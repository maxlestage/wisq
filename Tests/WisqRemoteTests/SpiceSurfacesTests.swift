import XCTest
@testable import WisqRemote

/// Where a draw is allowed to write, and what it puts there.
///
/// Nearly every test here is about a boundary, and that is not padding.
///
/// Swift's arrays are bounds-checked, so a draw that runs off a surface traps
/// rather than shearing the picture the way the equivalent C would. That makes
/// the failure loud but no less fatal: on a phone the app disappears, and the
/// numbers that caused it came off a socket. Removing the cut in `regions`
/// does not fail these tests, it takes the test process down with signal 4 —
/// which is itself the demonstration that the cut is load-bearing.
final class SpiceSurfacesTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    private func base(
        _ box: SpiceDisplayWire.Rect, clip: SpiceDisplayWire.Clip = .none, surface: UInt32 = 0
    ) -> SpiceDisplayWire.Base {
        SpiceDisplayWire.Base(surfaceID: surface, box: box, clip: clip)
    }

    private func makeSurface(
        _ width: UInt32 = 8, _ height: UInt32 = 8,
        format: SpiceDisplayWire.SurfaceFormat = .xrgb32
    ) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: format, flags: 0
        ))
        return surfaces
    }

    private func solidFill(
        _ box: SpiceDisplayWire.Rect, colour: UInt32, clip: SpiceDisplayWire.Clip = .none
    ) -> SpiceDisplayWire.Fill {
        SpiceDisplayWire.Fill(
            base: base(box, clip: clip), brush: .solid(colour), rop: 0,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        )
    }

    /// Reads a pixel as blue, green, red, pad.
    private func pixel(_ surfaces: SpiceSurfaces, _ x: Int, _ y: Int) -> [UInt8] {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return Array(surface.pixels[at..<(at + 4)])
    }

    // MARK: - Surfaces

    func testASurfaceIsCreatedAtItsSizeAndStartsBlack() throws {
        let surfaces = try makeSurface(4, 3)
        XCTAssertEqual(surfaces.surfaces[0]?.width, 4)
        XCTAssertEqual(surfaces.surfaces[0]?.height, 3)
        XCTAssertEqual(surfaces.surfaces[0]?.pixels.count, 4 * 3 * 4)
        XCTAssertTrue(surfaces.surfaces[0]!.pixels.allSatisfy { $0 == 0 })
    }

    /// A format that cannot be laid out is named rather than approximated. A
    /// 16-bit surface written as though it were 32-bit is a screen of noise.
    func testAFormatThatCannotBeLaidOutIsNamedRatherThanApproximated() {
        for format in [SpiceDisplayWire.SurfaceFormat.rgb16_565, .rgb16_555, .alpha8, .alpha1] {
            XCTAssertThrowsError(try makeSurface(8, 8, format: format), "\(format)") { error in
                XCTAssertEqual(error as? SpiceSurfaces.Failure, .unsupportedFormat(format))
            }
        }
    }

    /// Two numbers a server chose, multiplied, are an allocation a server
    /// chose. There is a ceiling.
    func testASizeNoPhoneCouldHoldIsRefusedBeforeAnythingIsAllocated() {
        for (width, height) in [(UInt32(0), UInt32(8)), (8, 0), (0xFFFF, 0xFFFF)] {
            XCTAssertThrowsError(try makeSurface(width, height), "\(width)x\(height)") { error in
                XCTAssertEqual(
                    error as? SpiceSurfaces.Failure,
                    .unreasonableSize(width: width, height: height)
                )
            }
        }
    }

    func testDrawingOnASurfaceThatDoesNotExistIsRefused() throws {
        var surfaces = SpiceSurfaces()
        XCTAssertThrowsError(try surfaces.fill(solidFill(rect(0, 0, 4, 4), colour: 1))) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .unknownSurface(0))
        }
    }

    // MARK: - Clipping

    /// The box is cut down to the surface. Without this, a box a server chose
    /// indexes past the pixel array and Swift traps — verified by removing the
    /// cut, which ends the run with signal 4 rather than a failure.
    func testABoxLargerThanTheSurfaceIsCutDownRatherThanRunningOff() throws {
        var surfaces = try makeSurface(4, 4)
        let written = try surfaces.fill(solidFill(rect(-10, -10, 100, 100), colour: 0x00FF_0000))

        XCTAssertEqual(written, [rect(0, 0, 4, 4)])
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(pixel(surfaces, x, y), [0, 0, 0xFF, 0], "pixel \(x),\(y)")
            }
        }
    }

    /// A box entirely outside the surface writes nothing, and says so.
    func testABoxCompletelyOutsideTheSurfaceWritesNothing() throws {
        var surfaces = try makeSurface(4, 4)
        XCTAssertEqual(try surfaces.fill(solidFill(rect(10, 10, 20, 20), colour: 0xFFFF)), [])
        XCTAssertTrue(surfaces.surfaces[0]!.pixels.allSatisfy { $0 == 0 })
    }

    /// The clip and the box are two different cuts and both apply. Honour only
    /// the box and a window that should have stayed covered gets painted over.
    func testTheClipCutsTheBoxAndNotTheOtherWayRound() throws {
        var surfaces = try makeSurface(8, 8)
        let written = try surfaces.fill(solidFill(
            rect(0, 0, 8, 8),
            colour: 0x00FF_0000,
            clip: .rects([rect(2, 2, 4, 4), rect(6, 6, 20, 20)])
        ))

        // The second clip rectangle runs past the surface and is cut to it.
        XCTAssertEqual(written, [rect(2, 2, 4, 4), rect(6, 6, 8, 8)])
        XCTAssertEqual(pixel(surfaces, 2, 2), [0, 0, 0xFF, 0], "dans la découpe")
        XCTAssertEqual(pixel(surfaces, 7, 7), [0, 0, 0xFF, 0], "dans la seconde")
        XCTAssertEqual(pixel(surfaces, 5, 5), [0, 0, 0, 0], "hors découpe, intact")
        XCTAssertEqual(pixel(surfaces, 0, 0), [0, 0, 0, 0], "dans la boîte mais hors découpe")
    }

    /// A clip rectangle that misses the box entirely contributes nothing rather
    /// than a rectangle with a negative width, which downstream is a range that
    /// traps or a count that wraps.
    func testAClipThatMissesTheBoxContributesNothingRatherThanANegativeRectangle() throws {
        var surfaces = try makeSurface(8, 8)
        let written = try surfaces.fill(solidFill(
            rect(0, 0, 4, 4), colour: 1, clip: .rects([rect(6, 6, 8, 8)])
        ))
        XCTAssertEqual(written, [])
        XCTAssertNil(SpiceSurfaces.intersect(rect(0, 0, 2, 2), rect(5, 5, 7, 7)))
    }

    // MARK: - Fill

    /// The colour word is little-endian into blue, green, red — and the fourth
    /// byte is padding on an `xRGB` surface, not transparency.
    func testTheFillColourLandsAsBlueGreenRedAndThePadStaysZero() throws {
        var surfaces = try makeSurface(2, 2)
        try surfaces.fill(solidFill(rect(0, 0, 2, 2), colour: 0xAABB_CCDD))
        XCTAssertEqual(pixel(surfaces, 0, 0), [0xDD, 0xCC, 0xBB, 0], "le pad reste à zéro")
    }

    /// On a surface that really carries alpha, the fourth byte is the source's.
    /// Writing it into an `xRGB` pad would make an opaque desktop see-through
    /// in whatever composites it later.
    func testAlphaIsCarriedOnlyBySurfacesThatHaveIt() throws {
        var opaque = try makeSurface(2, 2, format: .xrgb32)
        try opaque.fill(solidFill(rect(0, 0, 2, 2), colour: 0xAABB_CCDD))
        XCTAssertEqual(pixel(opaque, 0, 0)[3], 0)

        var translucent = try makeSurface(2, 2, format: .argb32)
        try translucent.fill(solidFill(rect(0, 0, 2, 2), colour: 0xAABB_CCDD))
        XCTAssertEqual(pixel(translucent, 0, 0)[3], 0xAA)
    }

    /// A brush this does not paint is refused rather than silently skipped, so
    /// the caller can tell "nothing to do" from "I could not do it".
    func testABrushThisDoesNotPaintIsRefusedRatherThanIgnored() throws {
        var surfaces = try makeSurface(4, 4)
        let fill = SpiceDisplayWire.Fill(
            base: base(rect(0, 0, 4, 4)), brush: .none, rop: 0,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        )
        XCTAssertThrowsError(try surfaces.fill(fill)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    // MARK: - Copy

    private func copyOperation(
        box: SpiceDisplayWire.Rect, area: SpiceDisplayWire.Rect,
        clip: SpiceDisplayWire.Clip = .none
    ) -> SpiceDisplayWire.Copy {
        SpiceDisplayWire.Copy(
            base: base(box, clip: clip), source: nil, sourceArea: area, rop: 0, scaleMode: 0,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        )
    }

    /// A 4×4 source whose every pixel is a different, recognisable value.
    private var marker: (pixels: [UInt8], width: Int, height: Int) {
        var pixels: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                pixels += [UInt8(x * 16), UInt8(y * 16), UInt8(x * 4 + y), 0]
            }
        }
        return (pixels, 4, 4)
    }

    func testAOneToOneCopyLandsPixelForPixelAtTheBoxOrigin() throws {
        var surfaces = try makeSurface(8, 8)
        try surfaces.copy(
            copyOperation(box: rect(2, 3, 6, 7), area: rect(0, 0, 4, 4)),
            source: marker, bytesPerSourcePixel: 4
        )
        // Source (0,0) lands at the box's top-left, which is (3, 2) in x,y.
        XCTAssertEqual(pixel(surfaces, 3, 2), [0, 0, 0, 0])
        XCTAssertEqual(pixel(surfaces, 4, 2), [16, 0, 4, 0], "source (1,0)")
        XCTAssertEqual(pixel(surfaces, 3, 3), [0, 16, 1, 0], "source (0,1)")
        XCTAssertEqual(pixel(surfaces, 6, 5), [48, 48, 15, 0], "source (3,3)")
        XCTAssertEqual(pixel(surfaces, 0, 0), [0, 0, 0, 0], "hors boîte, intact")
    }

    /// The one that is easy to get wrong. A clip changes *which* pixels get
    /// written, never *which source pixel* each one comes from. Compute the
    /// source coordinate from the clipped rectangle instead of the box and the
    /// image slides sideways wherever something overlaps it.
    func testAClipMovesWhichPixelsAreWrittenNotWhichSourcePixelTheyComeFrom() throws {
        var clipped = try makeSurface(8, 8)
        try clipped.copy(
            copyOperation(box: rect(0, 0, 4, 4), area: rect(0, 0, 4, 4),
                          clip: .rects([rect(2, 2, 4, 4)])),
            source: marker, bytesPerSourcePixel: 4
        )

        var whole = try makeSurface(8, 8)
        try whole.copy(
            copyOperation(box: rect(0, 0, 4, 4), area: rect(0, 0, 4, 4)),
            source: marker, bytesPerSourcePixel: 4
        )

        // Inside the clip the two must agree exactly.
        for y in 2..<4 {
            for x in 2..<4 {
                XCTAssertEqual(pixel(clipped, x, y), pixel(whole, x, y), "pixel \(x),\(y)")
            }
        }
        // Outside it, the clipped one wrote nothing.
        XCTAssertEqual(pixel(clipped, 0, 0), [0, 0, 0, 0])
        XCTAssertNotEqual(pixel(whole, 1, 1), pixel(clipped, 1, 1))
    }

    /// A box bigger than the source area is a scale, and nearest neighbour is
    /// what this does. Doubling must repeat each source pixel twice, not read
    /// past the source.
    func testABoxLargerThanTheSourceScalesByNearestNeighbour() throws {
        var surfaces = try makeSurface(8, 8)
        try surfaces.copy(
            copyOperation(box: rect(0, 0, 8, 8), area: rect(0, 0, 4, 4)),
            source: marker, bytesPerSourcePixel: 4
        )
        XCTAssertEqual(pixel(surfaces, 0, 0), pixel(surfaces, 1, 1), "même pixel source")
        XCTAssertEqual(pixel(surfaces, 2, 0), [16, 0, 4, 0], "source (1,0)")
        XCTAssertEqual(pixel(surfaces, 7, 7), [48, 48, 15, 0], "source (3,3), pas au-delà")
    }

    /// A three-byte source has no alpha to carry, and the destination pad must
    /// still be written rather than left holding whatever was there.
    func testAThreeByteSourceLeavesTheDestinationPadAtZero() throws {
        var surfaces = try makeSurface(4, 4, format: .xrgb32)
        try surfaces.fill(solidFill(rect(0, 0, 4, 4), colour: 0xFFFF_FFFF))

        let source: [UInt8] = (0..<16).flatMap { [UInt8($0), UInt8($0 &+ 1), UInt8($0 &+ 2)] }
        try surfaces.copy(
            copyOperation(box: rect(0, 0, 4, 4), area: rect(0, 0, 4, 4)),
            source: (source, 4, 4), bytesPerSourcePixel: 3
        )
        XCTAssertEqual(pixel(surfaces, 0, 0), [0, 1, 2, 0])
    }

    /// A source shorter than its own declared size is refused rather than read
    /// past. That array came from a decoder fed by the network.
    func testASourceShorterThanItsDeclaredSizeIsRefused() throws {
        var surfaces = try makeSurface(4, 4)
        XCTAssertThrowsError(try surfaces.copy(
            copyOperation(box: rect(0, 0, 4, 4), area: rect(0, 0, 4, 4)),
            source: ([1, 2, 3, 4], 4, 4), bytesPerSourcePixel: 4
        )) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    // MARK: - All the way through

    /// A stream from SPICE's own encoder, decoded and drawn onto a surface.
    ///
    /// The one test that crosses every seam at once: the display channel says
    /// where, the LZ decoder says what, and this puts it there. Each of those
    /// was correct on its own before this existed, and nothing showed anything.
    func testARealLZStreamReachesTheSurfaceAsPixels() throws {
        let fixture = try XCTUnwrap(SpiceLZFixtures.all.first { $0.name == "rgb32 8x8" })
        var hex = fixture.stream.filter { !$0.isWhitespace }
        var stream: [UInt8] = []
        while let next = hex.popFirst2() { stream.append(next) }

        let decoded = try SpiceLZ.decompress(stream)
        XCTAssertEqual(decoded.header.width, 8)

        var surfaces = try makeSurface(16, 16)
        let written = try surfaces.copy(
            copyOperation(box: rect(4, 4, 12, 12), area: rect(0, 0, 8, 8)),
            source: (decoded.pixels, 8, 8), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(written, [rect(4, 4, 12, 12)])

        // The surface's pixels are the decoder's, placed at the box's origin.
        for y in 0..<8 {
            for x in 0..<8 {
                let from = (y * 8 + x) * 4
                XCTAssertEqual(
                    Array(decoded.pixels[from..<(from + 3)]),
                    Array(pixel(surfaces, x + 4, y + 4)[0..<3]),
                    "pixel \(x),\(y)"
                )
            }
        }
        // And nothing outside the box was touched.
        XCTAssertEqual(pixel(surfaces, 0, 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(surfaces, 15, 15), [0, 0, 0, 0])
    }
}

private extension String {
    /// Takes two hex characters off the front and returns them as a byte.
    mutating func popFirst2() -> UInt8? {
        guard count >= 2 else { return nil }
        let pair = prefix(2)
        removeFirst(2)
        return UInt8(pair, radix: 16)
    }
}
