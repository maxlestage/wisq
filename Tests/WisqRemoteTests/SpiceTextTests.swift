import XCTest
@testable import WisqRemote

/// `DRAW_TEXT`: the wire, the glyph mask, and what lands on the surface.
final class SpiceTextTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private func u16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(value >> (8 * $0) & 0xFF) } }

    private func glyph(
        at position: (Int32, Int32), origin: (Int32, Int32) = (0, 0),
        _ width: UInt16, _ height: UInt16, _ data: [UInt8]
    ) -> SpiceDisplayWire.RasterGlyph {
        SpiceDisplayWire.RasterGlyph(
            renderPos: SpiceDisplayWire.Point(x: position.0, y: position.1),
            glyphOrigin: SpiceDisplayWire.Point(x: origin.0, y: origin.1),
            width: width, height: height, data: data
        )
    }

    // MARK: - Le fil

    /// The wire layout, built by hand: a pointer to the string, then the back
    /// area, **two** brushes, and the two modes.
    private func message(
        glyphs: [(pos: (Int32, Int32), origin: (Int32, Int32), w: UInt16, h: UInt16, data: [UInt8])],
        flags: UInt8 = SpiceDisplayWire.TextString.rasterA1,
        backArea: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    ) -> [UInt8] {
        let fixedLength = 21 + 4 + 16 + 5 + 5 + 2 + 2
        var body = u32(0) + i32(0) + i32(0) + i32(16) + i32(16) + [0]
        body += u32(UInt32(fixedLength))
        body += i32(backArea.0) + i32(backArea.1) + i32(backArea.2) + i32(backArea.3)
        body += [1] + u32(0x00FF_FFFF)          // fore brush : blanc
        body += [1] + u32(0x0000_00FF)          // back brush : rouge
        body += u16(0x08) + u16(0x08)
        XCTAssertEqual(body.count, fixedLength, "la partie fixe n'a pas la longueur annoncée")

        body += u16(UInt16(glyphs.count)) + [flags]
        for entry in glyphs {
            body += i32(entry.pos.0) + i32(entry.pos.1)
            body += i32(entry.origin.0) + i32(entry.origin.1)
            body += u16(entry.w) + u16(entry.h) + entry.data
        }
        return body
    }

    func testTheStringIsBehindAPointerAndBothBrushesAreInline() throws {
        let text = try SpiceDisplayWire.text(message(glyphs: [
            (pos: (2, 3), origin: (1, -1), w: 8, h: 2, data: [0b1010_0000, 0b0101_0000]),
        ]))

        XCTAssertEqual(text.foreBrush, .solid(0x00FF_FFFF))
        XCTAssertEqual(text.backBrush, .solid(0x0000_00FF), "la seconde brosse a été lue")
        XCTAssertEqual(text.foreMode, 0x08)
        XCTAssertEqual(text.string.glyphs.count, 1)

        let glyph = text.string.glyphs[0]
        XCTAssertEqual(glyph.renderPos, SpiceDisplayWire.Point(x: 2, y: 3))
        XCTAssertEqual(glyph.glyphOrigin, SpiceDisplayWire.Point(x: 1, y: -1))
        XCTAssertEqual(glyph.data, [0b1010_0000, 0b0101_0000])
    }

    /// **The two points are added, not alternatives.** `render_pos` is where the
    /// cursor sits, `glyph_origin` the glyph's own offset from it — negative for
    /// a descender, left for a kerned pair. Using either alone puts every accent
    /// in the wrong place and reads as a font problem.
    func testAGlyphsBoxIsBothItsPointsAddedTogether() {
        let one = glyph(at: (10, 20), origin: (-2, -5), 6, 8, [])
        XCTAssertEqual(one.box.left, 8)
        XCTAssertEqual(one.box.top, 15)
        XCTAssertEqual(one.box.right, 14)
        XCTAssertEqual(one.box.bottom, 23)
    }

    /// **A1 and A4 pad each row to a byte; A8 does not.**
    ///
    /// The generated parser sizes them `((w+7)/8)·h`, `((4w+7)/8)·h` and `w·h`.
    /// Odd widths are where they disagree — assuming one rule shears every row
    /// of the other two.
    func testTheThreeDepthsDoNotShareAPaddingRule() {
        for (depth, width, expected) in [
            (1, 1, 1), (1, 8, 1), (1, 9, 2), (1, 17, 3),
            (4, 1, 1), (4, 2, 1), (4, 3, 2), (4, 5, 3),
            (8, 1, 1), (8, 9, 9), (8, 17, 17),
        ] {
            XCTAssertEqual(
                SpiceDisplayWire.TextString.bytesPerRow(width: width, depth: depth), expected,
                "profondeur \\(depth), largeur \\(width)"
            )
        }
    }

    /// Each glyph's data length depends on its own width, so a second glyph can
    /// only be found by decoding the first. A wrong stride puts the second
    /// glyph's position somewhere in the first one's bitmap.
    func testASecondGlyphIsFoundOnlyByMeasuringTheFirst() throws {
        let text = try SpiceDisplayWire.text(message(glyphs: [
            (pos: (0, 0), origin: (0, 0), w: 9, h: 2, data: [0xFF, 0x80, 0x00, 0x00]),
            (pos: (12, 4), origin: (0, 0), w: 3, h: 1, data: [0xE0]),
        ]))
        XCTAssertEqual(text.string.glyphs.count, 2)
        XCTAssertEqual(text.string.glyphs[1].renderPos, SpiceDisplayWire.Point(x: 12, y: 4))
        XCTAssertEqual(text.string.glyphs[1].width, 3)
    }

    /// Vector glyphs are the real case: the reference warns and draws nothing.
    /// Refused here rather than half-read, because without a depth there is no
    /// way to know how long each glyph's data is and the walk would
    /// desynchronise.
    ///
    /// **Refused for the right reason**, which is what the assertion has to say.
    ///
    /// A first version only asked that something was thrown, and a sabotage that
    /// silently fell back to eight bits a pixel still threw — a *truncated*,
    /// because a depth-8 read of a four-pixel glyph wants four bytes and only
    /// one followed. Same colour of green, different reason. So the glyph here
    /// carries enough bytes for a depth-8 read to succeed, and the error is
    /// named.
    func testAStringWithNoRasterDepthIsRefused() {
        XCTAssertThrowsError(try SpiceDisplayWire.text(message(
            glyphs: [(pos: (0, 0), origin: (0, 0), w: 4, h: 1,
                      data: [0xF0, 0xF0, 0xF0, 0xF0])],
            flags: 0
        ))) { error in
            XCTAssertEqual(
                error as? SpiceError, .invalidData,
                "une chaîne sans profondeur doit être refusée, pas lue en 8 bits"
            )
        }
    }

    // MARK: - Le masque

    /// **Rows are read bottom-up**, at every depth, whatever `TOP_DOWN` says.
    ///
    /// `canvas_put_glyph_bits` starts at the end of the glyph's data and walks
    /// backwards, above a `//todo: support SPICE_STRING_FLAGS_RASTER_TOP_DOWN`.
    /// Reading top-down turns every letter over.
    func testGlyphRowsAreReadBottomUp() throws {
        let string = SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA1,
            // Deux rangées : la première du fil est celle du BAS.
            glyphs: [glyph(at: (0, 0), 8, 2, [0b1111_1111, 0b0000_0000])]
        )
        let mask = try XCTUnwrap(SpiceGlyphMask.build(string))
        XCTAssertEqual(mask.at(0, 0), 0, "la rangée du haut est la dernière du fil")
        XCTAssertEqual(mask.at(0, 1), 0xFF, "et la rangée du bas est la première")
    }

    /// The `TOP_DOWN` flag changes nothing, deliberately: the reference does not
    /// implement it, and honouring it here would draw text the other way up from
    /// every other client against the same server.
    func testTheTopDownFlagIsDecodedAndDeliberatelyIgnored() throws {
        let data: [UInt8] = [0b1111_1111, 0b0000_0000]
        let plain = SpiceGlyphMask.build(SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA1,
            glyphs: [glyph(at: (0, 0), 8, 2, data)]
        ))
        let flagged = SpiceGlyphMask.build(SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA1 | SpiceDisplayWire.TextString.topDown,
            glyphs: [glyph(at: (0, 0), 8, 2, data)]
        ))
        XCTAssertEqual(plain, flagged)
    }

    /// **The high bit is the leftmost pixel.** The reference runs A1 bytes
    /// through `revers_bits` on the way into pixman's `a1`, which puts the
    /// leftmost pixel in bit 0 — so the glyph's own order is the opposite, and
    /// that reversal is evidence for it rather than something to copy.
    /// **The byte has to be asymmetric**, and the first version of this test was
    /// not: `0b1000_0001` reads the same forwards and backwards, so reversing
    /// the bit order changed nothing and the sabotage survived a test written
    /// to catch it. `0b1100_0100` does not.
    func testTheHighBitIsTheLeftmostPixel() throws {
        let string = SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA1,
            glyphs: [glyph(at: (0, 0), 8, 1, [0b1100_0100])]
        )
        let mask = try XCTUnwrap(SpiceGlyphMask.build(string))
        let lit = (0..<8).map { mask.at($0, 0) == 0xFF }
        XCTAssertEqual(
            lit, [true, true, false, false, false, true, false, false],
            "bit 7 est le pixel de gauche"
        )
    }

    /// **A4 shifts a nibble into the high half rather than scaling it.**
    ///
    /// `dest[i] = MAX(dest[i], *now & 0xf0)` and `dest[i+1] = MAX(dest[i+1],
    /// *now << 4)`. A full nibble is therefore 240, not 255 — A4 text is never
    /// quite opaque. Scaling to 255 would look better and would not be what the
    /// server drew.
    func testAFullA4NibbleIsTwoHundredAndFortyRatherThanOpaque() throws {
        let string = SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA4,
            glyphs: [glyph(at: (0, 0), 2, 1, [0xF8])]
        )
        let mask = try XCTUnwrap(SpiceGlyphMask.build(string))
        XCTAssertEqual(mask.at(0, 0), 0xF0, "le quartet haut est le pixel de gauche")
        XCTAssertEqual(mask.at(1, 0), 0x80, "et le quartet bas remonte dans la moitié haute")
    }

    /// **Overlapping glyphs combine with `max`, not by overwriting.**
    ///
    /// Accents and kerned pairs overlap, and a later glyph must not punch a hole
    /// in an earlier one where its own coverage is zero.
    func testOverlappingGlyphsTakeTheGreaterCoverage() throws {
        // **Le second glyphe doit avoir une couverture non nulle mais plus
        // faible.** La première version de ce test mettait un zéro là où le
        // premier glyphe était opaque, et une couverture nulle est sautée avant
        // d'écrire — écraser et maximiser donnaient donc le même résultat, et le
        // sabotage a survécu au test écrit pour l'attraper.
        let string = SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA8,
            glyphs: [
                glyph(at: (0, 0), 2, 1, [0xFF, 0x20]),
                glyph(at: (0, 0), 2, 1, [0x40, 0x90]),
            ]
        )
        let mask = try XCTUnwrap(SpiceGlyphMask.build(string))
        XCTAssertEqual(mask.at(0, 0), 0xFF, "le second glyphe a écrasé le premier")
        XCTAssertEqual(mask.at(1, 0), 0x90, "et le plus couvrant des deux gagne")
    }

    /// The mask spans the union of the glyph boxes, and remembers where it sits.
    func testTheMaskSpansEveryGlyphAndKnowsWhereItStarts() throws {
        let string = SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA8,
            glyphs: [
                glyph(at: (4, 4), 2, 2, [0xFF, 0xFF, 0xFF, 0xFF]),
                glyph(at: (10, 7), 1, 1, [0xFF]),
            ]
        )
        let mask = try XCTUnwrap(SpiceGlyphMask.build(string))
        XCTAssertEqual(mask.left, 4)
        XCTAssertEqual(mask.top, 4)
        XCTAssertEqual(mask.width, 7)
        XCTAssertEqual(mask.height, 4)
    }

    /// The flag values, written out. `TOP_DOWN` is decoded and never acted on,
    /// so nothing else here can tell if its bit moved — an unused constant is
    /// exactly the kind that rots unnoticed.
    func testTheStringFlagsAreTheReferences() {
        XCTAssertEqual(SpiceDisplayWire.TextString.rasterA1, 0x01)
        XCTAssertEqual(SpiceDisplayWire.TextString.rasterA4, 0x02)
        XCTAssertEqual(SpiceDisplayWire.TextString.rasterA8, 0x04)
        XCTAssertEqual(SpiceDisplayWire.TextString.topDown, 0x08)
        let mask = SpiceDisplayWire.TextString.rasterA1 | SpiceDisplayWire.TextString.rasterA4
            | SpiceDisplayWire.TextString.rasterA8 | SpiceDisplayWire.TextString.topDown
        XCTAssertEqual(mask, 0x0F, "SPICE_STRING_FLAGS_MASK")
    }

    func testAStringWithNoGlyphsHasNoMask() {
        XCTAssertNil(SpiceGlyphMask.build(SpiceDisplayWire.TextString(
            flags: SpiceDisplayWire.TextString.rasterA1, glyphs: []
        )))
    }

    // MARK: - La surface

    private func surfaces() throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: 16, height: 16, format: .xrgb32, flags: 0
        ))
        return surfaces
    }

    private func pixel(_ surfaces: SpiceSurfaces, _ x: Int, _ y: Int) -> [UInt8] {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return Array(surface.pixels[at..<(at + 4)])
    }

    private func operation(
        glyphs: [SpiceDisplayWire.RasterGlyph],
        flags: UInt8 = SpiceDisplayWire.TextString.rasterA8,
        backArea: SpiceDisplayWire.Rect = SpiceDisplayWire.Rect(
            top: 0, left: 0, bottom: 0, right: 0
        )
    ) -> SpiceDisplayWire.Text {
        SpiceDisplayWire.Text(
            base: SpiceDisplayWire.Base(
                surfaceID: 0,
                box: SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 16, right: 16),
                clip: .none
            ),
            string: SpiceDisplayWire.TextString(flags: flags, glyphs: glyphs),
            backArea: backArea,
            foreBrush: .solid(0x00FF_FFFF),
            backBrush: .solid(0x0000_0080),
            foreMode: 0x08, backMode: 0x08
        )
    }

    func testAnOpaqueGlyphLandsAsTheForegroundBrush() throws {
        var surfaces = try surfaces()
        _ = try surfaces.text(operation(glyphs: [glyph(at: (3, 5), 2, 1, [0xFF, 0x00])]))

        XCTAssertEqual(pixel(surfaces, 3, 5), [0xFF, 0xFF, 0xFF, 0])
        XCTAssertEqual(pixel(surfaces, 4, 5), [0, 0, 0, 0], "couverture nulle, rien d'écrit")
    }

    /// Partial coverage blends rather than switching, which is the whole point
    /// of A8 — and of `PIXMAN_OP_OVER` rather than a copy.
    func testPartialCoverageBlendsTowardsTheBrush() throws {
        var surfaces = try surfaces()
        _ = try surfaces.text(operation(glyphs: [glyph(at: (2, 2), 1, 1, [0x80])]))

        let blended = pixel(surfaces, 2, 2)
        XCTAssertGreaterThan(blended[0], 100, "à mi-couverture, à mi-chemin du blanc")
        XCTAssertLessThan(blended[0], 160)
    }

    /// **The background is filled whether or not a glyph lands on it**, and an
    /// empty `back_area` draws none at all — which is the common case,
    /// transparent text.
    func testTheBackAreaIsFilledIndependentlyOfWhereTheGlyphsLand() throws {
        var surfaces = try surfaces()
        _ = try surfaces.text(operation(
            glyphs: [glyph(at: (1, 1), 1, 1, [0xFF])],
            backArea: SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 4, right: 8)
        ))

        XCTAssertEqual(pixel(surfaces, 6, 3), [0x80, 0, 0, 0], "le fond couvre son rectangle")
        XCTAssertEqual(pixel(surfaces, 1, 1), [0xFF, 0xFF, 0xFF, 0], "et le glyphe est par-dessus")
        XCTAssertEqual(pixel(surfaces, 9, 3), [0, 0, 0, 0], "hors du rectangle, rien")
    }

    func testAnEmptyBackAreaDrawsNoBackgroundAtAll() throws {
        var surfaces = try surfaces()
        _ = try surfaces.text(operation(glyphs: [glyph(at: (1, 1), 1, 1, [0xFF])]))
        XCTAssertEqual(pixel(surfaces, 6, 3), [0, 0, 0, 0])
    }

    /// **Transparent text draws even when its background brush is one this
    /// client cannot paint with.**
    ///
    /// That is the common case, and it is why the emptiness of `back_area` has
    /// to be checked *before* the background brush is looked at. Checking the
    /// brush first refuses the whole message — no text at all — over a brush
    /// that was never going to be used. Nothing else in these tests can see the
    /// difference, because an empty rectangle intersects nothing and paints
    /// nothing either way.
    func testTextWithNoBackgroundIsDrawnEvenIfItsBackBrushIsUnpaintable() throws {
        var surfaces = try surfaces()
        var text = operation(glyphs: [glyph(at: (1, 1), 1, 1, [0xFF])])
        text.backBrush = .pattern(image: nil, origin: SpiceDisplayWire.Point(x: 0, y: 0))

        XCTAssertNoThrow(try surfaces.text(text))
        XCTAssertEqual(
            pixel(surfaces, 1, 1), [0xFF, 0xFF, 0xFF, 0],
            "le texte est dessiné : la brosse de fond n'avait rien à peindre"
        )
    }

    /// The clip reduces both halves — the background fill and the glyphs.
    func testTheClipReducesTheBackgroundAndTheGlyphsAlike() throws {
        var surfaces = try surfaces()
        var text = operation(
            glyphs: [glyph(at: (0, 0), 8, 1, Array(repeating: 0xFF, count: 8))],
            backArea: SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 4, right: 16)
        )
        text.base.clip = .rects([SpiceDisplayWire.Rect(top: 0, left: 4, bottom: 16, right: 16)])
        _ = try surfaces.text(text)

        XCTAssertEqual(pixel(surfaces, 2, 0), [0, 0, 0, 0], "glyphe hors clip")
        XCTAssertEqual(pixel(surfaces, 5, 0), [0xFF, 0xFF, 0xFF, 0], "glyphe dans le clip")
        XCTAssertEqual(pixel(surfaces, 2, 3), [0, 0, 0, 0], "fond hors clip")
        XCTAssertEqual(pixel(surfaces, 5, 3), [0x80, 0, 0, 0], "fond dans le clip")
    }

    func testAPatternForegroundBrushIsRefusedRatherThanGuessedAt() throws {
        var surfaces = try surfaces()
        var text = operation(glyphs: [glyph(at: (0, 0), 1, 1, [0xFF])])
        text.foreBrush = .pattern(image: nil, origin: SpiceDisplayWire.Point(x: 0, y: 0))
        XCTAssertThrowsError(try surfaces.text(text)) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }
}
