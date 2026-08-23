import Foundation
import WisqCore
import WisqNet

/// SPICE backend. Not yet implemented.
///
/// The wire protocol is multi-channel (main, display, inputs, cursor, playback) and
/// the display channel needs QUIC/LZ image decoding, so it lands as its own milestone
/// rather than as a variant of the RFB pump. The type exists now so `SessionFactory`
/// and the machine editor can already model it, and so the surface it must implement
/// is fixed before the work starts.
///
/// Milestone plan, in the order the channels have to come up:
///   1. Main channel: link handshake, capabilities, `SPICE_MSG_MAIN_INIT`.
///   2. Inputs channel: keyboard and mouse, which alone makes it useful with a
///      framebuffer borrowed from the display channel's first full refresh.
///   3. Display channel: surfaces, `DRAW_COPY`/`DRAW_FILL` primitives, LZ images.
///   4. Cursor channel, then playback/record if audio ever matters on a phone.
public actor SPICESession: RemoteSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let framebuffer = Framebuffer(width: 0, height: 0)

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration

    public init(configuration: SessionConfiguration) {
        self.configuration = configuration
        var escapee: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escapee = $0 }
        self.continuation = escapee
    }

    public func start() async {
        continuation.yield(.disconnected(.unsupportedProtocol(.spice)))
        continuation.finish()
    }

    public func send(_ event: InputEvent) async {}
    public func setPreferredSize(width: Int, height: Int) async {}

    public func stop() async {
        continuation.finish()
    }
}
