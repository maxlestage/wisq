import Foundation
import WisqCore
import WisqNet
@testable import WisqRemote

/// A stream that can be told to park its writes until the test releases
/// them. Timing is not left to chance: nothing here waits on a duration.
actor GatedByteStream: ByteStream {
    private var inbound: Data
    private(set) var written = Data()
    private(set) var chunks: [Data] = []
    private var gated = false
    private(set) var parked = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(inbound: Data = Data()) { self.inbound = inbound }

    func gate() { gated = true }

    /// Returns once at least one write is parked, so a caller can be sure
    /// the other task ran while this one was suspended.
    func waitForAPark() async {
        while parked == 0 { await Task.yield() }
    }

    func open() {
        gated = false
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard inbound.count >= count else { throw WisqError.connectionClosed }
        let chunk = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(chunk)
    }

    func write(_ data: Data) async throws {
        if gated {
            parked += 1
            await withCheckedContinuation { waiters.append($0) }
            parked -= 1
        }
        written.append(data)
        chunks.append(data)
    }

    func close() {}

    /// The serial of every message written, in the order they landed.
    ///
    /// Read from the recorded writes one at a time rather than by parsing
    /// the concatenated stream: `send(_:)` makes exactly one `write` call
    /// per message, so each chunk is a whole message and there is no
    /// framing to get wrong. The link handshake is the one chunk that is
    /// not a data message, and it is skipped by trying to decode.
    func serials() -> [UInt64] {
        chunks.compactMap { chunk in
            guard chunk.count >= SpiceWire.dataHeaderBytes,
                  let header = try? SpiceWire.decodeDataHeader(
                      chunk.prefix(SpiceWire.dataHeaderBytes)
                  ),
                  Int(header.size) + SpiceWire.dataHeaderBytes == chunk.count
            else { return nil }
            return header.serial
        }
    }

    /// The message type of every message written, in order.
    func types() -> [UInt16] {
        chunks.compactMap { chunk in
            guard chunk.count >= SpiceWire.dataHeaderBytes,
                  let header = try? SpiceWire.decodeDataHeader(
                      chunk.prefix(SpiceWire.dataHeaderBytes)
                  ),
                  Int(header.size) + SpiceWire.dataHeaderBytes == chunk.count
            else { return nil }
            return header.type
        }
    }
}
