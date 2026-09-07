import Foundation
import WisqCore

/// In-memory `ByteStream` used by the protocol tests: `inbound` is what the fake
/// server says, `written` collects what the client sent back.
///
/// By default a read it cannot satisfy reports `connectionClosed`, which is how
/// most protocol tests stop: the scripted bytes run out, the client reads that
/// as the server hanging up, and the session ends. `endsWhenDry: false` gives
/// the other half of a real socket's behaviour — a stream with nothing to say
/// *yet* waits instead of announcing the end of the world. Two SPICE cursor
/// tests needed it: their display fixture reached the end of its script before
/// the cursor task had been scheduled, so the session ended first and the
/// cursor never arrived, about one run in four.
public actor MemoryByteStream: ByteStream {
    private var inbound: Data
    public private(set) var written = Data()
    private var closed = false
    private let endsWhenDry: Bool
    /// Readers suspended for bytes that have not arrived, oldest first. Serving
    /// them in arrival order is what keeps `read(exactly:)`'s one-reader rule
    /// true in this mode: each waiter takes a whole contiguous run, so a stream
    /// fed in one go cannot splice two readers together.
    private var waiting: [(count: Int, continuation: CheckedContinuation<Data, any Error>)] = []

    public init(inbound: Data = Data(), endsWhenDry: Bool = true) {
        self.inbound = inbound
        self.endsWhenDry = endsWhenDry
    }

    public func feed(_ data: Data) {
        inbound.append(data)
        serveWaiting()
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        if !endsWhenDry, !closed, inbound.count < count || !waiting.isEmpty {
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append((count, continuation))
                serveWaiting()
            }
        }
        guard inbound.count >= count else { throw WisqError.connectionClosed }
        return take(count)
    }

    public func write(_ data: Data) async throws {
        guard !closed else { throw WisqError.connectionClosed }
        written.append(data)
    }

    /// Closing wakes the readers this stream is holding. Cancelling their tasks
    /// would not: a cancelled task suspended on a continuation stays suspended
    /// until something resumes it, and a session's `stop()` cancels its pumps
    /// before closing their sockets.
    public func close() {
        closed = true
        let held = waiting
        waiting = []
        for waiter in held { waiter.continuation.resume(throwing: WisqError.connectionClosed) }
    }

    public func drainWritten() -> Data {
        let data = written
        written = Data()
        return data
    }

    private func take(_ count: Int) -> Data {
        let chunk = Data(inbound.prefix(count))
        inbound.removeFirst(count)
        return chunk
    }

    private func serveWaiting() {
        while let next = waiting.first, inbound.count >= next.count {
            waiting.removeFirst()
            next.continuation.resume(returning: take(next.count))
        }
    }
}
