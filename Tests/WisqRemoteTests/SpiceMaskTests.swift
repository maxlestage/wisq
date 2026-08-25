import XCTest
@testable import WisqRemote

/// The 1-bit mask that says which pixels of a box a draw may touch.
///
/// Every draw message ends with one, and it is null almost always — which is
/// exactly why it went unimplemented for so long and why getting it wrong is
/// invisible until a server sends one. The tests below are mostly about the
/// three things that can be off by a reflection: which bit of a byte is the
/// leftmost pixel, which way up the rows are, and where the mask sits relative
/// to the box.
final class SpiceMaskTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    /// A mask bitmap, as a draw message carries one.
    ///
    /// `rows` is one string per row, `#` for a set bit — readable, and the
    /// pattern is visible in the test rather than hidden in a hex blob.
    private func maskBitmap(
        _ rows: [String], format: SpiceDisplayWire.BitmapFormat = .oneBitLE,
        topDown: Bool = true, at origin: SpiceDisplayWire.Point = .init(x: 0, y: 0),
        inverse: Bool = false
    ) -> SpiceDisplayWire.Mask {
        let width = rows[0].count
        let stride = (width + 7) / 8
        var payload = [UInt8](repeating: 0, count: stride * rows.count)
        for (y, row) in rows.enumerated() {
            for (x, character) in row.enumerated() where character == "#" {
                let index = y * stride + x / 8
                payload[index] |= format == .oneBitBE ? 1 << UInt8(7 - x % 8) : 1 << UInt8(x % 8)
            }
        }
        return SpiceDisplayWire.Mask(
            flags: inverse ? SpiceMask.inverse : 0,
            origin: origin,
            bitmap: SpiceDisplayWire.Image(
                descriptor: SpiceDisplayWire.ImageDescriptor(
                    id: 1, type: .bitmap, flags: 0,
                    width: UInt32(width), height: UInt32(rows.count)
                ),
                bitmap: SpiceDisplayWire.Bitmap(
                    format: format, flags: topDown ? 0x04 : 0,
                    width: UInt32(width), height: UInt32(rows.count),
                    stride: UInt32(stride), cachedPaletteID: nil, palette: nil
                ),
                payload: payload
            )
        )
    }

    private func makeSurface(_ width: UInt32 = 8, _ height: UInt32 = 8) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: .xrgb32, flags: 0
        ))
        return surfaces
    }

    private func fill(
        _ box: SpiceDisplayWire.Rect, colour: UInt32, mask: SpiceDisplayWire.Mask
    ) -> SpiceDisplayWire.Fill {
        SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
            brush: .solid(colour), rop: 0, mask: mask
        )
    }

    /// What the surface looks like, one character per pixel: `#` where the
    /// fill landed, `.` where it did not. Comparing pictures rather than
    /// individual pixels is what makes a failure readable.
    private func picture(_ surfaces: SpiceSurfaces, colour: UInt8 = 0xFF) -> [String] {
        let surface = surfaces.surfaces[0]!
        return (0..<surface.height).map { y in
            String((0..<surface.width).map { x in
                surface.pixels[(y * surface.width + x) * 4 + 2] == colour ? "#" : "."
            })
        }
    }

    // MARK: - What the mask lets through

    func testAFillReachesOnlyThePixelsTheMaskSets() throws {
        var surfaces = try makeSurface(8, 4)
        let pattern = ["##......", "..##....", "....##..", "......##"]
        let written = try surfaces.fill(
            fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: maskBitmap(pattern))
        )
        XCTAssertEqual(picture(surfaces), pattern)
        // The region reported is still the rectangle. That is deliberate: an
        // update region is a hint about what to re-upload, so a superset costs
        // bandwidth and a subset loses pixels.
        XCTAssertEqual(written, [rect(0, 0, 4, 8)])
    }

    /// **Which bit of a byte is the leftmost pixel.**
    ///
    /// The same eight bytes mean mirrored things in the two formats, and either
    /// reading produces a picture — mirrored in groups of eight, which on a
    /// mask over a window is not obviously wrong at a glance.
    func testTheTwoBitOrdersAreMirrorImagesOfEachOther() throws {
        let pattern = ["#...#...", ".#...#..", "..#...#.", "...#...#"]

        var little = try makeSurface(8, 4)
        _ = try little.fill(
            fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: maskBitmap(pattern))
        )
        var big = try makeSurface(8, 4)
        _ = try big.fill(fill(
            rect(0, 0, 4, 8), colour: 0x00FF_0000,
            mask: maskBitmap(pattern, format: .oneBitBE)
        ))
        // Both helpers pack the same picture, each in its own order, so both
        // must decode back to it. The mirror test is on the *bytes*.
        XCTAssertEqual(picture(little), pattern)
        XCTAssertEqual(picture(big), pattern)

        let leBytes = maskBitmap(pattern).bitmap!.payload!
        let beBytes = maskBitmap(pattern, format: .oneBitBE).bitmap!.payload!
        XCTAssertNotEqual(leBytes, beBytes, "sinon le test ne distingue rien")

        // And the decisive half: the *same* bytes read in the other order give
        // the mirrored picture, so a decoder using one order for both is wrong.
        var crossed = try makeSurface(8, 4)
        var wrongWayRound = maskBitmap(pattern, format: .oneBitBE)
        wrongWayRound.bitmap!.payload = leBytes
        _ = try crossed.fill(fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: wrongWayRound))
        XCTAssertEqual(picture(crossed), pattern.map { String($0.reversed()) })
    }

    func testTheInverseFlagFlipsEveryBit() throws {
        var surfaces = try makeSurface(8, 4)
        let pattern = ["##......", "..##....", "....##..", "......##"]
        _ = try surfaces.fill(fill(
            rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: maskBitmap(pattern, inverse: true)
        ))
        XCTAssertEqual(
            picture(surfaces),
            pattern.map { String($0.map { $0 == "#" ? "." : "#" }) }
        )
    }

    /// Bottom-up is a bitmap's default here as everywhere else on this channel:
    /// the first row of data is the last row of the picture.
    func testAMaskThatIsNotTopDownHasItsRowsTheOtherWayUp() throws {
        var surfaces = try makeSurface(8, 4)
        let pattern = ["########", "........", "........", "..#####."]
        _ = try surfaces.fill(fill(
            rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: maskBitmap(pattern, topDown: false)
        ))
        XCTAssertEqual(picture(surfaces), pattern.reversed())
    }

    /// `pos` moves the mask relative to the box: destination pixel *(x, y)* is
    /// mask pixel *(x − box.left + pos.x, y − box.top + pos.y)*.
    func testThePositionSlidesTheMaskOverTheBox() throws {
        var surfaces = try makeSurface(8, 4)
        let pattern = ["####....", "####....", "####....", "####...."]
        _ = try surfaces.fill(fill(
            rect(0, 0, 4, 8), colour: 0x00FF_0000,
            mask: maskBitmap(pattern, at: SpiceDisplayWire.Point(x: -2, y: 0))
        ))
        // Shifted two to the right: mask column 0 now covers destination
        // column 2.
        XCTAssertEqual(picture(surfaces), ["..####..", "..####..", "..####..", "..####.."])
    }

    /// **Outside the mask is refused, not allowed.**
    ///
    /// The reference clips the mask's extents and then *intersects*, so a
    /// destination pixel with no mask pixel over it is dropped. Treating it as
    /// permitted paints the parts of the box the mask does not reach — which
    /// for a small mask over a large box is nearly all of it, and looks exactly
    /// like the mask working.
    func testTheBoxOutsideTheMaskIsNotPainted() throws {
        var surfaces = try makeSurface(8, 4)
        _ = try surfaces.fill(fill(
            rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: maskBitmap(["##", "##"])
        ))
        XCTAssertEqual(picture(surfaces), ["##......", "##......", "........", "........"])
    }

    /// The box moved away from the origin, which is where an implementation
    /// that forgot to subtract `box.left` still passes everything above.
    func testAMaskOnABoxAwayFromTheOriginLinesUpWithTheBoxAndNotTheSurface() throws {
        var surfaces = try makeSurface(8, 4)
        _ = try surfaces.fill(fill(
            rect(1, 3, 3, 7), colour: 0x00FF_0000, mask: maskBitmap(["#..#", ".##."])
        ))
        XCTAssertEqual(picture(surfaces), ["........", "...#..#.", "....##..", "........"])
    }

    /// A mask whose rows are padded out past the pixels they carry.
    ///
    /// The reference reads `ALIGN(x, 8) >> 3` bytes from each row and steps by
    /// the bitmap's stride, which is not the same number: a server is free to
    /// pad. Every fixture here uses the minimum stride, so a decoder that
    /// stepped by `(width + 7) / 8` instead of by the stride would pass all of
    /// them — which is why this one pads deliberately, and puts rubbish in the
    /// padding so reading it would show.
    func testAMaskWithPaddedRowsStepsByItsStride() throws {
        var surfaces = try makeSurface(4, 2)
        var mask = maskBitmap(["#.#.", ".#.#"])
        let padded: [UInt8] = [0b0000_0101, 0xFF, 0xFF, 0xFF, 0b0000_1010, 0xFF, 0xFF, 0xFF]
        mask.bitmap!.bitmap!.stride = 4
        mask.bitmap!.payload = padded

        _ = try surfaces.fill(fill(rect(0, 0, 2, 4), colour: 0x00FF_0000, mask: mask))
        XCTAssertEqual(picture(surfaces), ["#.#.", ".#.#"])
    }

    // MARK: - Through a copy

    func testACopyIsMaskedTheSameWay() throws {
        var surfaces = try makeSurface(4, 2)
        let source = [UInt8](repeating: 0x77, count: 4 * 2 * 4)
        let box = rect(0, 0, 2, 4)
        _ = try surfaces.copy(
            SpiceDisplayWire.Copy(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
                source: nil, sourceArea: box, rop: 0, scaleMode: 0,
                mask: maskBitmap(["#.#.", ".#.#"])
            ),
            source: (pixels: source, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(picture(surfaces, colour: 0x77), ["#.#.", ".#.#"])
    }

    func testTheOperandFreeRastersAreMaskedToo() throws {
        var surfaces = try makeSurface(4, 2)
        // White everywhere first, so the blackness below has something to
        // remove and "did nothing" is distinguishable from "did everything".
        _ = try surfaces.raster(SpiceDisplayWire.MaskedRaster(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
            operation: .whiteness,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        ))
        XCTAssertEqual(picture(surfaces), ["####", "####"])

        _ = try surfaces.raster(SpiceDisplayWire.MaskedRaster(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
            operation: .blackness, mask: maskBitmap(["#.#.", ".#.#"])
        ))
        XCTAssertEqual(picture(surfaces), [".#.#", "#.#."], "le noir n'a touché que les bits à un")
    }

    // MARK: - Masks that cannot be used

    func testAMaskThatIsNotOneBitIsRefused() throws {
        var surfaces = try makeSurface(8, 4)
        var mask = maskBitmap(["####"])
        mask.bitmap!.bitmap!.format = .eightBit
        XCTAssertThrowsError(
            try surfaces.fill(fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: mask))
        ) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    func testAMaskShorterThanItsGeometryIsRefused() throws {
        var surfaces = try makeSurface(8, 4)
        var mask = maskBitmap(["####", "####", "####", "####"])
        mask.bitmap!.payload = [0xFF]
        XCTAssertThrowsError(
            try surfaces.fill(fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: mask))
        ) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    func testAMaskNamingACachedImageIsRefused() throws {
        var surfaces = try makeSurface(8, 4)
        var mask = maskBitmap(["####"])
        mask.bitmap!.descriptor.type = .fromCache
        XCTAssertThrowsError(
            try surfaces.fill(fill(rect(0, 0, 4, 8), colour: 0x00FF_0000, mask: mask))
        ) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    /// The flag is bit 0. A bitmap's `TOP_DOWN` is bit 2, and the two flags
    /// bytes are close enough together in a message to be swapped.
    func testTheInverseFlagIsBitZeroAndNotTheBitmapsTopDown() {
        XCTAssertEqual(SpiceMask.inverse, 0x01)
        var mask = maskBitmap(["####"])
        mask.flags = 0x04
        let resolved = try? SpiceMask.resolve(mask, box: rect(0, 0, 1, 4))
        XCTAssertEqual(resolved?.inverted, false, "0x04 n'est pas INVERS")
    }
}
