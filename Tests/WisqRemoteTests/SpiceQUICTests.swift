import XCTest
@testable import WisqRemote

/// The first slice of QUIC: the stream header, and the tables the coder reads
/// on every symbol.
///
/// The tables are the part worth building first. They are pure — a bit depth
/// and a length limit determine them completely, and nothing about a stream
/// changes them — so they can be compared number for number against what the
/// reference computes. Nothing later in this codec can be checked that
/// cleanly, and a mistake here would be paid for on every pixel of every
/// image.
final class SpiceQUICTests: XCTestCase {
    private func header(
        magic: UInt32 = SpiceQUIC.magic, version: UInt32 = 0,
        type: UInt32 = 4, width: UInt32 = 8, height: UInt32 = 6
    ) -> [UInt8] {
        SpiceWire.u32(magic) + SpiceWire.u32(version) + SpiceWire.u32(type)
            + SpiceWire.u32(width) + SpiceWire.u32(height)
    }

    // MARK: - The header

    /// Little-endian, like the display channel around it — and unlike the LZ
    /// stream's header, which is big-endian. Two codecs in one protocol
    /// disagreeing about byte order is exactly the sort of thing a reader
    /// carries over from the file they read last.
    func testTheHeaderIsLittleEndianUnlikeTheLZOneNextDoor() throws {
        let decoded = try SpiceQUIC.header(header(type: 4, width: 320, height: 200))
        XCTAssertEqual(decoded, SpiceQUIC.Header(type: .rgb32, width: 320, height: 200))

        // The magic read the other way round is not the magic.
        let backwards = Array(header().prefix(4).reversed()) + Array(header().dropFirst(4))
        XCTAssertThrowsError(try SpiceQUIC.header(backwards))
    }

    /// The four bytes are `QUIC`, and that is what the constant has to be.
    func testTheMagicIsTheFourLettersInWireOrder() {
        XCTAssertEqual(SpiceWire.u32(SpiceQUIC.magic), Array("QUIC".utf8))
    }

    func testAStreamThatIsNotQUICIsRefusedOnItsMagic() {
        XCTAssertThrowsError(try SpiceQUIC.header(header(magic: 0xDEAD_BEEF))) { error in
            XCTAssertEqual(error as? SpiceQUIC.Failure, .notQUIC(magic: 0xDEAD_BEEF))
        }
    }

    /// Version zero is the only one the codec has ever had. A stream claiming
    /// another is refused rather than decoded hopefully.
    func testAnotherVersionIsRefusedRatherThanAttempted() {
        XCTAssertThrowsError(try SpiceQUIC.header(header(version: 1))) { error in
            XCTAssertEqual(error as? SpiceQUIC.Failure, .unsupportedVersion(1))
        }
    }

    func testAnUnknownOrInvalidImageTypeIsRefused() {
        for type in [UInt32(0 /* INVALID */), 6, 99] {
            XCTAssertThrowsError(try SpiceQUIC.header(header(type: type)), "type \(type)") { error in
                XCTAssertEqual(error as? SpiceQUIC.Failure, .unknownImageType(type))
            }
        }
    }

    /// The dimensions are signed on the wire. A negative one is not a small
    /// image — it is a size that becomes enormous the moment it is multiplied.
    func testANegativeDimensionIsRefusedBeforeAnythingIsSized() {
        let negative = UInt32(bitPattern: -4)
        XCTAssertThrowsError(try SpiceQUIC.header(header(width: negative))) { error in
            XCTAssertEqual(
                error as? SpiceQUIC.Failure, .badGeometry(width: -4, height: 6)
            )
        }
        XCTAssertThrowsError(try SpiceQUIC.header(header(height: 0))) { error in
            XCTAssertEqual(error as? SpiceQUIC.Failure, .badGeometry(width: 8, height: 0))
        }
    }

    func testAHeaderShorterThanTwentyBytesIsRefused() {
        XCTAssertThrowsError(try SpiceQUIC.header(Array(header().prefix(19)))) { error in
            XCTAssertEqual(error as? SpiceQUIC.Failure, .truncated)
        }
    }

