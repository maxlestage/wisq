import XCTest
@testable import WisqRemote

/// LZ4 on the display channel.
///
/// The fixtures are the whole argument here: eleven payloads produced by the
/// server's encoding loop, each agreed on by three programs before it was
/// written down. What the tests add is the questions the fixtures cannot ask
/// themselves — what happens to a payload that has been damaged, and whether
/// the two header bytes are read at all.
final class SpiceLZ4Tests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] { SpiceLZ4Fixtures.bytes(hex) }

    private func image(
        _ fixture: SpiceLZ4Fixtures.Case, payload: [UInt8]? = nil
    ) -> SpiceDisplayWire.Image {
        SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .lz4, flags: 0,
                width: UInt32(fixture.width), height: UInt32(fixture.height)
            ),
            bitmap: nil,
            payload: payload ?? bytes(fixture.payload)
        )
    }

    // MARK: - The codec

    func testEveryFixtureDecodesToWhatTheReferenceDecoderProduced() throws {
        for (name, fixture) in SpiceLZ4Fixtures.all {
            let expected = bytes(fixture.rows)
            let (header, rows) = try SpiceLZ4.decode(
                bytes(fixture.payload), width: fixture.width, height: fixture.height
            )
            XCTAssertEqual(header.format.rawValue, fixture.format, "\(name) : format")
            XCTAssertEqual(header.topDown, fixture.topDown, "\(name) : sens")
            XCTAssertEqual(rows.count, expected.count, "\(name) : longueur")
            if rows != expected {
                let at = (0..<min(rows.count, expected.count)).first { rows[$0] != expected[$0] }
                XCTFail("\(name) : premier octet faux à \(at.map(String.init) ?? "?")")
            }
        }
    }

    /// A decode that produced the buffer it was handed — all zeroes — would
    /// pass a comparison against a fixture that was also all zeroes, and prove
    /// nothing at all. So the fixtures are checked for having content before
    /// they are trusted to check anything.
    ///
    /// The bar is deliberately low for all of them and high for some, because
    /// two are *supposed* to be nearly uniform: `longRuns` holds two distinct
    /// byte values and `shortOffsets` three, and that is exactly what makes
    /// their matches long. Demanding variety from those would be demanding they
    /// stop testing what they exist to test.
    func testTheFixturesActuallyCarryContent() {
        for (name, fixture) in SpiceLZ4Fixtures.all {
            let rows = bytes(fixture.rows)
            XCTAssertFalse(rows.isEmpty, "\(name)")
            XCTAssertGreaterThan(Set(rows).count, 1, "\(name) : une seule valeur")
            XCTAssertTrue(rows.contains { $0 != 0 }, "\(name) : rien que des zéros")
        }
        for name in ["crossBlock", "manyBlocks", "incompressible", "withAlpha"] {
            let fixture = try? XCTUnwrap(SpiceLZ4Fixtures.all.first { $0.name == name }?.value)
            XCTAssertGreaterThan(
                Set(bytes(fixture?.rows ?? "")).count, 64,
                "\(name) : censée être une image variée"
            )
        }
    }

    /// **The blocks are not independent.**
    ///
    /// The server compresses them with one `LZ4_stream_t` that lives as long as
    /// the image, so a match in a later block routinely names bytes an earlier
    /// one decoded. This reproduces the mistake — every block decoded on its
    /// own, into its own buffer — and asserts the result is not the picture.
    ///
    /// Seven of the eleven fixtures are wrong that way. Four are not, and they
    /// are named rather than filtered out by a predicate: `independent` has no
    /// cross-block match in it, `oneBlock` has only one block, and
    /// `incompressible` is all literals. Testing only against the seven would
    /// pass just as well with a decoder that never shared anything.
    func testDecodingEachBlockOnItsOwnGetsItWrong() throws {
        let sharing = Set([
            "crossBlock", "longRuns", "shortOffsets", "manyBlocks",
            "fiveFiveFive", "threeBytes", "withAlpha", "bottomUp",
        ])
        for (name, fixture) in SpiceLZ4Fixtures.all {
            let payload = bytes(fixture.payload)
            var perBlock: [UInt8] = []
            var offset = 2
            var failed = false
            while offset + 4 <= payload.count {
                let size =
                    Int(payload[offset]) << 24 | Int(payload[offset + 1]) << 16
                    | Int(payload[offset + 2]) << 8 | Int(payload[offset + 3])
                offset += 4
                guard size > 0, payload.count - offset >= size else { break }
                // A buffer holding nothing but this block: exactly what a
                // decoder that reset the dictionary would have to work with.
                var alone = [UInt8](repeating: 0, count: bytes(fixture.rows).count)
                if let produced = try? SpiceLZ4.block(
                    payload, from: offset, size: size, into: &alone, at: 0
                ) {
                    perBlock += alone[0..<produced]
                } else {
                    failed = true
                }
                offset += size
            }
            let wrong = failed || perBlock != bytes(fixture.rows)
            XCTAssertEqual(
                wrong, sharing.contains(name),
                "\(name) : le partage du dictionnaire entre blocs n'est pas ce qui était attendu"
            )
        }
    }

    // MARK: - The two header bytes

    /// Same blocks, one byte apart: 8 says the fourth byte of a pixel is
    /// padding, 9 says it is alpha.
    func testTheFormatByteIsWhatDecidesWhetherThereIsAlpha() throws {
        let opaque = try XCTUnwrap(
            try SpiceDisplayWire.pixels(of: image(SpiceLZ4Fixtures.crossBlock))
        )
        let translucent = try XCTUnwrap(
            try SpiceDisplayWire.pixels(of: image(SpiceLZ4Fixtures.withAlpha))
        )
        let rows = bytes(SpiceLZ4Fixtures.crossBlock.rows)
        XCTAssertEqual(rows, bytes(SpiceLZ4Fixtures.withAlpha.rows), "mêmes octets décodés")

        let count = SpiceLZ4Fixtures.crossBlock.width * SpiceLZ4Fixtures.crossBlock.height
        var differed = 0
        for pixel in 0..<count {
            for channel in 0..<3 {
                XCTAssertEqual(
                    opaque.pixels[pixel * 4 + channel], rows[pixel * 4 + channel],
                    "la couleur passe telle quelle"
                )
                XCTAssertEqual(
                    translucent.pixels[pixel * 4 + channel], rows[pixel * 4 + channel]
                )
            }
            XCTAssertEqual(opaque.pixels[pixel * 4 + 3], 0xFF, "xRGB n'a pas d'alpha")
            XCTAssertEqual(translucent.pixels[pixel * 4 + 3], rows[pixel * 4 + 3])
            if translucent.pixels[pixel * 4 + 3] != 0xFF { differed += 1 }
        }
        // Without this the test above would pass on an image that happened to
        // be entirely opaque, which is the shape of assertion that agrees with
        // everything.
        XCTAssertGreaterThan(differed, count / 4, "l'alpha de la fixture varie vraiment")
    }

    /// Same blocks again, and this time the byte before: bottom-up means the
    /// first row decoded is the last row on screen.
    func testTheDirectionByteTurnsTheImageOver() throws {
        let down = try XCTUnwrap(
            try SpiceDisplayWire.pixels(of: image(SpiceLZ4Fixtures.crossBlock))
        )
        let up = try XCTUnwrap(
            try SpiceDisplayWire.pixels(of: image(SpiceLZ4Fixtures.bottomUp))
        )
        XCTAssertEqual(
            bytes(SpiceLZ4Fixtures.crossBlock.rows), bytes(SpiceLZ4Fixtures.bottomUp.rows),
            "mêmes octets décodés : seul l'octet de sens diffère"
        )
        XCTAssertNotEqual(down.pixels, up.pixels, "sinon le drapeau n'est pas lu")

        let rowSize = SpiceLZ4Fixtures.crossBlock.width * 4
        for row in 0..<SpiceLZ4Fixtures.crossBlock.height {
            let mirrored = SpiceLZ4Fixtures.crossBlock.height - 1 - row
            XCTAssertEqual(
                Array(down.pixels[(row * rowSize)..<((row + 1) * rowSize)]),
                Array(up.pixels[(mirrored * rowSize)..<((mirrored + 1) * rowSize)]),
                "ligne \(row)"
            )
        }
    }

    /// The four formats the codec carries, and the four it does not.
    ///
    /// The refused list is the reference's `switch` exactly. It is not a gap
    /// waiting to be filled: `get_compression_for_bitmap` downgrades LZ4 to
    /// plain LZ for every format `bitmap_fmt_is_rgb` rejects, so no server
    /// sends the others.
    func testOnlyTheFourRGBFormatsAreCarried() {
        let carried: [SpiceDisplayWire.BitmapFormat] = [
            .sixteenBit, .twentyFourBit, .thirtyTwoBit, .rgba,
        ]
        for format in carried {
            XCTAssertNotNil(SpiceLZ4.bytesPerPixel(format), "\(format)")
        }
        for format in [SpiceDisplayWire.BitmapFormat.oneBitLE, .oneBitBE, .fourBitLE,
                       .fourBitBE, .eightBit, .eightBitAlpha] {
            XCTAssertNil(SpiceLZ4.bytesPerPixel(format), "\(format)")
        }
    }

    func testAFormatThisCodecDoesNotCarryIsNamedRatherThanGuessed() {
        var payload = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        payload[1] = 5      // 8BIT, palettised: never sent as LZ4
        XCTAssertThrowsError(
            try SpiceLZ4.decode(payload, width: 24, height: 12)
        ) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .unsupportedFormat(5))
        }
    }

    /// 0555, and the expansion that repeats the high bits rather than shifting
    /// and leaving zeroes. Two pixels read out of the fixture by hand, because
    /// recomputing them with the same expression the code uses would agree with
    /// a wrong expression.
    func testTheSixteenBitFormatReachesTheFullRange() throws {
        let fixture = SpiceLZ4Fixtures.fiveFiveFive
        let decoded = try XCTUnwrap(try SpiceDisplayWire.pixels(of: image(fixture)))
        let rows = bytes(fixture.rows)
        XCTAssertEqual(rows.count, fixture.width * fixture.height * 2)

        for pixel in [0, 1, 37, fixture.width * fixture.height - 1] {
            let value = UInt16(rows[pixel * 2]) | UInt16(rows[pixel * 2 + 1]) << 8
            let red = UInt8((value >> 10) & 0x1F)
            let green = UInt8((value >> 5) & 0x1F)
            let blue = UInt8(value & 0x1F)
            XCTAssertEqual(decoded.pixels[pixel * 4], blue << 3 | blue >> 2, "bleu \(pixel)")
            XCTAssertEqual(decoded.pixels[pixel * 4 + 1], green << 3 | green >> 2)
            XCTAssertEqual(decoded.pixels[pixel * 4 + 2], red << 3 | red >> 2)
            XCTAssertEqual(decoded.pixels[pixel * 4 + 3], 0xFF)
        }
        // The expansion only matters if the fixture reaches the top of the
        // range somewhere; on a dark image, shifting and repeating agree.
        XCTAssertTrue(decoded.pixels.contains { $0 == 0xFF }, "la fixture atteint le haut")
    }

    func testTheThreeByteFormatIsAlreadyBGR() throws {
        let fixture = SpiceLZ4Fixtures.threeBytes
        let decoded = try XCTUnwrap(try SpiceDisplayWire.pixels(of: image(fixture)))
        let rows = bytes(fixture.rows)
        XCTAssertEqual(rows.count, fixture.width * fixture.height * 3)
        for pixel in 0..<(fixture.width * fixture.height) {
            XCTAssertEqual(Array(decoded.pixels[(pixel * 4)..<(pixel * 4 + 3)]),
                           Array(rows[(pixel * 3)..<(pixel * 3 + 3)]), "pixel \(pixel)")
            XCTAssertEqual(decoded.pixels[pixel * 4 + 3], 0xFF)
        }
    }

    // MARK: - Damaged payloads

    /// Big-endian, in a protocol that is little-endian everywhere else.
    ///
    /// Reversed, the first block's length reads as some hundreds of megabytes
    /// and the payload looks truncated — an error that names the wrong thing,
    /// which is why the byte order is worth a test of its own.
    func testTheBlockLengthIsBigEndian() {
        var payload = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        payload[2...5].reverse()
        XCTAssertThrowsError(try SpiceLZ4.decode(payload, width: 24, height: 12))
    }

    func testAPayloadCutShortIsRefused() {
        let whole = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        for cut in [0, 1, 2, 5, 40, whole.count - 1] {
            XCTAssertThrowsError(
                try SpiceLZ4.decode(Array(whole.prefix(cut)), width: 24, height: 12),
                "coupé à \(cut)"
            )
        }
    }

    /// The payload carries no geometry of its own, so the descriptor's is taken
    /// on trust for the row length — and the only thing that catches a
    /// disagreement is the total. Without that check a width one pixel out
    /// would produce a picture, sheared.
    func testGeometryThatDisagreesWithThePayloadIsRefused() {
        let payload = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        // A buffer bigger than the pixels reaches the end with room to spare,
        // and it is the total that catches it.
        for (width, height) in [(25, 12), (24, 13)] {
            XCTAssertThrowsError(
                try SpiceLZ4.decode(payload, width: width, height: height),
                "\(width)x\(height)"
            ) { error in
                guard case .wrongSize = error as? SpiceLZ4.Failure else {
                    return XCTFail("\(width)x\(height) : \(error)")
                }
            }
        }
        // A buffer smaller than the pixels is caught earlier and harder: the
        // block runs out of output part-way and the bounds refuse it. Named as
        // a different failure because it *is* one — the payload never finished.
        for (width, height) in [(23, 12), (24, 11)] {
            XCTAssertThrowsError(
                try SpiceLZ4.decode(payload, width: width, height: height),
                "\(width)x\(height)"
            ) { error in
                XCTAssertEqual(error as? SpiceLZ4.Failure, .badBlock, "\(width)x\(height)")
            }
        }
        for (width, height) in [(0, 12), (24, 0), (-1, 12), (1 << 20, 1 << 20)] {
            XCTAssertThrowsError(
                try SpiceLZ4.decode(payload, width: width, height: height), "\(width)x\(height)"
            ) { error in
                XCTAssertEqual(error as? SpiceLZ4.Failure, .badGeometry, "\(width)x\(height)")
            }
        }
    }

    /// A match may not reach back before the first byte the image decoded. The
    /// distance is sixteen bits, so the way to reach outside is to place a big
    /// one early — here, in the first block, where nothing precedes it.
    func testAMatchReachingBeforeTheImageIsRefused() {
        // One block: a token with four literals and a match, a distance of
        // 0x0100, and enough trailing literals to satisfy the end rules.
        var block: [UInt8] = [0x40, 1, 2, 3, 4, 0x00, 0x01]
        block += [0x60] + [UInt8](repeating: 9, count: 6)
        var payload: [UInt8] = [1, 8]
        payload += [0, 0, 0, UInt8(block.count)] + block
        XCTAssertThrowsError(try SpiceLZ4.decode(payload, width: 4, height: 1)) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .badBlock)
        }
    }

    func testADistanceOfZeroIsRefused() {
        var block: [UInt8] = [0x40, 1, 2, 3, 4, 0x00, 0x00]
        block += [0x60] + [UInt8](repeating: 9, count: 6)
        var payload: [UInt8] = [1, 8]
        payload += [0, 0, 0, UInt8(block.count)] + block
        XCTAssertThrowsError(try SpiceLZ4.decode(payload, width: 4, height: 1)) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .badBlock)
        }
    }

    /// A block whose length is zero, or that decodes to nothing, is refused
    /// rather than skipped — otherwise a payload could pad itself out after the
    /// pixels were already complete.
    func testABlockThatProducesNothingIsRefused() {
        var payload = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        payload += [0, 0, 0, 1, 0]
        XCTAssertThrowsError(try SpiceLZ4.decode(payload, width: 24, height: 12))

        var zero = bytes(SpiceLZ4Fixtures.crossBlock.payload)
        zero += [0, 0, 0, 0]
        XCTAssertThrowsError(try SpiceLZ4.decode(zero, width: 24, height: 12)) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .truncated)
        }
    }

    /// A literal run of exactly fourteen.
    ///
    /// Fourteen is the value that separates "the nibble is the length" from
    /// "the nibble is 15 and the length continues in the bytes after it", and
    /// none of the eleven generated fixtures happens to contain one — a
    /// decoder that took 14 as the escape passed every one of them. So this
    /// block is written by hand and checked against lz4's own decoder before
    /// being written down here: seven rgb16 pixels, one token, fourteen
    /// literals, nothing else.
    func testALiteralRunOfExactlyFourteenIsNotAnEscape() throws {
        let payload = bytes("01060000000fe00102030405060708090a0b0c0d0e")
        let (header, rows) = try SpiceLZ4.decode(payload, width: 7, height: 1)
        XCTAssertEqual(header.format, .sixteenBit)
        XCTAssertTrue(header.topDown)
        XCTAssertEqual(rows, Array(1...14))
    }

    /// A block whose last match leaves too little input behind it is refused.
    ///
    /// This test began life claiming something else — that it pinned lz4's
    /// "a match may not finish inside the last five bytes of the output" rule.
    /// It does not, and the way that came out is worth keeping: the rule was
    /// removed from the decoder and every test still passed, including this
    /// one. Tracing the block showed it is refused three sequences earlier, by
    /// the *input* restriction, and never reaches the output one at all.
    ///
    /// The two rules cannot be separated, and that is arithmetic rather than an
    /// accident of these bytes. A match may only be read at all if the sequence
    /// before it left eight bytes of input spare; the sequence after it must be
    /// a literal run that both consumes the input exactly and brings the output
    /// to its end. Put those together and a match ending within five bytes of
    /// the output end needs at most four trailing literals, which needs at most
    /// seven trailing input bytes, which is fewer than the eight the earlier
    /// check demanded. So no stream reaches it. Four hundred thousand random
    /// blocks and a hundred and fifty thousand mutations of real ones found
    /// none either, in a decoder run twice with the rule on and off.
    ///
    /// It stays in the code because it is lz4's, and because "unreachable
    /// today" is a property of the other bounds rather than of this one. What
    /// is tested here is the bound that does the work.
    ///
    /// Both blocks below were run through lz4 first: it refuses the first with
    /// error -15 and decodes the second.
    func testABlockThatRunsOutOfInputBeforeItsLastLiteralsIsRefused() throws {
        let tooLate = bytes("01080000001340aabbccdd04000e04000e04000e0400201122")
        XCTAssertThrowsError(
            try SpiceLZ4.decode(tooLate, width: 16, height: 1)
        ) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .badBlock)
        }

        let clear = bytes("01080000001940aabbccdd04000e04000e0400080400803031323334353637")
        let (_, rows) = try SpiceLZ4.decode(clear, width: 16, height: 1)
        XCTAssertEqual(
            rows,
            bytes("""
                aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd
                aabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd3031323334353637
                """),
            "sinon le refus ci-dessus ne prouve rien"
        )
    }

    /// **A distance of zero is refused here and is not by lz4.**
    ///
    /// The block format says a zero offset "denotes an invalid (corrupted)
    /// block", and a conformant decoder may reject it. lz4's own decoder does
    /// not: it has a deliberate `LZ4_write32(op, 0)` on the `offset < 8` path,
    /// commented as silencing a memory-sanitiser warning, and the effect is
    /// that a zero distance copies a pixel from itself and produces a run of
    /// zeroes. So the reference client would draw something.
    ///
    /// wisq refuses instead, and this is the one place the two decoders decide
    /// differently on a payload lz4 accepts. It was found by fuzzing against
    /// the reference rather than by reading, and the choice is deliberate: no
    /// encoder emits a zero offset, so a stream carrying one is damaged, and
    /// drawing a band of black from damaged data is worse than drawing nothing.
    func testAZeroDistanceIsRefusedWhereTheReferenceWouldDrawBlack() {
        let payload = bytes("01080000000b1f000100275000000000000000000a0f000028500000000000")
        XCTAssertThrowsError(try SpiceLZ4.decode(payload, width: 8, height: 4)) { error in
            XCTAssertEqual(error as? SpiceLZ4.Failure, .badBlock)
        }
    }

    /// Every single-byte change to a block is either decoded to something or
    /// refused, and never reads outside its buffers or traps.
    ///
    /// The interesting number is not how many throw. It is that the loop
    /// finishes: an out-of-bounds subscript in Swift is a crash, not a wrong
    /// answer, so this is the test that would have caught a missing bound
    /// rather than a wrong one.
    func testEveryDamagedByteIsEitherDecodedOrRefused() {
        let whole = bytes(SpiceLZ4Fixtures.longRuns.payload)
        var refused = 0
        for index in 0..<whole.count {
            for flip in [UInt8(0x01), 0x80, 0xFF] {
                var damaged = whole
                damaged[index] ^= flip
                do {
                    let (_, rows) = try SpiceLZ4.decode(damaged, width: 24, height: 12)
                    XCTAssertEqual(rows.count, 24 * 12 * 4)
                } catch {
                    refused += 1
                }
            }
        }
        XCTAssertGreaterThan(refused, 0, "aucune modification refusée : le test ne teste rien")
    }
}
