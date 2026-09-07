import WisqCore
import XCTest

@testable import WisqNet

/// A stream that has run out of bytes is not a stream that has been closed.
///
/// `MemoryByteStream` conflated the two: a read it could not satisfy threw
/// `connectionClosed`, which a real socket reports only when the peer has
/// actually hung up. A real socket with nothing to say *yet* blocks.
///
/// That difference decided the outcome of two tests. A SPICE session opens its
/// display channel, starts pumping it, and only then opens the cursor channel on
/// a second connection. With a fixture display socket the pump reached the end
/// of the scripted bytes in microseconds, read that as the server hanging up,
/// ended the session and closed the event stream before the cursor task had been
/// scheduled at all. The two cursor tests failed about one run in four. The
/// fixture had been given a tail of two hundred pings to chew on, which is not a
/// fix: it is the same race with a bigger number, and it lost anyway.
///
/// `endsWhenDry: false` gives a stream that waits. The default is unchanged,
/// because most protocol tests *want* the far end to hang up — that is how they
/// stop.
///
/// Every wait here is read through `settled(_:)` rather than awaited directly.
/// `await task.result` cannot be given a deadline — it ignores cancellation — so
/// an implementation that woke nobody would suspend the whole suite instead of
/// failing one test. That is not hypothetical: it is what the first sabotage of
/// `close()` did, and a suite that hangs reports nothing.
final class MemoryByteStreamWaitingTests: XCTestCase {
    /// The default is still an end, so nothing that relied on it has moved.
    func testTheDefaultStreamStillReportsTheEndOfWhatItWasGiven() async throws {
        let stream = MemoryByteStream(inbound: Data([1, 2]))
        _ = try await stream.read(exactly: 2)
        do {
            _ = try await stream.read(exactly: 1)
            XCTFail("un flux par défaut doit annoncer la fin")
        } catch {
            XCTAssertEqual(error as? WisqError, .connectionClosed)
        }
    }

    /// A waiting stream suspends until it is fed, rather than throwing.
    ///
    /// The claim is checked from both sides: nothing has come back *before* the
    /// feed — which catches a mode flag accepted and ignored — and the whole
    /// three bytes come back after it.
    func testAStreamThatWaitsIsFedRatherThanEnded() async throws {
        let stream = MemoryByteStream(inbound: Data([7]), endsWhenDry: false)
        let reader = reading(stream, exactly: 3)

        try await Task.sleep(nanoseconds: 20_000_000)
        let early = await reader.value
        XCTAssertNil(early, "la lecture est revenue sans attendre la suite : \(early as Any)")

        await stream.feed(Data([8, 9]))
        let outcome = await settled(reader)
        let got = try XCTUnwrap(outcome, "la lecture n'est jamais revenue")
        XCTAssertEqual(Array(try got.get()), [7, 8, 9])
    }

    /// Waiting is not hanging: closing wakes every reader with the end it was
    /// waiting for. Without this a session's `stop()` — which cancels its pumps
    /// and then closes their sockets — would leave a task suspended for ever,
    /// because cancellation alone does not resume a continuation.
    func testClosingAWaitingStreamEndsTheReadsItHolds() async throws {
        let stream = MemoryByteStream(endsWhenDry: false)
        let reader = reading(stream, exactly: 4)

        try await Task.sleep(nanoseconds: 20_000_000)
        await stream.close()

        guard let outcome = await settled(reader) else {
            return XCTFail("la lecture n'a jamais été réveillée : close() la laisse suspendue")
        }
        switch outcome {
        case .success(let data): XCTFail("close() a rendu des octets : \(Array(data))")
        case .failure(let error): XCTAssertEqual(error as? WisqError, .connectionClosed)
        }
    }

    /// A read that arrives after the close does not wait for a feed that can no
    /// longer come.
    func testAReadOnAClosedWaitingStreamDoesNotWait() async throws {
        let stream = MemoryByteStream(endsWhenDry: false)
        await stream.close()
        do {
            _ = try await stream.read(exactly: 1)
            XCTFail("un flux fermé doit refuser tout de suite")
        } catch {
            XCTAssertEqual(error as? WisqError, .connectionClosed)
        }
    }

    /// The one-reader rule survives the new mode.
    ///
    /// `MemoryByteStreamConcurrencyTests` guards a sentence on
    /// `ByteStream.read(exactly:)` by showing that two overlapping reads take
    /// disjoint, contiguous runs. Waiting introduces the suspension *inside*
    /// `read` that the sentence is about, so the property has to be shown again
    /// in this mode: waiters are served in the order they arrived, each taking a
    /// whole run, so a stream fed in one go still cannot splice them together.
    func testTwoOverlappingReadsOnAWaitingStreamStillDoNotSplice() async throws {
        let stream = MemoryByteStream(endsWhenDry: false)

        let first = reading(stream, exactly: 4)
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = reading(stream, exactly: 4)
        try await Task.sleep(nanoseconds: 20_000_000)
        await stream.feed(Data([1, 2, 3, 4, 5, 6, 7, 8]))

        let firstOutcome = await settled(first)
        let secondOutcome = await settled(second)
        let a = try XCTUnwrap(firstOutcome, "le premier lecteur n'est pas revenu")
        let b = try XCTUnwrap(secondOutcome, "le second lecteur n'est pas revenu")
        XCTAssertEqual(Array(try a.get()), [1, 2, 3, 4], "le premier arrivé est servi en premier")
        XCTAssertEqual(Array(try b.get()), [5, 6, 7, 8])
    }

    /// A trickle is not an end either: bytes arriving in pieces smaller than the
    /// read are accumulated, and nothing comes back until the count is reached.
    func testAWaitingReadIsSatisfiedBySeveralSmallFeeds() async throws {
        let stream = MemoryByteStream(endsWhenDry: false)
        let reader = reading(stream, exactly: 3)

        for byte: UInt8 in [1, 2] {
            await stream.feed(Data([byte]))
            try await Task.sleep(nanoseconds: 10_000_000)
            let early = await reader.value
            XCTAssertNil(early, "revenue avec moins que les trois octets demandés")
        }
        await stream.feed(Data([3]))

        let outcome = await settled(reader)
        let got = try XCTUnwrap(outcome, "la lecture n'est jamais revenue")
        XCTAssertEqual(Array(try got.get()), [1, 2, 3])
    }

    // MARK: - Waiting on a wait, with a deadline

    /// Starts a read and collects its outcome where the test can look at it
    /// without awaiting the task itself.
    private func reading(_ stream: MemoryByteStream, exactly count: Int) -> Landed<Data> {
        let landed = Landed<Data>()
        Task {
            do {
                await landed.record(.success(try await stream.read(exactly: count)))
            } catch {
                await landed.record(.failure(error))
            }
        }
        return landed
    }

    /// The outcome of a started read, or `nil` if it has not come back within
    /// `seconds`. Two seconds is not a performance claim: a resumption that has
    /// not happened by then is not going to happen.
    private func settled<Value>(
        _ landed: Landed<Value>, within seconds: Double = 2
    ) async -> Result<Value, any Error>? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let outcome = await landed.value { return outcome }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

/// Where a started read leaves what became of it.
private actor Landed<Value: Sendable> {
    private(set) var value: Result<Value, any Error>?
    func record(_ outcome: Result<Value, any Error>) { value = outcome }
}
