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
    /// The guest played some sound.
    ///
    /// Frames rather than a decoded buffer, and delivered rather than played,
    /// because playing needs an audio engine that exists only on Apple. What
    /// travels here — samples, channel count, rate, and the server's own clock
    /// — is everything the platform layer needs and nothing it has to guess.
    case audio(AudioFrames)
    /// Terminal. `error` is nil when the user hung up.
    case disconnected(WisqError?)
}

/// Sound from the guest, ready to be played.
///
/// A protocol-independent shape: SPICE is what fills it today, and RFB has no
/// audio at all, but nothing in it is SPICE's. The clock is the server's own
/// millisecond counter, kept so that sound and picture can be lined up rather
/// than played as they arrive.
public struct AudioFrames: Equatable, Sendable {
    /// Interleaved signed sixteen-bit samples, one group a frame.
    public var samples: [Int16]
    public var channels: Int
    public var frequency: Int
    public var time: UInt32

    public init(samples: [Int16], channels: Int, frequency: Int, time: UInt32) {
        self.samples = samples
        self.channels = channels
        self.frequency = frequency
        self.time = time
    }

    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
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
    /// What `.tlsPinned` pins to; nil resolves to system validation.
    public var certificateFingerprint: Data?
    public var username: String?
    public var password: String?
    public var display: DisplaySettings

    public init(
        host: String,
        port: Int,
        security: TransportSecurity = .none,
        certificateFingerprint: Data? = nil,
        username: String? = nil,
        password: String? = nil,
        display: DisplaySettings = .init()
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.certificateFingerprint = certificateFingerprint
        self.username = username
        self.password = password
        self.display = display
    }

    /// The configuration a saved machine asks for, with its secret beside it.
    ///
    /// One place, so that a field added to `Machine` that the transport must
    /// see — the fingerprint was the first — cannot be forgotten on the way.
    public init(machine: Machine, password: String?) {
        self.init(
            host: machine.host,
            port: machine.port,
            security: machine.security,
            certificateFingerprint: machine.certificateFingerprint,
            username: machine.username,
            password: password,
            display: machine.display
        )
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
        let configuration = SessionConfiguration(machine: machine, password: password)

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
            // Same wrapper as VNC and for the same reason, with one of its own:
            // SPICE opens a connection per channel, so a dropped session leaves
            // two sockets and a set of surfaces to discard rather than one
            // socket. A fresh attempt starting from a blank screen is the
            // correct behaviour, not a simplification.
            return ReconnectingSession { framebuffer in
                SPICESession(configuration: configuration, framebuffer: framebuffer)
            }
        case .rdp:
            throw WisqError.unsupportedProtocol(.rdp)
        }
    }
}
