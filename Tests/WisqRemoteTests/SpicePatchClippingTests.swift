import Foundation
import WisqCore
import XCTest

@testable import WisqRemote

/// Cutting a rectangle out of a SPICE surface, and the invariant that used to
/// be held by a default argument in another file.
///
/// `publish` copies each drawn region out of the primary surface and into the
/// framebuffer. It indexed `surface.pixels` straight from the region's numbers.
/// That is correct exactly as long as the region was clipped against *this*
/// surface and the surface has not changed since — and nothing said so.
///
/// It is true today, for a narrow reason: `publish` runs after every `pump`,
/// and `pump` takes `limit: Int = 1`. One message a call, so a draw and a later
/// `surface_destroy` / `surface_create` cannot share a batch, and a region
/// never outlives its surface. **That is the whole proof, and it lives in a
/// default argument.** Raise the limit for throughput — the obvious
/// optimisation — and one batch carries create-large, draw, destroy,
/// create-small; the region is then cut from a surface a quarter its size and
/// the slice runs off the end.
///
/// So the clip is enforced here instead of assumed there. These tests are the
/// ones that would have to fail before that becomes possible again.
final class SpicePatchClippingTests: XCTestCase {
    private func surface(_ width: Int, _ height: Int, fill: UInt8 = 0x11) -> SpiceSurfaces.Surface {
        SpiceSurfaces.Surface(
            width: width, height: height, hasAlpha: false,
            pixels: [UInt8](repeating: fill, count: width * height * 4))
    }

    // MARK: - What must be clipped

    /// The scenario a larger `limit` would allow: a region measured against a
    /// big surface, cut from the small one that replaced it.
    func testARegionLargerThanItsSurfaceIsClippedRatherThanRunningOff() throws {
        let small = surface(8, 8)
        let stale = Rect(x: 0, y: 0, width: 64, height: 64)

        let cut = try XCTUnwrap(SPICESession.patch(of: stale, in: small))
        XCTAssertEqual(cut.rect.width, 8)
        XCTAssertEqual(cut.rect.height, 8)
        XCTAssertEqual(cut.pixels.count, 8 * 8 * 4)
    }

    /// Overhanging on one axis only, which is what a resize in one dimension
    /// leaves behind.
    func testARegionThatOverhangsOnOneAxisIsClippedOnThatAxis() throws {
        let wide = surface(16, 4)
        let cut = try XCTUnwrap(
            SPICESession.patch(of: Rect(x: 8, y: 0, width: 32, height: 4), in: wide))
        XCTAssertEqual(cut.rect.x, 8)
        XCTAssertEqual(cut.rect.width, 8, "8 + 32 dépasse : coupé à la largeur de la surface")
        XCTAssertEqual(cut.rect.height, 4)
        XCTAssertEqual(cut.pixels.count, 8 * 4 * 4)
    }

    /// A negative origin is the other end of the same problem.
    func testANegativeOriginIsClippedToZero() throws {
        let cut = try XCTUnwrap(
            SPICESession.patch(of: Rect(x: -4, y: -4, width: 8, height: 8), in: surface(8, 8)))
        XCTAssertEqual(cut.rect.x, 0)
        XCTAssertEqual(cut.rect.y, 0)
        XCTAssertEqual(cut.rect.width, 4)
        XCTAssertEqual(cut.rect.height, 4)
    }

    /// Entirely outside is nothing to paint, not an empty rectangle to report.
    func testARegionEntirelyOutsideTheSurfaceIsRefused() {
        XCTAssertNil(SPICESession.patch(of: Rect(x: 64, y: 0, width: 8, height: 8), in: surface(8, 8)))
        XCTAssertNil(SPICESession.patch(of: Rect(x: 0, y: 64, width: 8, height: 8), in: surface(8, 8)))
        XCTAssertNil(
            SPICESession.patch(of: Rect(x: -8, y: 0, width: 8, height: 8), in: surface(8, 8)))
    }

    /// A surface whose buffer disagrees with its declared size would index past
    /// the end even after clipping. Belt as well as braces.
    func testASurfaceShorterThanItsOwnGeometryIsRefused() {
        let lying = SpiceSurfaces.Surface(width: 64, height: 64, hasAlpha: false, pixels: [0, 0, 0, 0])
        XCTAssertNil(SPICESession.patch(of: Rect(x: 0, y: 0, width: 8, height: 8), in: lying))
    }

    // MARK: - What must not change

    /// The ordinary case, which is every real frame: a region inside the
    /// surface comes back exactly as asked, with the right pixels.
    ///
    /// Without this, a `patch` that returned nil for everything would satisfy
    /// all the clipping tests above.
    func testARegionInsideTheSurfaceIsReturnedUntouched() throws {
        var canvas = surface(4, 4, fill: 0)
        // Marque le pixel (2, 1) pour vérifier que la bonne rangée est lue.
        let mark = (1 * 4 + 2) * 4
        canvas.pixels[mark] = 0xAB
        canvas.pixels[mark + 1] = 0xCD

        let cut = try XCTUnwrap(
            SPICESession.patch(of: Rect(x: 2, y: 1, width: 2, height: 2), in: canvas))
        XCTAssertEqual(cut.rect, Rect(x: 2, y: 1, width: 2, height: 2))
        XCTAssertEqual(cut.pixels.count, 2 * 2 * 4)
        XCTAssertEqual(cut.pixels[0], 0xAB, "la première ligne du patch est celle de y = 1")
        XCTAssertEqual(cut.pixels[1], 0xCD)
    }

    /// The whole surface at once, which is the first frame of every session.
    func testTheWholeSurfaceIsCutWithoutBeingClipped() throws {
        let cut = try XCTUnwrap(
            SPICESession.patch(of: Rect(x: 0, y: 0, width: 8, height: 8), in: surface(8, 8)))
        XCTAssertEqual(cut.rect, Rect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(cut.pixels.count, 8 * 8 * 4)
        XCTAssertTrue(cut.pixels.allSatisfy { $0 == 0x11 })
    }

    /// The rectangle handed back is the clipped one, and that is what the
    /// renderer is told changed. Reporting the region as asked for would claim
    /// pixels were painted outside the surface.
    func testTheReportedRectangleIsTheClippedOneRatherThanTheRequest() throws {
        let cut = try XCTUnwrap(
            SPICESession.patch(of: Rect(x: 4, y: 4, width: 99, height: 99), in: surface(8, 8)))
        XCTAssertEqual(cut.rect, Rect(x: 4, y: 4, width: 4, height: 4))
        XCTAssertEqual(cut.pixels.count, cut.rect.width * cut.rect.height * 4)
    }
}
