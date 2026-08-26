import Foundation

/// Wire protocol used to reach a remote machine.
public enum RemoteProtocol: String, Codable, CaseIterable, Sendable {
    case vnc
    case spice
    case rdp

    public var defaultPort: Int {
        switch self {
        case .vnc: return 5900
        case .spice: return 5930
        case .rdp: return 3389
        }
    }

    public var displayName: String {
        switch self {
        case .vnc: return "VNC"
        case .spice: return "SPICE"
        case .rdp: return "RDP"
        }
    }

    /// Whether a session of this protocol can be opened by the current build.
    /// SPICE and RDP land in later milestones; the UI greys them out until then.
    public var isImplemented: Bool {
        self == .vnc
    }

    /// Credentials the protocol expects. Drives which fields the editor shows.
    public var requiresUsername: Bool {
        switch self {
        case .vnc: return false   // classic VNC auth is password-only
        case .spice: return false // ticket based
        case .rdp: return true
        }
    }
}

/// Transport security applied under the protocol.
public enum TransportSecurity: String, Codable, CaseIterable, Sendable {
    /// Plain TCP. Only reasonable inside a trusted LAN or an existing tunnel.
    case none
    /// TLS with standard certificate validation.
    case tls
    /// TLS pinned to a certificate fingerprint.
    ///
    /// The fingerprint has to come from somewhere, and on the machine path
    /// nothing carries one: neither `Machine` nor `SessionConfiguration` has a
    /// field for it. `ResolvedTransportSecurity.resolve` therefore turns this
    /// into full system validation rather than into a connection that trusts
    /// whatever answers — which is what it used to become. The agent path
    /// pins for real, but by a different road: `AgentBinding` records a
    /// fingerprint at pairing and `AgentClient` takes it as a non-optional.
    ///
    /// This case is not removed because saved machines carry it and because
    /// the machine path is meant to grow the same recording the agent path
    /// already has; see `docs/ROADMAP.md`.
    case tlsPinned

    public var displayName: String {
        switch self {
        case .none: return "Aucune"
        case .tls: return "TLS"
        case .tlsPinned: return "TLS épinglé"
        }
    }
}
