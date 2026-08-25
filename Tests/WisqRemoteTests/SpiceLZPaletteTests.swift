import XCTest
@testable import WisqRemote

/// The palette forms of LZ, checked against SPICE's own encoder and decoder.
///
/// Every fixture here carries three things: the stream the reference encoder
/// produced, the palette exactly as it travels in a display message, and the
/// pixels the reference *decoder* made of the two. So a disagreement is a
/// disagreement with the codec, not with a reading of it.
///
/// That matters more here than for the RGB forms, because three of the rules
/// produce an image when written backwards rather than an error — a mirrored
/// pair of pixels, a mirrored group of eight, or a colour table read the wrong
/// way round. All three were checked against this output before the decoder was
/// written, which is the only order in which that check means anything.
final class SpiceLZPaletteTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        let hex = hex.filter { !$0.isWhitespace }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func palette(_ fixture: SpiceLZPaletteFixtures.Case) throws -> SpiceLZ.Palette {
        var reader = SpiceLZ.Reader(bytes(fixture.palette))
        return try SpiceLZ.palette(from: &reader)
    }

    /// The test the whole exercise is for: every reference stream, expanded
    /// through its palette, is exactly what the reference decoder produced.
    func testEveryPaletteStreamExpandsToWhatTheReferenceDecoderProduced() throws {
        for fixture in SpiceLZPaletteFixtures.all {
            let (header, indices) = try SpiceLZ.decompress(bytes(fixture.stream))
            XCTAssertEqual(header.type, fixture.type, fixture.name)
            XCTAssertEqual(header.width, fixture.width, fixture.name)

            let pixels = try SpiceLZ.pixels(
                fromIndices: indices, type: fixture.type,
                width: fixture.width, height: fixture.height,
                palette: try palette(fixture)
            )
            let expected = bytes(fixture.expected)
            XCTAssertEqual(pixels.count, expected.count, "\(fixture.name) : longueur")
            if pixels != expected {
                let at = (0..<min(pixels.count, expected.count)).first { pixels[$0] != expected[$0] }
                XCTFail("""
                \(fixture.name) (\(fixture.note)) : \
                premier octet différent à \(at ?? -1) — \
                obtenu \(at.map { String(pixels[$0], radix: 16) } ?? "?"), \
                attendu \(at.map { String(expected[$0], radix: 16) } ?? "?")
                """)
            }
        }
    }

    /// The palette is little-endian while the LZ stream header above it is
    /// big-endian. The two orders genuinely meet inside one message, because
    /// the palette belongs to the display channel and the stream to the codec.
    /// Read either with the other's helper and the colour table is nonsense.
    func testThePaletteIsLittleEndianWhileTheStreamHeaderIsBig() throws {
        let fixture = SpiceLZPaletteFixtures.all[0]
        let decoded = try palette(fixture)
        XCTAssertEqual(decoded.unique, 1, "un u64 petit-boutiste, pas 0x0100000000000000")
        XCTAssertEqual(decoded.colours.count, 256)

        // And the stream's own magic still reads big-endian, in the same test,
        // so the two cannot quietly become one convention.
        var stream = SpiceLZ.Reader(bytes(fixture.stream))
        XCTAssertEqual(try stream.u32(), SpiceLZ.magic)
    }

    /// The two four-bit orders differ only in which nibble comes first, so a
    /// decoder that picks the wrong one still produces an image — mirrored in
    /// pairs. The fixtures are the same picture in both orders, which is what
    /// makes this checkable at all.
    func testTheFourBitOrdersAreNotInterchangeable() throws {
        let little = try XCTUnwrap(SpiceLZPaletteFixtures.all.first { $0.type == .palette4LE })
        let big = try XCTUnwrap(SpiceLZPaletteFixtures.all.first { $0.type == .palette4BE })

        let (_, indices) = try SpiceLZ.decompress(bytes(little.stream))
        let asLittle = try SpiceLZ.pixels(
            fromIndices: indices, type: .palette4LE,
            width: little.width, height: little.height, palette: try palette(little)
        )
        let asBig = try SpiceLZ.pixels(
            fromIndices: indices, type: .palette4BE,
            width: little.width, height: little.height, palette: try palette(little)
        )
        XCTAssertNotEqual(asLittle, asBig, "les deux ordres doivent différer")
        XCTAssertEqual(asLittle, bytes(little.expected))

        // And the same the other way: the `BE` stream read as `LE` is not what
        // the reference decoder made of it.
        //
        // Note what is *not* asserted here. The two fixtures compress the same
        // source bytes, so the `LE` stream read as `BE` equals the `BE`
        // fixture's own output — the streams are identical and only the
        // interpretation differs. An earlier version of this test claimed
        // otherwise and failed, which is the test being wrong rather than the
        // decoder.
        let (_, bigIndices) = try SpiceLZ.decompress(bytes(big.stream))
        let bigAsLittle = try SpiceLZ.pixels(
            fromIndices: bigIndices, type: .palette4LE,
            width: big.width, height: big.height, palette: try palette(big)
        )
        XCTAssertNotEqual(bigAsLittle, bytes(big.expected))
    }

    /// Same for the one-bit forms, where a wrong order mirrors every group of
    /// eight pixels.
    func testTheOneBitOrdersAreNotInterchangeable() throws {
        let little = try XCTUnwrap(SpiceLZPaletteFixtures.all.first { $0.type == .palette1LE })
        let (_, indices) = try SpiceLZ.decompress(bytes(little.stream))

        let asLittle = try SpiceLZ.pixels(
            fromIndices: indices, type: .palette1LE,
            width: little.width, height: little.height, palette: try palette(little)
        )
        let asBig = try SpiceLZ.pixels(
            fromIndices: indices, type: .palette1BE,
            width: little.width, height: little.height, palette: try palette(little)
        )
        XCTAssertNotEqual(asLittle, asBig)
        XCTAssertEqual(asLittle, bytes(little.expected))
    }

    /// Rows start on byte boundaries. A five-pixel-wide four-bit image spends
    /// three bytes a row and wastes the last half-byte; reading straight
    /// through would shear every row after the first.
    func testARowStartsOnAByteBoundaryRatherThanWhereTheLastOneEnded() throws {
        let palette = SpiceLZ.Palette(unique: 0, colours: [0x0000_0000, 0x00FF_FFFF])
        // Two rows of five pixels, 1 bit each: one byte a row, three bits spare.
        // First row all zero, second row all one.
        let indices: [UInt8] = [0b0000_0000, 0b1111_1111]
        let pixels = try SpiceLZ.pixels(
            fromIndices: indices, type: .palette1LE, width: 5, height: 2, palette: palette
        )
        XCTAssertEqual(pixels.count, 5 * 2 * 4)
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0, 0], "premier pixel de la ligne 1")
        XCTAssertEqual(Array(pixels[20..<24]), [0xFF, 0xFF, 0xFF, 0], "premier pixel de la ligne 2")
    }

    /// A palette form arriving with no palette is named rather than filled with
    /// black. A screen of black is a picture, and a wrong one.
    func testAPaletteFormWithNoPaletteIsNamedRatherThanFilledWithBlack() {
        XCTAssertThrowsError(try SpiceLZ.pixels(
            fromIndices: [0, 1, 2, 3], type: .palette8, width: 2, height: 2,
            palette: SpiceLZ.Palette(unique: 0, colours: [])
        )) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .missingPalette)
        }
    }

    /// Fewer indices than the image claims is refused, not padded.
    func testFewerIndicesThanTheImageClaimsIsRefused() {
        XCTAssertThrowsError(try SpiceLZ.pixels(
            fromIndices: [0], type: .palette8, width: 4, height: 4,
            palette: SpiceLZ.Palette(unique: 0, colours: [1, 2])
        )) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .truncated)
        }
    }

    /// An index past the end of the palette wraps, which is what the codec
    /// itself does. A broken image is not a reason to drop the connection.
    func testAnIndexPastTheEndOfThePaletteWrapsRatherThanThrowing() throws {
        let pixels = try SpiceLZ.pixels(
            fromIndices: [5], type: .palette8, width: 1, height: 1,
            palette: SpiceLZ.Palette(unique: 0, colours: [0x0011_2233, 0x0044_5566])
        )
        // 5 % 2 == 1, so the second colour: 0x00445566 -> b=66, g=55, r=44.
        XCTAssertEqual(pixels, [0x66, 0x55, 0x44, 0])
    }

    /// The forms that are still not decoded stay named apart from the ones that
    /// are, so "work not done" does not quietly become "broken stream".
    func testTheFormsStillNotDecodedAreNamedApart() {
        for type in [SpiceLZ.ImageType.rgba, .xxxa, .a8] {
            XCTAssertNil(SpiceLZ.pixelsPerByte(type), "\(type)")
        }
        for type in [SpiceLZ.ImageType.palette8, .palette4LE, .palette1BE] {
            XCTAssertNotNil(SpiceLZ.pixelsPerByte(type), "\(type)")
        }
    }
    /// The whole path, end to end: a real `LZ_PLT` message assembled the way
    /// the display channel carries one — flags, size, a palette behind a
    /// pointer, then the stream — decoded through the same entry point the
    /// session uses, and compared against what the reference decoder produced.
    ///
    /// Until now the palette codec was finished and unreachable: `pixels(of:)`
    /// dispatched only `lzRGB`, so every one of these streams arrived and
    /// nothing drew it.
    func testAPalettisedStreamArrivesThroughTheDisplayMessage() throws {
        for fixture in SpiceLZPaletteFixtures.all {
            let stream = bytes(fixture.stream)
            let table = bytes(fixture.palette)

            // The palette goes after the stream, and the pointer reaches back
            // to it — the ordinary arrangement in one of these messages.
            var message = [UInt8](repeating: 0, count: 4)
            let offset = UInt32(message.count)
            message += SpiceWire.u64(9) + [100 /* LZ_PLT */, 0]
            message += SpiceWire.u32(UInt32(fixture.width))
            message += SpiceWire.u32(UInt32(fixture.height))
            message += [0]                                  // flags: palette inline
            message += SpiceWire.u32(UInt32(stream.count))
            let palettePointer = UInt32(message.count + 4 + stream.count)
            message += SpiceWire.u32(palettePointer)
            message += stream
            message += table

            let body = SpiceDisplayWire.Body(message)
            guard let image = try SpiceDisplayWire.image(at: offset, in: body) else {
                return XCTFail("\(fixture.name) : l'image doit se lire")
            }
            XCTAssertEqual(image.payload, stream, "\(fixture.name) : le flux entier")

            guard let decoded = try SpiceDisplayWire.pixels(of: image) else {
                return XCTFail("\(fixture.name) : l'image doit se dessiner")
            }
            XCTAssertEqual(decoded.width, fixture.width, fixture.name)
            XCTAssertEqual(decoded.height, fixture.height, fixture.name)
            XCTAssertEqual(
                decoded.pixels, bytes(fixture.expected),
                "\(fixture.name) (\(fixture.note)) : les pixels du décodeur de référence"
            )
        }
    }

    /// A palettised stream that says it is bottom-up must come back flipped,
    /// like an `lzRGB` one — and through the same entry point the session uses,
    /// not by calling the flip directly.
    ///
    /// Worth its own test rather than trusting the RGB one, because every
    /// fixture the reference encoder produced has `top_down = 1`: the flip is
    /// simply never reached on this route by any other test, and a sabotage
    /// that hard-codes it away passes without this. That is the same blind
    /// spot that let the flag be parsed and ignored for as long as it was.
    func testAPalettisedStreamThatSaysBottomUpComesBackFlipped() throws {
        let fixture = SpiceLZPaletteFixtures.all[0]
        var stream = bytes(fixture.stream)
        // `top_down` is the seventh word of the LZ header.
        XCTAssertEqual(Array(stream[24..<28]), [0, 0, 0, 1], "le gabarit est de haut en bas")
        stream[27] = 0

        var message = [UInt8](repeating: 0, count: 4)
        let offset = UInt32(message.count)
        message += SpiceWire.u64(9) + [100 /* LZ_PLT */, 0]
        message += SpiceWire.u32(UInt32(fixture.width))
        message += SpiceWire.u32(UInt32(fixture.height))
        message += [0]
        message += SpiceWire.u32(UInt32(stream.count))
        message += SpiceWire.u32(UInt32(message.count + 4 + stream.count))
        message += stream
        message += bytes(fixture.palette)

        let body = SpiceDisplayWire.Body(message)
        guard let image = try SpiceDisplayWire.image(at: offset, in: body),
              let decoded = try SpiceDisplayWire.pixels(of: image) else {
            return XCTFail("l'image doit se lire et se dessiner")
        }

        let upright = bytes(fixture.expected)
        let rowSize = fixture.width * 4
        var expected: [UInt8] = []
        for row in (0..<fixture.height).reversed() {
            expected += upright[(row * rowSize)..<((row + 1) * rowSize)]
        }
        XCTAssertEqual(decoded.pixels, expected)
        XCTAssertNotEqual(
            decoded.pixels, upright, "sinon le gabarit a toutes ses lignes identiques"
        )
    }

}
