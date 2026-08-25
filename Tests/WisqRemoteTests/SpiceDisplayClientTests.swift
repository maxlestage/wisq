import XCTest
@testable import WisqRemote

/// What the client says to the display channel.
///
/// The interesting assertions here are not about byte layout. They are about a
/// decision: wisq decodes LZ and nothing else, so it must *ask* for LZ, and
/// the tests below pin the two ways that can go wrong — asking a server that
/// cannot be asked, and asking for a mode that lets the server send something
/// else anyway.
final class SpiceDisplayClientTests: XCTestCase {
    /// A capability is a bit index, not a value. Read as a value, capability 6
    /// would be "the word equals 6" and every check would be wrong in a way
    /// that happens to be right for capability 1 and 2.
    func testACapabilityIsABitPositionRatherThanAValue() {
        // Bit 6 set, and nothing else.
        XCTAssertTrue(SpiceDisplayClient.supports(.preferredCompression, in: [0b0100_0000]))
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: [6]))
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: [0b0010_0000]))

        // And each capability is its own bit, not a shared one.
        let words = SpiceDisplayClient.capabilityWords([.preferredCompression, .sizedStream])
        XCTAssertEqual(words, [0b0100_0001])
        XCTAssertTrue(SpiceDisplayClient.supports(.sizedStream, in: words))
        XCTAssertTrue(SpiceDisplayClient.supports(.preferredCompression, in: words))
        XCTAssertFalse(SpiceDisplayClient.supports(.composite, in: words))
    }

    /// A server that advertises nothing, or fewer words than the capability
    /// needs, must read as "no" rather than as an index past the end.
    func testAServerThatSaysNothingSupportsNothing() {
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: []))
        XCTAssertFalse(SpiceDisplayClient.supports(.multiCodec, in: []))
        XCTAssertNil(SpiceDisplayClient.compressionToRequest(givenServerCapabilities: []))
    }

    /// The decision this whole file exists for. wisq decodes LZ; a server left
    /// to its own default sends QUIC or GLZ for most of the screen, and neither
    /// is decoded here. Asking is what turns one finished codec into a picture.
    func testAServerThatCanBeAskedIsAskedForLZ() {
        let caps = SpiceDisplayClient.capabilityWords([.preferredCompression])
        XCTAssertEqual(SpiceDisplayClient.compressionToRequest(givenServerCapabilities: caps), .lz)
    }

    /// `lz`, not `autoLZ`. The automatic modes leave the server free to send
    /// QUIC for photographic content — that is what automatic means — so asking
    /// for one would be asking for an encoding this client cannot read, some of
    /// the time, which is the hardest kind of bug to see.
    func testTheRequestIsPlainLZRatherThanAnAutomaticMode() {
        let caps = SpiceDisplayClient.capabilityWords([.preferredCompression])
        let asked = SpiceDisplayClient.compressionToRequest(givenServerCapabilities: caps)
        XCTAssertNotEqual(asked, .autoLZ)
        XCTAssertNotEqual(asked, .autoGLZ)
        XCTAssertEqual(SpiceDisplayClient.preferredCompression(.lz), [6])
    }

    /// The init message the server waits for before it draws anything.
    func testTheInitMessageIsLaidOutAsTheProtocolStatesIt() {
        let body = SpiceDisplayClient.initialise(
            pixmapCacheID: 1, pixmapCachePixels: 0x0102_0304, glzDictionaryID: 2, glzWindowPixels: 0
        )
        // uint8, int64 little-endian, uint8, int32 little-endian.
        XCTAssertEqual(body.count, 1 + 8 + 1 + 4)
        XCTAssertEqual(body[0], 1)
        XCTAssertEqual(Array(body[1...8]), [0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0])
        XCTAssertEqual(body[9], 2)
        XCTAssertEqual(Array(body[10...13]), [0, 0, 0, 0])
    }

    /// The GLZ window is zero on purpose, not by omission: wisq does not decode
    /// GLZ, so a window would be memory held to assemble images it will never
    /// assemble. A phone is where that matters.
    func testTheGLZWindowIsZeroBecauseGLZIsNotDecoded() {
        let body = SpiceDisplayClient.initialise()
        XCTAssertEqual(Array(body.suffix(4)), [0, 0, 0, 0])
    }

    /// The message numbers, which are not sequential from one and are easy to
    /// transpose.
    func testTheMessageNumbersAreTheProtocolsOwn() {
        XCTAssertEqual(SpiceDisplayClient.Message.initialise.rawValue, 101)
        XCTAssertEqual(SpiceDisplayClient.Message.preferredCompression.rawValue, 103)
        XCTAssertEqual(SpiceDisplayClient.Compression.lz.rawValue, 6)
        XCTAssertEqual(SpiceDisplayClient.Compression.quic.rawValue, 4)
    }
}