    /// The header of a stream the reference encoder actually produced, rather
    /// than one assembled here from the same assumptions.
    func testTheHeaderOfARealEncodedStreamIsRead() throws {
        let stream = SpiceQUICFixtures.all[0]
        let decoded = try SpiceQUIC.header(SpiceQUICFixtures.bytes(stream.stream))
        XCTAssertEqual(decoded.type, stream.type)
        XCTAssertEqual(decoded.width, stream.width)
        XCTAssertEqual(decoded.height, stream.height)
    }

    // MARK: - The family tables

    private func check(
        _ built: SpiceQUIC.Family, against reference: SpiceQUICFamilyFixtures.Reference,
        _ name: String
    ) {
        XCTAssertEqual(built.golombCodewords, reference.golombCodewords, "\(name) : nGRcodewords")
        XCTAssertEqual(built.escapeLength, reference.escapeLength, "\(name) : notGRcwlen")
        XCTAssertEqual(
            built.escapePrefixMask, reference.escapePrefixMask, "\(name) : notGRprefixmask"
        )
        XCTAssertEqual(
            built.escapeSuffixLength, reference.escapeSuffixLength, "\(name) : notGRsuffixlen"
        )
        XCTAssertEqual(built.errorToSymbol, reference.errorToSymbol, "\(name) : xlatU2L")
        XCTAssertEqual(built.symbolToError, reference.symbolToError, "\(name) : xlatL2U")

        // Flattened symbol-major, the order the reference indexes them in.
        XCTAssertEqual(
            built.codeLength.flatMap { $0 }, reference.codeLength, "\(name) : golomb_code_len"
        )
        XCTAssertEqual(built.code.flatMap { $0 }, reference.code, "\(name) : golomb_code")
    }

    /// The whole point of this slice: both families, every number, against the
    /// tables `family_init` filled in.
    func testBothFamiliesMatchTheReferenceNumberForNumber() {
        check(
            SpiceQUIC.family(bitsPerChannel: 8),
            against: SpiceQUICFamilyFixtures.eightBit, "8 bpc"
        )
        check(
            SpiceQUIC.family(bitsPerChannel: 5),
            against: SpiceQUICFamilyFixtures.fiveBit, "5 bpc"
        )
    }

    /// The fold has to be a bijection, or a decoded error is not the error
    /// that was encoded. Checked over the whole range rather than sampled.
    func testFoldingASignedErrorAndUnfoldingItIsARoundTrip() {
        for bpc in [5, 8] {
            let mask = SpiceQUIC.bitMask(bpc)
            let family = SpiceQUIC.family(bitsPerChannel: bpc)
            for value in 0...mask {
                let symbol = family.errorToSymbol[Int(value)]
                XCTAssertEqual(
                    family.symbolToError[Int(symbol)], value,
                    "\(bpc) bpc : \(value) revient sur lui-même"
                )
            }
            XCTAssertEqual(
                Set(family.errorToSymbol.map(UInt32.init)).count, Int(mask) + 1,
                "\(bpc) bpc : la table est une bijection, pas seulement une fonction"
            )
        }
    }

