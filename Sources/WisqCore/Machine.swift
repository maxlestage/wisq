import Foundation

/// A saved remote machine: everything needed to reopen a session, minus the secrets,
/// which live in the credential store and are referenced by `credentialRef`.
public struct Machine: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var proto: RemoteProtocol
    public var security: TransportSecurity
    /// Opaque key into the `CredentialStore`. Nil until a secret is saved.
    public var credentialRef: String?
    public var username: String?
    public var display: DisplaySettings
    public var input: InputSettings
    public var guestOS: GuestOS
    public var tags: [String]
    public var lastConnectedAt: Date?
    public var createdAt: Date
    /// Optional host agent that can power this machine on before connecting.
    public var agent: AgentBinding?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        proto: RemoteProtocol = .vnc,
        security: TransportSecurity = .none,
        credentialRef: String? = nil,
        username: String? = nil,
        display: DisplaySettings = .init(),
        input: InputSettings = .init(),
        guestOS: GuestOS = .unknown,
        tags: [String] = [],
        lastConnectedAt: Date? = nil,
        createdAt: Date = Date(),
        agent: AgentBinding? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? proto.defaultPort
        self.proto = proto
        self.security = security
        self.credentialRef = credentialRef
        self.username = username
        self.display = display
        self.input = input
        self.guestOS = guestOS
        self.tags = tags
        self.lastConnectedAt = lastConnectedAt
        self.createdAt = createdAt
        self.agent = agent
    }

    /// Stable key for the credential store, derived from the machine id.
    public var defaultCredentialRef: String { "machine.\(id.uuidString)" }
}

/// Guest operating system, used for the icon and for keyboard defaults.
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case unknown, linux, windows, macos, bsd, other

    public var displayName: String {
        switch self {
        case .unknown: return "Non précisé"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .macos: return "macOS"
        case .bsd: return "BSD"
        case .other: return "Autre"
        }
    }

    /// SF Symbol shown in the machine list.
    public var symbolName: String {
        switch self {
        case .unknown, .other: return "desktopcomputer"
        case .linux: return "terminal"
        case .windows: return "square.grid.2x2"
        case .macos: return "apple.logo"
        case .bsd: return "shippingbox"
        }
    }
}

/// Link to a host agent that manages the VM lifecycle (start/stop/status).
public struct AgentBinding: Codable, Hashable, Sendable {
    /// Base URL of the wisq host agent, e.g. `https://nas.local:7442`.
    public var baseURL: URL
    /// Identifier of the VM on that host (libvirt domain name, QEMU tag, …).
    public var vmIdentifier: String
    /// Ask the agent to boot the VM when the user taps Connect.
    public var autoStart: Bool
    public var credentialRef: String?

    public init(baseURL: URL, vmIdentifier: String, autoStart: Bool = true, credentialRef: String? = nil) {
        self.baseURL = baseURL
        self.vmIdentifier = vmIdentifier
        self.autoStart = autoStart
        self.credentialRef = credentialRef
    }
}
