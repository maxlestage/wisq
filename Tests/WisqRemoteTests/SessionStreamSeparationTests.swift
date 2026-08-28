import Foundation
import WisqNet
import XCTest

@testable import WisqRemote

/// One zlib stream per encoding, and Tight's four — the claim `RFBStreams`
/// opens with, and which nothing held.
///
/// Three sabotages proved it: giving `zlib` and `zrle` the same stream, making
/// `tight(_:)` always answer stream 0, and collapsing Tight's four into one
/// shared stream all left the whole suite green.
///
/// What that costs is not a crash. A zlib stream's dictionary is everything it
/// has inflated so far, so two encodings sharing one stream each poison the
/// other's history: the session decodes **wrong**, quietly, from the first
/// mixed frame onward. `InflateStream`'s own doc says it — "one dropped or
/// mis-parsed byte corrupts every frame after it" — and RFC 6143 §7.7.6 gives
/// Tight four independent streams for exactly this reason.
///
/// The tests below check the **behaviour**, not the object identity. `===`
/// would pin how the separation happens to be implemented; what matters is that
/// one stream's history is invisible to the next.
final class SessionStreamSeparationTests: XCTestCase {
    /// Two rectangles from one server-side deflate stream, the second a
    /// continuation of the first. The same pair `InflateStreamTests` uses, and
    /// the point of them here is that `secondChunk` alone is not a valid zlib
    /// stream: it carries no header, so only a stream that already swallowed
    /// `firstChunk` can make sense of it.
    private static let firstChunk = Data([
        0x78, 0x9C, 0xCA, 0x49, 0x2D, 0x56, 0x48, 0xCE, 0xC8, 0x4C, 0xCD, 0x2B, 0x56, 0x48,
        0x4C, 0xCA, 0x07, 0xD2, 0x25, 0x3A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
    ])
    private static let secondChunk = Data([
        0xCA, 0xC1, 0x26, 0x96, 0xA8, 0x90, 0x9C, 0x58, 0x94, 0x58, 0x96, 0x98, 0x97, 0xAA,
        0x50, 0x90, 0x58, 0x5C, 0x9C, 0x0A, 0x00, 0x00, 0x00, 0xFF, 0xFF,
    ])

    private let opening = "les chiens aboient, "
    private let whole = "les chiens aboient, la caravane passe"

    // MARK: - The control, first

    /// Before any claim that a stream did *not* see something: show that a
    /// stream which did, says so. Without this the refusals below would pass
    /// for a `RFBStreams` whose every stream is broken.
    func testAStreamThatSawTheFirstChunkContinuesIt() throws {
        let streams = try RFBStreams()
        XCTAssertEqual(String(data: try streams.zrle.inflate(Self.firstChunk, limit: 1 << 16), encoding: .utf8), opening)
        XCTAssertEqual(String(data: try streams.zrle.inflate(Self.secondChunk, limit: 1 << 16), encoding: .utf8), whole)
    }

    // MARK: - ZRLE and Zlib are not the same stream

    /// The continuation handed to the *other* encoding has to fail: it is a
    /// headerless fragment, and a fresh stream cannot read it. If it succeeds,
    /// the two encodings are sharing a dictionary and every later frame of both
    /// is being decoded against the wrong history.
    func testZlibDoesNotInheritWhatZRLEInflated() throws {
        let streams = try RFBStreams()
        _ = try streams.zrle.inflate(Self.firstChunk, limit: 1 << 16)
        XCTAssertThrowsError(try streams.zlib.inflate(Self.secondChunk, limit: 1 << 16))
    }

    /// And the other way round, because sharing is symmetric and a test of one
    /// direction would pass for a `zrle` aliased onto `zlib`.
    func testZRLEDoesNotInheritWhatZlibInflated() throws {
        let streams = try RFBStreams()
        _ = try streams.zlib.inflate(Self.firstChunk, limit: 1 << 16)
        XCTAssertThrowsError(try streams.zrle.inflate(Self.secondChunk, limit: 1 << 16))
    }

    // MARK: - Tight's four

    /// Each of the four is its own stream. Checked pairwise rather than in one
    /// pass: a single loop would go green for an implementation where only the
    /// first two happen to differ.
    func testEachTightStreamHasItsOwnDictionary() throws {
        for source in 0..<4 {
            for other in 0..<4 where other != source {
                let streams = try RFBStreams()
                _ = try streams.tight(source).inflate(Self.firstChunk, limit: 1 << 16)
                XCTAssertThrowsError(
                    try streams.tight(other).inflate(Self.secondChunk, limit: 1 << 16),
                    "le flux \(other) a hérité du dictionnaire de \(source)")
            }
        }
    }

    /// And the same index really is the same stream — the half that makes the
    /// four useful rather than merely distinct.
    func testTheSameIndexIsTheSameStream() throws {
        let streams = try RFBStreams()
        _ = try streams.tight(2).inflate(Self.firstChunk, limit: 1 << 16)
        XCTAssertEqual(
            String(data: try streams.tight(2).inflate(Self.secondChunk, limit: 1 << 16), encoding: .utf8), whole)
    }

    /// An index outside 0…3 is clamped rather than crashing.
    ///
    /// Not reachable from the wire today, and worth saying so plainly:
    /// `TightDecoder` masks the control byte with `& 0x3` before calling, and
    /// resets loop over `0..<4`. So this is depth, not a hole — but sabotage
    /// shows what it is depth against. Replacing the clamp with a raw subscript
    /// does not fail a test, it kills the process with `Fatal error: Index out
    /// of range`. The test is here so that a caller who forgets the mask
    /// discovers it as a red test rather than as a dead client.
    func testAnOutOfRangeIndexIsClampedRatherThanFatal() throws {
        let streams = try RFBStreams()
        _ = try streams.tight(3).inflate(Self.firstChunk, limit: 1 << 16)
        XCTAssertEqual(
            String(data: try streams.tight(9).inflate(Self.secondChunk, limit: 1 << 16), encoding: .utf8), whole,
            "un indice trop grand doit retomber sur le dernier flux")

        let others = try RFBStreams()
        _ = try others.tight(0).inflate(Self.firstChunk, limit: 1 << 16)
        XCTAssertEqual(
            String(data: try others.tight(-4).inflate(Self.secondChunk, limit: 1 << 16), encoding: .utf8), whole,
            "un indice négatif doit retomber sur le premier flux")
    }

    // MARK: - Reset

    /// Tight resets a stream when the server says so, and it must reset **that**
    /// one. Resetting the wrong stream throws away a dictionary the server is
    /// still counting on, and leaves the one it asked for polluted.
    func testResettingOneStreamLeavesTheOthersAlone() throws {
        let streams = try RFBStreams()
        _ = try streams.tight(1).inflate(Self.firstChunk, limit: 1 << 16)
        _ = try streams.tight(2).inflate(Self.firstChunk, limit: 1 << 16)

        try streams.resetTight(1)

        XCTAssertThrowsError(
            try streams.tight(1).inflate(Self.secondChunk, limit: 1 << 16), "le flux 1 n'a pas été réinitialisé")
        XCTAssertEqual(
            String(data: try streams.tight(2).inflate(Self.secondChunk, limit: 1 << 16), encoding: .utf8), whole,
            "le flux 2 a été réinitialisé alors que seul le 1 était visé")
    }
}
