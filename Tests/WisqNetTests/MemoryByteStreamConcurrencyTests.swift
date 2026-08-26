import XCTest
import WisqCore
@testable import WisqNet

/// The half of `ByteStream`'s one-reader rule that this platform can prove.
///
/// The rule is written on the protocol because its two implementations do not
/// share it. `NetworkByteStream` fills a buffer in a loop and **suspends inside
/// it**, so two overlapping reads splice a stream together from each other's
/// positions; `MemoryByteStream` never suspends inside its read, so it has no
/// such window. That asymmetry is the whole reason the rule had to be spelled
/// out, and half of it is checkable here — `Network` is Apple-only, this is not.
///
/// So this file is not "a test that concurrency works". It is the guard on a
/// sentence in a doc comment. `MemoryByteStream` is the double every protocol
/// test reaches for, and giving it a buffer that tops itself up is exactly the
/// kind of convenience someone adds later. The day that happens, the comment on
/// `ByteStream.read(exactly:)` becomes wrong with nothing to say so.
final class MemoryByteStreamConcurrencyTests: XCTestCase {
    /// Two readers, overlapping, taking disjoint bytes in a coherent order.
    ///
    /// Each read is atomic on the actor — no suspension between reading the
    /// buffer and shortening it — so whichever goes first gets a whole,
    /// contiguous run. Which one that is, is not asserted: two concurrent calls
    /// have no order between them, and demanding one would be pinning the
    /// scheduler rather than the property. That mistake cost a CI cycle
    /// earlier and is not worth repeating.
    func testTwoOverlappingReadsDoNotSpliceTheStream() async throws {
        let stream = MemoryByteStream(inbound: Data([1, 2, 3, 4, 5, 6, 7, 8]))

        async let first = stream.read(exactly: 4)
        async let second = stream.read(exactly: 4)
        let (a, b) = try await (first, second)

        // One took the head and the other the tail, whichever way round.
        XCTAssertEqual(
            Set([Array(a), Array(b)]), Set([[1, 2, 3, 4], [5, 6, 7, 8]]),
            "les deux lectures se sont mélangées : \(Array(a)) et \(Array(b))"
        )
    }

    /// And the refusal stays a refusal: a reader asking for more than is left
    /// gets an error rather than a short read, even when another read is
    /// draining the same buffer.
    func testAReaderAskingForMoreThanRemainsIsRefused() async throws {
        let stream = MemoryByteStream(inbound: Data([1, 2, 3, 4]))
        _ = try await stream.read(exactly: 4)

        do {
            _ = try await stream.read(exactly: 1)
            XCTFail("une lecture au-delà de la fin doit être refusée")
        } catch let error as WisqError {
            XCTAssertEqual(error, .connectionClosed)
        }
    }
}
