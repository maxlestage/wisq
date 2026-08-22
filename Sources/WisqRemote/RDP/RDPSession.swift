import Foundation
import WisqCore
import WisqNet

/// RDP backend. Not yet implemented.
///
/// Unlike RFB, RDP is not realistically hand-rolled: NLA/CredSSP, the RemoteFX and
/// H.264 codecs and the virtual-channel stack are a project of their own. The plan
/// is to vendor FreeRDP 3 as a static library built for iOS/arm64 and drive it
/// through a thin C shim behind this actor, keeping the rest of the app unaware.
///
/// Two things to settle before writing code:
///   - FreeRDP is Apache-2.0, so shipping it on the App Store is fine — unlike the
///     GPL question that constrains QEMU-based competitors.
///   - The build must be reproducible in CI; a checked-in xcframework is a
///     maintenance trap when CVEs land.
public actor RDPSession: RemoteSession {
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
        continuation.yield(.disconnected(.unsupportedProtocol(.rdp)))
        continuation.finish()
    }

    public func send(_ event: InputEvent) async {}
    public func setPreferredSize(width: Int, height: Int) async {}

    public func stop() async {
        continuation.finish()
    }
}