    /// `ceil_log_2` as the reference defines it, which is not the
    /// mathematical one at 1: it answers zero there rather than raising.
    func testCeilingLogTwoFollowsTheReferencesOwnDefinitionAtOne() {
        XCTAssertEqual(SpiceQUIC.ceilingLog2(1), 0)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(2), 1)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(3), 2)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(4), 2)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(5), 3)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(256), 8)
        XCTAssertEqual(SpiceQUIC.ceilingLog2(257), 9)
    }

    /// Computed rather than transcribed, so this pins the rule at both ends
    /// where an off-by-one would hide.
    func testTheBitMaskCoversZeroAndThirtyTwoAsWellAsTheMiddle() {
        XCTAssertEqual(SpiceQUIC.bitMask(0), 0)
        XCTAssertEqual(SpiceQUIC.bitMask(1), 1)
        XCTAssertEqual(SpiceQUIC.bitMask(8), 0xFF)
        XCTAssertEqual(SpiceQUIC.bitMask(31), 0x7FFF_FFFF)
        XCTAssertEqual(SpiceQUIC.bitMask(32), 0xFFFF_FFFF)
    }
    // MARK: - The bit reader

    /// Step for step against the reference's own registers.
    ///
    /// Comparing only the final answer would let the reader be wrong in the
    /// middle and right at the end. Comparing every call says which one
    /// diverged, which on a codec that decodes hundreds of thousands of
    /// symbols is the difference between a bug found and a bug hunted.
    func testTheBitReaderMatchesTheReferenceAtEveryStep() throws {
        for trace in SpiceQUICBitFixtures.all {
            var reader = try SpiceQUIC.BitReader(SpiceQUICFixtures.bytes(trace.stream))
            XCTAssertEqual(
                SpiceQUICBitFixtures.Step(
                    window: reader.window, availableBits: reader.availableBits
                ),
                trace.steps[0], "\(trace.name) : après init"
            )
            for (index, length) in trace.lengths.enumerated() {
                try reader.eat(length)
                XCTAssertEqual(
                    SpiceQUICBitFixtures.Step(
                        window: reader.window, availableBits: reader.availableBits
                    ),
                    trace.steps[index + 1],
                    "\(trace.name) : après eat(\(length)) numéro \(index + 1)"
                )
            }
        }
    }

    /// Both registers start on the *first* word. Priming the lookahead with the
    /// second instead loses the stream by 32 bits — and the magic still reads
    /// correctly, so the mistake survives the first thing anyone checks.
    func testBothRegistersStartOnTheSameFirstWord() throws {
        let reader = try SpiceQUIC.BitReader(SpiceQUICFixtures.bytes(
            SpiceQUICFixtures.all[0].stream
        ))
        XCTAssertEqual(reader.window, SpiceQUIC.magic)
        XCTAssertEqual(reader.lookahead, SpiceQUIC.magic)
        XCTAssertEqual(reader.availableBits, 0)
    }

    /// The reader and the direct header parse have to agree, because the decode
    /// loop continues from where the reader left off while the header was read
    /// separately. If they disagree, every pixel after the header is shifted.
    func testTheReaderAndTheHeaderParserAgreeOnTheSameFiveWords() throws {
        for fixture in SpiceQUICFixtures.all {
            let bytes = SpiceQUICFixtures.bytes(fixture.stream)
            let parsed = try SpiceQUIC.header(bytes)
            var reader = try SpiceQUIC.BitReader(bytes)

            var words: [UInt32] = []
            for _ in 0..<5 {
                words.append(reader.window)
                try reader.eat32()
            }
            XCTAssertEqual(words[0], SpiceQUIC.magic, fixture.name)
            XCTAssertEqual(words[1], 0, fixture.name)
            XCTAssertEqual(words[2], parsed.type.rawValue, fixture.name)
            XCTAssertEqual(Int(words[3]), parsed.width, fixture.name)
            XCTAssertEqual(Int(words[4]), parsed.height, fixture.name)
        }
    }

    /// Running off the end throws rather than reading whatever follows the
    /// buffer. The reference asks its caller for more words and gives up when
    /// there are none; there are never any more here.
    func testReadingPastTheEndOfTheStreamThrows() throws {
        var reader = try SpiceQUIC.BitReader([1, 2, 3, 4, 5, 6, 7, 8])
        // Two words in hand, so the third fetch is the one with nothing behind
        // it. Eating 31 at a time forces a fetch every call.
        XCTAssertThrowsError(
            try { for _ in 0..<8 { try reader.eat(31) } }()
        ) { XCTAssertEqual($0 as? SpiceQUIC.Failure, .truncated) }
    }

    func testAStreamTooShortForOneWordIsRefused() {
        XCTAssertThrowsError(try SpiceQUIC.BitReader([1, 2, 3])) { error in
            XCTAssertEqual(error as? SpiceQUIC.Failure, .truncated)
        }
    }

    // MARK: - The model and its schedule

    /// The chaos table is not randomness and not a seed anyone picks: encoder
    /// and decoder walk the same fixed table so they take the same decisions
    /// in the same order without transmitting any of them. One wrong entry
    /// desynchronises the model rather than corrupting a pixel, so the picture
    /// degrades gradually instead of breaking — the hardest kind of fault to
    /// trace back.
    func testTheChaosDrawsMatchTheReference() {
        XCTAssertEqual(SpiceQUIC.chaosSeed, SpiceQUICModelFixtures.chaosSeed)
        XCTAssertEqual(SpiceQUIC.chaosTable.count, 256)

        var seed = SpiceQUIC.chaosSeed
        let drawn = SpiceQUICModelFixtures.chaosDraws.indices.map { _ in
            SpiceQUIC.chaos(&seed)
        }
        XCTAssertEqual(drawn, SpiceQUICModelFixtures.chaosDraws)
    }

    /// The increment happens before the lookup, so the first draw is entry 0
    /// and not entry 255. Post-increment shifts the whole schedule by one.
    func testTheFirstDrawIsEntryZeroRatherThanTheSeedsOwnEntry() {
        var seed = SpiceQUIC.chaosSeed
        XCTAssertEqual(SpiceQUIC.chaos(&seed), SpiceQUIC.chaosTable[0])
        XCTAssertNotEqual(SpiceQUIC.chaosTable[0], SpiceQUIC.chaosTable[255])
    }

    /// The index is clamped at ten, not wrapped: the table has eleven columns
    /// and the index legitimately walks past them.
    func testTheTriggerTableIsClampedRatherThanWrapped() {
        let expected = SpiceQUICModelFixtures.triggers
        XCTAssertEqual((0...12).map { SpiceQUIC.trigger(waitMaskIndex: $0) }, expected)
        XCTAssertEqual(expected[10], expected[11], "au-delà de dix, la même colonne")
        XCTAssertEqual(expected[11], expected[12])
    }

    /// Buckets grow geometrically, and the last one is stretched rather than
    /// followed by one that would overshoot. Compared against the map the
    /// reference actually built.
    func testTheBucketLayoutMatchesTheReference() {
        let eight = SpiceQUIC.Model(bitsPerChannel: 8)
        XCTAssertEqual(eight.bucketOfValue, SpiceQUICModelFixtures.bucketOfValue8)
        XCTAssertEqual(eight.buckets.count, SpiceQUICModelFixtures.bucketCount8)

        let five = SpiceQUIC.Model(bitsPerChannel: 5)
        XCTAssertEqual(five.bucketOfValue, SpiceQUICModelFixtures.bucketOfValue5)
        XCTAssertEqual(five.buckets.count, SpiceQUICModelFixtures.bucketCount5)
    }

    /// Every counter after every update, against the reference's own trace.
    ///
    /// The sequence crosses the halving threshold, which is the part that
    /// cannot be checked by looking at one update: halving early or late
    /// leaves the model reachable but wrong.
    func testTheModelUpdatesExactlyAsTheReferenceDoes() {
        for (bpc, expected) in [
            (8, SpiceQUICModelFixtures.updates8), (5, SpiceQUICModelFixtures.updates5)
        ] {
            let family = SpiceQUIC.family(bitsPerChannel: bpc)
            let trigger = SpiceQUIC.trigger(waitMaskIndex: 0)
            var model = SpiceQUIC.Model(bitsPerChannel: bpc)

            for (step, update) in expected.enumerated() {
                // Context zero throughout, so every update lands in one bucket
                // and the counters accumulate rather than being spread thin.
                model.update(value: update.value, context: 0, family: family, trigger: trigger)
                XCTAssertEqual(
                    model.buckets[0].bestCode, update.bestCode,
                    "\(bpc) bpc, étape \(step) : le meilleur code"
                )
                XCTAssertEqual(
                    Array(model.buckets[0].counters.prefix(bpc)), update.counters,
                    "\(bpc) bpc, étape \(step) : les compteurs"
                )
            }
        }
    }

    /// Exactly on the trigger, the counters are **not** halved.
    ///
    /// `update_model` halves on strictly greater, and the two readings of that
    /// comparison differ only when the total lands precisely on the trigger —
    /// which no ordinary sequence reaches, because `set_wm_trigger` can only
    /// produce eleven tabulated values. The reference was asked directly, with
    /// the trigger set by hand, and this is its answer.
    ///
    /// Without this the boundary is unpinned: swapping `>` for `>=` passes
    /// every other test in this file.
    func testTheCountersAreNotHalvedExactlyOnTheTrigger() {
        let family = SpiceQUIC.family(bitsPerChannel: 8)

        var onTheLine = SpiceQUIC.Model(bitsPerChannel: 8)
        onTheLine.update(
            value: SpiceQUICModelFixtures.boundaryAt.value, context: 0,
            family: family, trigger: SpiceQUICModelFixtures.boundaryTrigger
        )
        XCTAssertEqual(
            onTheLine.buckets[0].counters, SpiceQUICModelFixtures.boundaryAt.counters,
            "pile sur le seuil : rien n'est divisé"
        )

        var justBelow = SpiceQUIC.Model(bitsPerChannel: 8)
        justBelow.update(
            value: SpiceQUICModelFixtures.boundaryBelow.value, context: 0,
            family: family, trigger: SpiceQUICModelFixtures.boundaryBelowTrigger
        )
        XCTAssertEqual(
            justBelow.buckets[0].counters, SpiceQUICModelFixtures.boundaryBelow.counters,
            "un cran en dessous : tout est divisé par deux"
        )
        XCTAssertNotEqual(
            SpiceQUICModelFixtures.boundaryAt.counters,
            SpiceQUICModelFixtures.boundaryBelow.counters,
            "sinon le test ne distingue rien"
        )
    }

    /// A tie keeps the higher code number, because the scan runs downwards and
    /// replaces only on a strict improvement. Scanning upwards would break
    /// ties the other way and drift away from the encoder over an image.
    func testATieKeepsTheHigherCodeBecauseTheScanRunsDownwards() {
        let family = SpiceQUIC.family(bitsPerChannel: 8)
        var model = SpiceQUIC.Model(bitsPerChannel: 8)
        // Value 0 costs 1, 2, 3 … bits at codes 0, 1, 2 …, so no tie yet; the
        // reference trace above covers the real sequences. Here the point is
        // only the direction, which the first update already shows: with
        // strictly increasing costs the cheapest is code 0.
        model.update(value: 0, context: 0, family: family, trigger: .max)
        XCTAssertEqual(model.buckets[0].bestCode, 0)

        // Make every code cost the same, and the highest must win.
        var flat = SpiceQUIC.Model(bitsPerChannel: 8)
        let uniform = SpiceQUIC.Family(
            golombCodewords: family.golombCodewords,
            escapeLength: family.escapeLength,
            escapePrefixMask: family.escapePrefixMask,
            escapeSuffixLength: family.escapeSuffixLength,
            codeLength: family.codeLength.map { _ in [UInt32](repeating: 5, count: 8) },
            code: family.code,
            errorToSymbol: family.errorToSymbol,
            symbolToError: family.symbolToError
        )
        flat.update(value: 3, context: 0, family: uniform, trigger: .max)
        XCTAssertEqual(
            flat.buckets[0].bestCode, 7,
            "à égalité, le code le plus haut reste — le balayage descend"
        )
    }

    /// `golomb_decoding` is a pure function of the level and the window.
    /// Compared over both families and a wide sweep of windows, including the
    /// two sides of the escape boundary.
    func testGolombDecodingMatchesTheReferenceAcrossBothShapes() {
        for bpc in [5, 8] {
            let family = SpiceQUIC.family(bitsPerChannel: bpc)
            for level in 0..<bpc {
                var sawPlain = false
                var sawEscape = false
                for bits in SpiceQUICTests.windowSweep {
                    let (value, length) = SpiceQUIC.golombDecode(
                        level: level, bits: bits, family: family
                    )
                    XCTAssertGreaterThan(length, 0, "\(bpc)/\(level)/\(bits)")
                    XCTAssertLessThanOrEqual(
                        length, SpiceQUIC.maximumCodeLength, "\(bpc)/\(level)/\(bits)"
                    )
                    if bits > family.escapePrefixMask[level] { sawPlain = true } else { sawEscape = true }
                    // Re-encoding what came out has to give the same codeword
                    // length the family recorded, which is the only closed
                    // check available without a second decoder.
                    if value < 256 {
                        XCTAssertEqual(
                            family.codeLength[Int(value)][level], UInt32(length),
                            "\(bpc) bpc, niveau \(level), fenêtre \(bits)"
                        )
                    }
                }
                XCTAssertTrue(sawPlain, "\(bpc)/\(level) : le balayage doit voir la forme simple")
                XCTAssertTrue(sawEscape, "\(bpc)/\(level) : et la forme échappée")
            }
        }
    }

    /// Windows spanning both sides of every escape boundary.
    private static let windowSweep: [UInt32] = {
        var out: [UInt32] = [0, 1, 2, 0xFFFF_FFFF, 0x8000_0000, 0x7FFF_FFFF]
        for shift in 0..<32 {
            out.append(1 << UInt32(shift))
            out.append((1 << UInt32(shift)) &- 1)
        }
        for step in stride(from: UInt32(0), to: UInt32(0xFFFF_F000), by: 0x0100_0000) {
            out.append(step)
        }
        return out
    }()

}
