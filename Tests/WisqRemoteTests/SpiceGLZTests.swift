import XCTest
@testable import WisqRemote

/// The GLZ header, against streams SPICE's own encoder produced.
///
/// The header is the one self-contained part of GLZ, so it is the one part
/// that can be checked exactly before any window exists. Everything after it
/// needs earlier images to reach into.
final class SpiceGLZTests: XCTestCase {
    func testEveryHeaderInTheSequenceReadsAsTheEncoderWroteIt() throws {
        for (index, fixture) in SpiceGLZFixtures.sequence.enumerated() {
            let header = try SpiceGLZ.header(SpiceGLZFixtures.bytes(fixture.stream))
            XCTAssertEqual(header.type, .rgb32, "image \(index)")
            XCTAssertEqual(header.width, SpiceGLZFixtures.width, "image \(index)")
            XCTAssertEqual(header.height, SpiceGLZFixtures.height, "image \(index)")
            XCTAssertEqual(header.stride, SpiceGLZFixtures.width * 4, "image \(index)")
            XCTAssertTrue(header.topDown, "image \(index)")
            XCTAssertEqual(header.id, fixture.id, "image \(index)")
            XCTAssertEqual(
                header.winHeadDistance, fixture.winHeadDistance, "image \(index)"
            )
        }
    }

    /// The ids run 0, 1, 2, 3 and the distances run with them. That is what
    /// makes this a sequence rather than four unrelated streams, and it is the
    /// thing the window will be indexed by.
    func testTheSequenceIsActuallyASequence() throws {
        let headers = try SpiceGLZFixtures.sequence.map {
            try SpiceGLZ.header(SpiceGLZFixtures.bytes($0.stream))
        }
        XCTAssertEqual(headers.map(\.id), [0, 1, 2, 3])
        // `id - winHeadDistance` is the oldest image each stream may still
        // reach into. Here every one of them may reach all the way back to 0.
        XCTAssertEqual(
            headers.map { $0.id - UInt64($0.winHeadDistance) }, [0, 0, 0, 0]
        )
    }

    /// **33 bytes, not LZ's 28.** The two headers agree on their first eight
    /// bytes — magic and version — and diverge immediately after, so a reader
    /// that takes GLZ for LZ passes its only cheap check and then misreads
    /// everything.
    ///
    /// Read as LZ, the packed type/top_down byte becomes the top byte of a
    /// 32-bit type word, and what comes out is neither the right type nor the
    /// right anything after it.
    func testAGLZHeaderIsNotAnLZHeader() throws {
        let raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        let glz = try SpiceGLZ.header(raw)

        var reader = SpiceLZ.Reader(raw)
        let asLZ = try? SpiceLZ.header(from: &reader)
        XCTAssertNotEqual(asLZ?.width, glz.width, "sinon les deux lectures seraient interchangeables")
        XCTAssertEqual(SpiceGLZ.headerBytes, 33)
    }

    /// The type and the orientation share one byte: the low nibble is the type,
    /// the bit just above it is `top_down`. Not the byte's top bit — a reader
    /// that takes `0x80` gets every GLZ image's orientation wrong and nothing
    /// else, which is a bug that hides behind whichever way up the server
    /// happens to send.
    func testTheTypeAndTheOrientationShareOneByte() throws {
        var raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        XCTAssertEqual(raw[8], 0x18, "type 8 dans le quartet bas, top_down au bit 4")

        raw[8] = 0x08
        let bottomUp = try SpiceGLZ.header(raw)
        XCTAssertFalse(bottomUp.topDown)
        XCTAssertEqual(bottomUp.type, .rgb32, "le type ne bouge pas avec l'orientation")

        raw[8] = 0x86
        let other = try SpiceGLZ.header(raw)
        XCTAssertEqual(other.type, .rgb16)
        XCTAssertFalse(other.topDown, "le bit 7 n'est pas top_down")
    }

    func testSomethingThatIsNotAGLZStreamIsRefusedOnItsMagic() {
        XCTAssertThrowsError(try SpiceGLZ.header([UInt8](repeating: 0x41, count: 40))) {
            XCTAssertEqual($0 as? SpiceGLZ.Failure, .notGLZ)
        }
    }

    func testAHeaderShorterThanThirtyThreeBytesIsRefused() throws {
        let raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        for length in 0..<SpiceGLZ.headerBytes {
            XCTAssertThrowsError(try SpiceGLZ.header(Array(raw.prefix(length))), "\(length)") {
                XCTAssertEqual($0 as? SpiceGLZ.Failure, .truncated, "\(length)")
            }
        }
        XCTAssertNoThrow(try SpiceGLZ.header(Array(raw.prefix(SpiceGLZ.headerBytes))))
    }

    func testANegativeDimensionIsRefusedBeforeAnythingIsSized() throws {
        var raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        raw[9] = 0xFF   // the top byte of the width
        XCTAssertThrowsError(try SpiceGLZ.header(raw)) {
            XCTAssertEqual($0 as? SpiceGLZ.Failure, .badGeometry)
        }
    }

    func testAnUnknownImageTypeIsRefused() throws {
        var raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        raw[8] = 0x0F   // no such type
        XCTAssertThrowsError(try SpiceGLZ.header(raw)) {
            XCTAssertEqual($0 as? SpiceGLZ.Failure, .unknownImageType(0x0F))
        }
    }

    func testAnotherVersionIsRefusedRatherThanAttempted() throws {
        var raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        raw[5] = 0x02
        XCTAssertThrowsError(try SpiceGLZ.header(raw)) {
            XCTAssertEqual($0 as? SpiceGLZ.Failure, .unsupportedVersion(major: 2, minor: 1))
        }
    }
}
