import XCTest
@testable import WisqRemote

/// The draws that carry no image: the surface copying from itself, and the
/// three raster operations with no operand.
///
/// They are the cheapest messages on the channel and among the most used — a
/// window scrolling is `DRAW_COPY_BITS`, a window clearing itself before it
/// repaints is usually `DRAW_BLACKNESS` or `DRAW_WHITENESS`. Until now every
/// one of them was counted as ignored, which on screen is a scrolled window
/// that keeps its old contents.
final class SpiceCopyBitsTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    private func noMask() -> SpiceDisplayWire.Mask {
        SpiceDisplayWire.Mask(flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil)
    }

    private func aMask() -> SpiceDisplayWire.Mask {
        SpiceDisplayWire.Mask(
            flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0),
            bitmap: SpiceDisplayWire.Image(
                descriptor: SpiceDisplayWire.ImageDescriptor(
                    id: 1, type: .bitmap, flags: 0, width: 4, height: 4
                ),
                bitmap: nil, payload: nil
            )
        )
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

    /// Every pixel a different value, so a copy that lands one row or one
    /// column out is a failure rather than a coincidence.
    ///
    /// Painted through `copy` rather than by reaching into the surface, because
    /// the surface's pixels are read-only from out here — which is the right
    /// way round, and means the setup uses the same door as the protocol.
    private func paintGradient(_ surfaces: inout SpiceSurfaces) throws {
        let width = surfaces.surfaces[0]!.width
        let height = surfaces.surfaces[0]!.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                pixels[at] = UInt8(truncatingIfNeeded: x &* 16 &+ 1)
                pixels[at + 1] = UInt8(truncatingIfNeeded: y &* 16 &+ 2)
                pixels[at + 2] = UInt8(truncatingIfNeeded: (x &+ y) &* 8 &+ 3)
                pixels[at + 3] = 0xFF
            }
        }
        let box = rect(0, 0, Int32(height), Int32(width))
        _ = try surfaces.copy(
            SpiceDisplayWire.Copy(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
                source: nil, sourceArea: box, rop: 0, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: pixels, width: width, height: height),
            bytesPerSourcePixel: 4
        )
    }

    private func pixel(_ surfaces: SpiceSurfaces, _ x: Int, _ y: Int) -> [UInt8] {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return Array(surface.pixels[at..<(at + 4)])
    }

    private func copyBits(
        box: SpiceDisplayWire.Rect, from source: SpiceDisplayWire.Point,
        clip: SpiceDisplayWire.Clip = .none
    ) -> SpiceDisplayWire.CopyBits {
        SpiceDisplayWire.CopyBits(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: clip), source: source
        )
    }

    private func raster(
        _ operation: SpiceDisplayWire.MaskedRaster.Operation,
        _ box: SpiceDisplayWire.Rect,
        clip: SpiceDisplayWire.Clip = .none,
        mask: SpiceDisplayWire.Mask? = nil
    ) -> SpiceDisplayWire.MaskedRaster {
        SpiceDisplayWire.MaskedRaster(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: clip),
            operation: operation, mask: mask ?? noMask()
        )
    }

    // MARK: - Copying from the surface itself

    /// **The copy overlaps itself**, and this is the test that says so.
    ///
    /// Moving a 6-row band up by two rows means rows 2 and 3 of the source are
    /// read after rows 0 and 1 of the destination — which are the same
    /// memory — have already been written. A loop that reads as it writes gets
    /// the first two rows right and then repeats them down the band.
    ///
    /// The expectation is built from a copy of the surface taken *before* the
    /// draw, so it cannot accidentally agree with whatever the draw did.
    func testAnOverlappingUpwardCopyMovesTheContentRatherThanSmearingIt() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        let written = try surfaces.copyBits(
            copyBits(box: rect(0, 0, 6, 8), from: SpiceDisplayWire.Point(x: 0, y: 2))
        )
        XCTAssertEqual(written, [rect(0, 0, 6, 8)])

        for y in 0..<6 {
            for x in 0..<8 {
                let from = ((y + 2) * 8 + x) * 4
                XCTAssertEqual(
                    pixel(surfaces, x, y), Array(before[from..<(from + 4)]),
                    "la ligne \(y) vient de la ligne \(y + 2)"
                )
            }
        }
        // The two rows the band did not reach are untouched.
        for y in 6..<8 {
            let from = (y * 8) * 4
            XCTAssertEqual(pixel(surfaces, 0, y), Array(before[from..<(from + 4)]))
        }
    }

    /// The same, downwards, which needs the opposite row order. A decoder that
    /// hard-coded one direction passes the test above and fails this one.
    func testAnOverlappingDownwardCopyMovesTheContentToo() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        _ = try surfaces.copyBits(
            copyBits(box: rect(3, 0, 8, 8), from: SpiceDisplayWire.Point(x: 0, y: 0))
        )
        for y in 3..<8 {
            for x in 0..<8 {
                let from = ((y - 3) * 8 + x) * 4
                XCTAssertEqual(
                    pixel(surfaces, x, y), Array(before[from..<(from + 4)]), "(\(x), \(y))"
                )
            }
        }
    }

    /// And sideways, where the rows are the same and only the columns move —
    /// the case a per-row `memmove` handles and a forward byte loop does not.
    func testAnOverlappingSidewaysCopyMovesTheColumns() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        _ = try surfaces.copyBits(
            copyBits(box: rect(0, 3, 8, 8), from: SpiceDisplayWire.Point(x: 0, y: 0))
        )
        for y in 0..<8 {
            for x in 3..<8 {
                let from = (y * 8 + x - 3) * 4
                XCTAssertEqual(
                    pixel(surfaces, x, y), Array(before[from..<(from + 4)]), "(\(x), \(y))"
                )
            }
        }
    }

    /// **The source is clipped as well as the destination.**
    ///
    /// The clip and the box say where pixels are written. Nothing in either
    /// says where they are read, and a scroll that starts above the surface
    /// names a source row that does not exist. The reference intersects the
    /// destination with a rectangle offset by the distance; the effect is that
    /// the rows with no source are left alone rather than filled with the edge.
    func testARegionWithNoSourceIsLeftAloneRatherThanClamped() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        // Move the whole surface down by three: rows 0, 1 and 2 would have to
        // read from rows -3, -2 and -1.
        let written = try surfaces.copyBits(
            copyBits(box: rect(0, 0, 8, 8), from: SpiceDisplayWire.Point(x: 0, y: -3))
        )
        XCTAssertEqual(written, [rect(3, 0, 8, 8)], "les trois premières lignes n'ont pas de source")

        for y in 0..<3 {
            for x in 0..<8 {
                let at = (y * 8 + x) * 4
                XCTAssertEqual(
                    pixel(surfaces, x, y), Array(before[at..<(at + 4)]),
                    "(\(x), \(y)) : inchangé, et surtout pas une copie du bord"
                )
            }
        }
        for y in 3..<8 {
            let from = ((y - 3) * 8) * 4
            XCTAssertEqual(pixel(surfaces, 0, y), Array(before[from..<(from + 4)]))
        }
    }

    func testASourceOffTheRightEdgeIsCutTheSameWay() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        // Move left by three: columns 5, 6 and 7 would read from 8, 9 and 10.
        let written = try surfaces.copyBits(
            copyBits(box: rect(0, 0, 8, 8), from: SpiceDisplayWire.Point(x: 3, y: 0))
        )
        XCTAssertEqual(written, [rect(0, 0, 8, 5)])
        for y in 0..<8 {
            for x in 5..<8 {
                let at = (y * 8 + x) * 4
                XCTAssertEqual(pixel(surfaces, x, y), Array(before[at..<(at + 4)]), "(\(x), \(y))")
            }
        }
    }

    /// A copy that goes nowhere writes nothing *and reports nothing*.
    ///
    /// The second half is the part that matters: reporting a region would make
    /// a renderer repaint a rectangle that did not change, on a message a
    /// server sends more often than it looks.
    func testACopyOntoItselfIsNotADraw() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        let written = try surfaces.copyBits(
            copyBits(box: rect(1, 1, 5, 5), from: SpiceDisplayWire.Point(x: 1, y: 1))
        )
        XCTAssertEqual(written, [])
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before)
    }

    func testTheClipCutsACopyTheSameWayItCutsAFill() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        let written = try surfaces.copyBits(
            copyBits(
                box: rect(0, 0, 8, 8), from: SpiceDisplayWire.Point(x: 0, y: 2),
                clip: .rects([rect(0, 0, 4, 4)])
            )
        )
        XCTAssertEqual(written, [rect(0, 0, 4, 4)])
        // Inside the clip: moved. Outside it: untouched.
        for y in 0..<4 {
            let from = ((y + 2) * 8) * 4
            XCTAssertEqual(pixel(surfaces, 0, y), Array(before[from..<(from + 4)]))
        }
        for y in 0..<4 {
            let at = (y * 8 + 5) * 4
            XCTAssertEqual(pixel(surfaces, 5, y), Array(before[at..<(at + 4)]))
        }
    }

    func testACopyOnASurfaceThatDoesNotExistIsRefused() throws {
        var surfaces = try makeSurface(8, 8)
        var operation = copyBits(box: rect(0, 0, 4, 4), from: SpiceDisplayWire.Point(x: 1, y: 1))
        operation.base.surfaceID = 9
        XCTAssertThrowsError(try surfaces.copyBits(operation)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .unknownSurface(9))
        }
    }

    // MARK: - Black, white, and the complement

    func testBlacknessAndWhitenessWriteTheTwoConstants() throws {
        var surfaces = try makeSurface(4, 4)
        try paintGradient(&surfaces)

        _ = try surfaces.raster(raster(.whiteness, rect(0, 0, 2, 4)))
        _ = try surfaces.raster(raster(.blackness, rect(2, 0, 4, 4)))

        for x in 0..<4 {
            XCTAssertEqual(pixel(surfaces, x, 0), [0xFF, 0xFF, 0xFF, 0], "blanc")
            XCTAssertEqual(pixel(surfaces, x, 3), [0, 0, 0, 0], "noir")
        }
    }

    /// Inverting twice is the identity, which is a stronger statement than
    /// checking one complement: it says the operation reads the pixel it
    /// replaces rather than writing a constant that happens to match.
    func testInvertingTwiceLeavesTheSurfaceExactlyAsItWas() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        _ = try surfaces.raster(raster(.invers, rect(0, 0, 8, 8)))
        XCTAssertNotEqual(surfaces.surfaces[0]!.pixels, before, "sinon rien n'a été inversé")
        _ = try surfaces.raster(raster(.invers, rect(0, 0, 8, 8)))
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before)
    }

    /// **The fourth byte is not the same for the three**, and the asymmetry is
    /// the reference's rather than a slip here: blackness passes `0x000000` and
    /// whiteness `0xffffffff`, so on a surface with alpha one clears it and the
    /// other sets it. Invers is a rop over the whole word and complements it.
    func testTheFourthByteFollowsTheReferencesConstants() throws {
        var surfaces = try makeSurface(4, 4, format: .argb32)
        // An alpha that is neither 0 nor 0xFF, so a complement is visible.
        _ = try surfaces.fill(SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 4, 4), clip: .none),
            brush: .solid(0x3011_2233), rop: 0, mask: noMask()
        ))
        XCTAssertEqual(pixel(surfaces, 0, 0)[3], 0x30, "la préparation a bien pris")

        _ = try surfaces.raster(raster(.whiteness, rect(0, 0, 1, 4)))
        _ = try surfaces.raster(raster(.blackness, rect(1, 0, 2, 4)))
        _ = try surfaces.raster(raster(.invers, rect(2, 0, 3, 4)))

        XCTAssertEqual(pixel(surfaces, 0, 0)[3], 0xFF, "blanc : tous les bits")
        XCTAssertEqual(pixel(surfaces, 0, 1)[3], 0x00, "noir : 0x000000, donc alpha nul")
        XCTAssertEqual(pixel(surfaces, 0, 2)[3], ~UInt8(0x30), "invers : le mot entier")
    }

    func testASurfaceWithoutAlphaKeepsItsFourthByteAtZero() throws {
        var surfaces = try makeSurface(4, 4, format: .xrgb32)
        _ = try surfaces.raster(raster(.whiteness, rect(0, 0, 4, 4)))
        XCTAssertEqual(pixel(surfaces, 2, 2), [0xFF, 0xFF, 0xFF, 0])
        _ = try surfaces.raster(raster(.invers, rect(0, 0, 4, 4)))
        XCTAssertEqual(pixel(surfaces, 2, 2), [0, 0, 0, 0], "l'inversion ne remplit pas le pad")
    }

    // MARK: - The mask that is not honoured

    /// A masked draw is refused, and it is worth being plain about why.
    ///
    /// A `QMask` reduces what a draw touches. wisq does not decode it, so both
    /// available answers are wrong: painting the whole box destroys pixels the
    /// server wanted kept, and painting nothing leaves pixels stale. Refusing
    /// is what this file does everywhere else it cannot carry out a draw, and a
    /// black rectangle across a window is worse to look at than one that did
    /// not change.
    ///
    /// This test pins the behaviour so that decoding the mask later is a change
    /// something notices.
    func testADrawCarryingAMaskIsRefusedRatherThanOverPainted() throws {
        var surfaces = try makeSurface(8, 8)
        try paintGradient(&surfaces)
        let before = surfaces.surfaces[0]!.pixels

        for operation in [SpiceDisplayWire.MaskedRaster.Operation.blackness, .whiteness, .invers] {
            XCTAssertThrowsError(
                try surfaces.raster(raster(operation, rect(0, 0, 8, 8), mask: aMask())),
                "\(operation)"
            ) { error in
                XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable, "\(operation)")
            }
        }

        let masked = SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 8, 8), clip: .none),
            brush: .solid(0x00FF_00FF), rop: 0, mask: aMask()
        )
        XCTAssertThrowsError(try surfaces.fill(masked)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before, "rien n'a été écrit")
    }

    func testADrawWithoutAMaskStillGoesThrough() throws {
        var surfaces = try makeSurface(8, 8)
        let written = try surfaces.raster(raster(.whiteness, rect(0, 0, 8, 8)))
        XCTAssertEqual(written, [rect(0, 0, 8, 8)], "sinon le test au-dessus ne prouve rien")
    }

    // MARK: - The wire

    func testCopyBitsIsBaseThenAPointAndNotARectangle() throws {
        var payload: [UInt8] = []
        payload += SpiceWire.u32(0)                                   // surface
        payload += [3, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 7, 0, 0, 0]   // box: top left bottom right
        payload += [0]                                                // clip: none
        payload += SpiceWire.u32(UInt32(bitPattern: -4))              // src x
        payload += SpiceWire.u32(11)                                  // src y

        let bits = try SpiceDisplayWire.copyBits(payload)
        XCTAssertEqual(bits.base.box, rect(3, 1, 9, 7))
        XCTAssertEqual(bits.source, SpiceDisplayWire.Point(x: -4, y: 11))
    }

    func testTheThreeRastersShareOneShapeAndDifferOnlyInTheMessageType() throws {
        var payload: [UInt8] = []
        payload += SpiceWire.u32(2)                                   // surface
        payload += [0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0]
        payload += [0]                                                // clip: none
        payload += [0]                                                // mask flags
        payload += SpiceWire.u32(0) + SpiceWire.u32(0)                // mask origin
        payload += SpiceWire.u32(0)                                   // mask bitmap: null

        for operation in [SpiceDisplayWire.MaskedRaster.Operation.blackness, .whiteness, .invers] {
            let decoded = try SpiceDisplayWire.maskedRaster(payload, operation)
            XCTAssertEqual(decoded.operation, operation)
            XCTAssertEqual(decoded.base.surfaceID, 2)
            XCTAssertEqual(decoded.base.box, rect(0, 0, 4, 4))
            XCTAssertNil(decoded.mask.bitmap, "un pointeur nul est une absence de masque")
        }
    }
}
