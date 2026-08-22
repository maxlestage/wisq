import Foundation
import WisqCore

/// Everything the UI needs to know about a live session, in the order it happens.
public enum SessionEvent: Sendable {
    case connecting
    case authenticating
    /// Handshake complete: the desktop is known and the framebuffer is sized.
    case ready(desktopName: String, width: Int, height: Int)
    /// Regions of the framebuffer changed. The renderer redraws and asks for more.
    case framebufferChanged([Rect])
    case resized(width: Int, height: Int)
    case clipboard(String)
    case bell
    /// The connection dropped and is being rebuilt. Purely informational for the
    /// UI; input sent meanwhile is silently dropped.
    case reconnecting(attempt: Int)
    /// The guest's cursor image changed. An empty cursor means "hide it".
    case cursor(RemoteCursor)
    /// Terminal. `error` is nil when the user hung up.
    case disconnected(WisqError?)
}

/// A live connection to one remote machine. Backends are actors; the UI drives them
/// with `send(_:)` and reads `events`.
public protocol RemoteSession: Actor {
    /// Event stream. Finishes after `.disconnected`.
    nonisolated var events: AsyncStream<SessionEvent> { get }
    /// Shared pixel buffer. The renderer snapshots it on `.framebufferChanged`.
    nonisolated var framebuffer: Framebuffer { get }

    /// Connects, authenticates, then pumps server messages until stopped.
    func start() async
    func send(_ event: InputEvent) async
    /// Tells the server the viewport changed, when the protocol supports it.
    func setPreferredSize(width: Int, height: Int) async
    func stop() async
}

/// What a backend needs to open a session. Assembled by `SessionFactory` from a
/// `Machine` plus its secret.
public struct SessionConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var security: TransportSecurity
    public var username: String?
    public var password: String?
    public var display: DisplaySettings

    public init(
        host: String,
        port: Int,
        security: TransportSecurity = .none,
        username: String? = nil,
        password: String? = nil,
        display: DisplaySettings = .init()
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.password = password
        self.display = display
    }
}

public enum SessionFactory {
    /// Builds the backend for a machine. Throws for protocols this build cannot speak,
    /// so the UI can say so instead of failing mid-handshake.
    public static func makeSession(
        machine: Machine,
        credentials: CredentialStore
    ) throws -> any RemoteSession {
        let password = try machine.credentialRef.flatMap { try credentials.secret(for: $0) }
        let configuration = SessionConfiguration(
            host: machine.host,
            port: machine.port,
            security: machine.security,
            username: machine.username,
            password: password,
            display: machine.display
        )

        switch machine.proto {
        case .vnc:
            // Reconnection lives outside the protocol backend: the wrapper owns
            // the framebuffer, each attempt gets a fresh session — and with it
            // fresh zlib streams, since an inherited dictionary decodes to
            // garbage.
            return ReconnectingSession { framebuffer in
                VNCSession(configuration: configuration, framebuffer: framebuffer)
            }
        case .spice:
            throw WisqError.unsupportedProtocol(.spice)
        case .rdp:
            throw WisqError.unsupportedProtocol(.rdp)
        }
    }
}
