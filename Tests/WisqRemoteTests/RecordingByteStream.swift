import Foundation
import WisqCore
import WisqNet

/// A `ByteStream` that answers from a script and remembers every size it was
/// asked for.
///
/// The question these tests ask is not "did it crash" — a decoder handed an
/// absurd length on a real socket does not crash, it waits, accumulating
/// whatever the server dribbles until the phone kills the app. The question is
/// **what size did the decoder ask for**, and that is what this records.
///
/// `MemoryByteStream` cannot answer it: its read throws as soon as the request
/// exceeds what it holds, so a bounded decoder and an unbounded one both end in
/// a throw and look alike. Here the request itself is the evidence.
actor RecordingByteStream: ByteStream {
    private var inbound: Data
    private(set) var requestedCounts: [Int] = []
    private(set) var written = Data()

    init(inbound: Data = Data()) {
        self.inbound = inbound
    }

    func read(exactly count: Int) async throws -> Data {
        requestedCounts.append(count)
        guard count > 0 else { return Data() }
        guard inbound.count >= count else { throw WisqError.connectionClosed }
        let chunk = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(chunk)
    }

    func write(_ data: Data) async throws {
        written.append(data)
    }

    func close() {}

    /// The largest single read the code under test asked for.
    var largestRequest: Int { requestedCounts.max() ?? 0 }
}
