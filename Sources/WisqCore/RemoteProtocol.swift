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
    ///
    /// This is a **label**, and `SessionFactory.makeSession` is the fact. They
    /// were two hand-kept lists and they had drifted apart: this one still
    /// said `self == .vnc`, from the milestone where it was true, so the
    /// editor offered « SPICE (bientôt) » about a protocol the factory has
    /// been building sessions for since lot 5 — the console that carries the
    /// clipboard, the file drop and the resize, greyed out in the one place a
    /// person chooses it.
    ///
    /// `ImplementedProtocolsTests` now walks `allCases` through the factory
    /// and requires the two to agree, so the next protocol to land cannot be
    /// announced late — or early.
    public var isImplemented: Bool {
        switch self {
        case .vnc, .spice: return true
        case .rdp: return false
        }
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
    /// The fingerprint has to come from somewhere. Without one,
    /// `ResolvedTransportSecurity.resolve` turns this into full system
    /// validation rather than into a connection that trusts whatever answers
    /// — which is what it used to become. The agent path pins by a different
    /// road: `AgentBinding` records a fingerprint at pairing and `AgentClient`
    /// takes it as a non-optional.
    ///
    /// `Machine.certificateFingerprint` is where the machine path carries
    /// one, typed in by the user from what `openssl` or a browser shows;
    /// recording it from the connection itself is still to come — see
    /// `docs/ROADMAP.md`.
    case tlsPinned

    public var displayName: String {
        switch self {
        case .none: return "Aucune"
        case .tls: return "TLS"
        // The name of the mode, not of what a given machine gets from it: the
        // mode pins only when the machine carries a fingerprint, and without
        // one it is system-validated TLS. That per-machine truth is
        // `Machine.transportDescription`; the editor says it under the
        // picker. See `ResolvedTransportSecurity` and `docs/ROADMAP.md`.
        case .tlsPinned: return "TLS épinglé par empreinte"
        }
    }
}
