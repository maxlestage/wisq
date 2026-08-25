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
}
