import Foundation
import WisqCore

/// In-memory `ByteStream` used by the protocol tests: `inbound` is what the fake
/// server says, `written` collects what the client sent back.
public actor MemoryByteStream: ByteStream {
    private var inbound: Data
    public private(set) var written = Data()
    private var closed = false

    public init(inbound: Data = Data()) {
        self.inbound = inbound
    }

    public func feed(_ data: Data) {
        inbound.append(data)
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard inbound.count >= count else { throw WisqError.connectionClosed }
        let chunk = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(chunk)
    }

    public func write(_ data: Data) async throws {
        guard !closed else { throw WisqError.connectionClosed }
        written.append(data)
    }

    public func close() {
        closed = true
    }

    public func drainWritten() -> Data {
        let data = written
        written = Data()
        return data
    }
}
