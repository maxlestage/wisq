import Foundation
import WisqCore
import WisqNet

/// The zlib streams a session keeps alive from connect to disconnect.
///
/// One per compressed encoding, plus Tight's four. They are session state, not
/// rectangle state: the whole point is that the dictionary carries across frames.
///
/// Genuinely `Sendable`: every stored property is a `let` holding an
/// individually thread-safe `InflateStream`, which is what lets a decoder be
/// handed to a nonisolated async call without an escape hatch.
final class RFBStreams: Sendable {
    let zrle: InflateStream
    let zlib: InflateStream
    private let tightStreams: [InflateStream]

    init() throws {
        self.zrle = try InflateStream()
        self.zlib = try InflateStream()
        self.tightStreams = try (0..<4).map { _ in try InflateStream() }
    }

    func tight(_ index: Int) -> InflateStream {
        tightStreams[min(max(0, index), tightStreams.count - 1)]
    }

    func resetTight(_ index: Int) throws {
        try tight(index).reset()
    }
}
