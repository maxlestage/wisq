import XCTest
@testable import WisqRemote

/// A stroke landing on a surface.
///
/// The rasteriser's own tests look at coordinates; these look at pixels, which
/// is where the rop, the clip and the brush come in — none of which the walk
/// knows about, and each of which has been the thing that was missing on some
/// earlier draw.
final class SpiceStrokeSurfaceTests: XCTestCase {
    private func surfaces(_ width: UInt32 = 16, _ height: UInt32 = 8) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: .xrgb32, flags: 0
        ))
        return surfaces
    }

    private func fix(_ x: Int, _ y: Int) -> SpiceDisplayWire.PointFix {
        SpiceDisplayWire.PointFix(
            x: SpiceDisplayWire.Fixed28_4.whole(x), y: SpiceDisplayWire.Fixed28_4.whole(y)
        )
    }

    /// A stroke of one open figure, over the whole surface unless told otherwise.
    private func stroke(
        _ points: [(Int, Int)], colour: UInt32 = 0x00FF_FFFF, foreMode: UInt16 = 0x08,
        clip: SpiceDisplayWire.Clip = .none, style: [Int] = [], lineFlags: UInt8 = 0,
        closed: Bool = false
    ) -> SpiceDisplayWire.Stroke {
        var flags = SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.end
        if closed { flags |= SpiceDisplayWire.PathSegment.close }
        return SpiceDisplayWire.Stroke(
            base: SpiceDisplayWire.Base(
                surfaceID: 0,
                box: SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 8, right: 16),
                clip: clip
            ),
            path: SpiceDisplayWire.Path(segments: [
                SpiceDisplayWire.PathSegment(
                    flags: flags, points: points.map { fix($0.0, $0.1) }
                ),
            ]),
            attr: SpiceDisplayWire.LineAttr(
                flags: lineFlags,
                style: style.map { SpiceDisplayWire.Fixed28_4.whole($0) }
            ),
            brush: .solid(colour),
            foreMode: foreMode,
            backMode: 0
        )
    }

    private func pixel(_ surfaces: SpiceSurfaces, _ x: Int, _ y: Int) -> [UInt8] {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return Array(surface.pixels[at..<(at + 4)])
    }

    // MARK: - Le trait lui-même

    func testAHorizontalStrokeLandsWhereItsPathSays() throws {
        var surfaces = try surfaces()
        _ = try surfaces.stroke(stroke([(2, 3), (6, 3)]))

        for x in 2..<6 {
            XCTAssertEqual(pixel(surfaces, x, 3), [0xFF, 0xFF, 0xFF, 0], "x = \(x)")
        }
        XCTAssertEqual(pixel(surfaces, 6, 3), [0, 0, 0, 0], "le point final n'est pas dessiné")
        XCTAssertEqual(pixel(surfaces, 1, 3), [0, 0, 0, 0])
        XCTAssertEqual(pixel(surfaces, 2, 2), [0, 0, 0, 0], "rien au-dessus")
    }

    // MARK: - L'opération raster

    /// **The reason strokes needed the rop at all.**
    ///
    /// A rubber-band outline, a caret and a selection rectangle are all drawn
    /// with `XOR`, precisely so that drawing them a second time takes them off
    /// again. Read as a copy — which is what every draw did before the rop was
    /// wired — they go on and stay on, and dragging a selection leaves a trail
    /// of boxes behind it.
    func testAnXORStrokeDrawnTwiceLeavesTheScreenAsItFoundIt() throws {
        var surfaces = try surfaces()
        // Something to draw over, so that "restored" means restored and not
        // "black either way".
        _ = try surfaces.fill(SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(
                surfaceID: 0,
                box: SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 8, right: 16),
                clip: .none
            ),
            brush: .solid(0x0012_3456), rop: 0x08,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        ))
        let before = surfaces.surfaces[0]!.pixels

        let xorMode: UInt16 = 0x40   // SPICE_ROPD_OP_XOR
        let outline = stroke([(1, 1), (9, 1), (9, 5), (1, 5)],
                             foreMode: xorMode, closed: true)
        _ = try surfaces.stroke(outline)
        XCTAssertNotEqual(surfaces.surfaces[0]!.pixels, before, "le premier tracé a marqué l'écran")

        _ = try surfaces.stroke(outline)
        XCTAssertEqual(
            surfaces.surfaces[0]!.pixels, before,
            "le second tracé doit rendre l'écran identique"
        )
    }

    /// **A pixel is painted once even where the path crosses itself.**
    ///
    /// Under `XOR` the difference shows: paint a crossing twice and there is a
    /// hole in it. A figure-of-eight is the smallest shape that has one.
    func testAPathThatCrossesItselfPaintsTheCrossingOnce() throws {
        var surfaces = try surfaces()
        let xorMode: UInt16 = 0x40
        // Two diagonals meeting at (4, 2): drawn independently they would each
        // touch it, and the second would rub out the first.
        _ = try surfaces.stroke(stroke([(2, 0), (6, 4), (6, 0), (2, 4)], foreMode: xorMode))

        XCTAssertEqual(
            pixel(surfaces, 4, 2), [0xFF, 0xFF, 0xFF, 0],
            "le croisement a été peint deux fois et s'est effacé"
        )
    }

    /// **A stroke's rop combines the *brush* with the destination**, so the flag
    /// that inverts its source is `INVERS_BRUSH` and not `INVERS_SRC`.
    ///
    /// A descriptor with no inversion bits cannot tell the two apart — both
    /// labellings give the same operation — which is exactly why sabotage
    /// swapping `.brush` for `.source` survived a suite whose strokes all used
    /// plain `PUT` and `XOR`. The discriminating input is a descriptor that
    /// inverts something.
    ///
    /// `OP_PUT | INVERS_BRUSH` means "copy the inverted brush": drawing white
    /// with it must lay down black. Read as `INVERS_SRC`, nothing is inverted
    /// and the line comes out white.
    func testTheRopInvertsTheBrushAndNotSomethingCalledTheSource() throws {
        var surfaces = try surfaces()
        let putInvertingTheBrush: UInt16 = 0x08 | 0x02   // OP_PUT | INVERS_BRUSH
        _ = try surfaces.stroke(stroke(
            [(2, 3), (6, 3)], colour: 0x00FF_FFFF, foreMode: putInvertingTheBrush
        ))

        XCTAssertEqual(
            pixel(surfaces, 3, 3), [0x00, 0x00, 0x00, 0],
            "le blanc inversé doit être noir : la brosse n'a pas été inversée"
        )
    }

    // MARK: - Le clip

    /// The clip reduces where a stroke lands, the same as it does for a fill —
    /// which is what stops a line drawn under a window from showing through it.
    func testTheClipReducesWhereAStrokeLands() throws {
        var surfaces = try surfaces()
        let clipped = stroke(
            [(0, 3), (12, 3)],
            clip: .rects([SpiceDisplayWire.Rect(top: 0, left: 4, bottom: 8, right: 8)])
        )
        _ = try surfaces.stroke(clipped)

        XCTAssertEqual(pixel(surfaces, 3, 3), [0, 0, 0, 0], "avant le clip")
        XCTAssertEqual(pixel(surfaces, 4, 3), [0xFF, 0xFF, 0xFF, 0], "dedans")
        XCTAssertEqual(pixel(surfaces, 7, 3), [0xFF, 0xFF, 0xFF, 0], "dedans")
        XCTAssertEqual(pixel(surfaces, 8, 3), [0, 0, 0, 0], "après le clip")
    }

    /// A stroke running off the surface is clipped rather than trapping. The
    /// coordinates come off a socket; a negative one must not become an index.
    func testAStrokeLeavingTheSurfaceIsClippedRatherThanTrapping() throws {
        var surfaces = try surfaces()
        XCTAssertNoThrow(try surfaces.stroke(stroke([(-40, 3), (400, 3)])))
        XCTAssertEqual(pixel(surfaces, 0, 3), [0xFF, 0xFF, 0xFF, 0])
        XCTAssertEqual(pixel(surfaces, 15, 3), [0xFF, 0xFF, 0xFF, 0])
    }

    // MARK: - Les tirets

    /// A dashed line draws its cycle, and — the part worth checking — the drawn
    /// pixels sit on the **same track** as a solid line's. A dasher that walked
    /// its own geometry could put them a pixel beside it.
    func testADashedStrokeIsASubsetOfTheSolidOne() throws {
        var solidSurfaces = try surfaces()
        _ = try solidSurfaces.stroke(stroke([(0, 2), (14, 6)]))

        var dashedSurfaces = try surfaces()
        _ = try dashedSurfaces.stroke(stroke(
            [(0, 2), (14, 6)],
            style: [2, 2], lineFlags: SpiceDisplayWire.LineAttr.styled
        ))

        var drawn = 0
        for y in 0..<8 {
            for x in 0..<16 {
                let dashed = pixel(dashedSurfaces, x, y)
                if dashed != [0, 0, 0, 0] {
                    drawn += 1
                    XCTAssertEqual(
                        pixel(solidSurfaces, x, y), dashed,
                        "(\(x),\(y)) est allumé en pointillé mais pas en plein"
                    )
                }
            }
        }
        XCTAssertGreaterThan(drawn, 0, "le pointillé n'a rien dessiné")
        XCTAssertLessThan(drawn, 14, "le pointillé a tout dessiné")
    }

    /// **The dash cycle runs along the whole figure, across its corners.**
    ///
    /// Restarting it at each vertex puts a dash at every corner of a dashed
    /// rectangle, which is not what a dashed rectangle looks like. A single
    /// straight segment cannot tell the two apart — there is no second vertex —
    /// which is why sabotage restarting the cycle survived until this test
    /// existed. Two segments meeting at a corner can.
    ///
    /// The corner is placed so that the cycle is mid-gap when it arrives: a
    /// restart would light it, carrying on leaves it dark.
    func testTheDashCycleCarriesAcrossACorner() throws {
        var surfaces = try surfaces()
        // Five pixels along the top, then down. With a cycle of 2 on, 2 off,
        // the fifth pixel — the corner — falls in the second gap.
        _ = try surfaces.stroke(stroke(
            [(0, 0), (4, 0), (4, 6)],
            style: [2, 2], lineFlags: SpiceDisplayWire.LineAttr.styled
        ))

        XCTAssertEqual(pixel(surfaces, 0, 0), [0xFF, 0xFF, 0xFF, 0], "premier trait")
        XCTAssertEqual(pixel(surfaces, 1, 0), [0xFF, 0xFF, 0xFF, 0])
        XCTAssertEqual(pixel(surfaces, 2, 0), [0, 0, 0, 0], "premier blanc")
        XCTAssertEqual(pixel(surfaces, 3, 0), [0, 0, 0, 0])
        XCTAssertEqual(
            pixel(surfaces, 4, 0), [0xFF, 0xFF, 0xFF, 0],
            "le cycle continue au coin plutôt que de repartir"
        )
        XCTAssertEqual(pixel(surfaces, 4, 1), [0xFF, 0xFF, 0xFF, 0])
        XCTAssertEqual(pixel(surfaces, 4, 2), [0, 0, 0, 0], "et le blanc suit")
    }

    // MARK: - Ce qui n'est pas dessiné

    /// A brush this cannot paint with is refused rather than drawn in some
    /// default colour: a line the server meant to be a pattern coming out solid
    /// white is a wrong picture, not a missing feature.
    func testAPatternBrushIsRefusedRatherThanGuessedAt() throws {
        var surfaces = try surfaces()
        var operation = stroke([(0, 0), (4, 4)])
        operation.brush = .pattern(image: nil, origin: SpiceDisplayWire.Point(x: 0, y: 0))
        XCTAssertThrowsError(try surfaces.stroke(operation)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    func testAStrokeForASurfaceThatDoesNotExistIsRefused() throws {
        var surfaces = try surfaces()
        var operation = stroke([(0, 0), (4, 4)])
        operation.base.surfaceID = 7
        XCTAssertThrowsError(try surfaces.stroke(operation)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .unknownSurface(7))
        }
    }
}
