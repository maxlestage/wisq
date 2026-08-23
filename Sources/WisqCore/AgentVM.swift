import Foundation

/// What the host agent reports about one VM.
public struct AgentVM: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, paused, stopped, starting, unknown

        public var displayName: String {
            switch self {
            case .running: return "En marche"
            case .paused: return "En pause"
            case .stopped: return "Arrêtée"
            case .starting: return "Démarrage…"
            case .unknown: return "Inconnu"
            }
        }
    }

    public var id: String
    public var name: String
    public var state: State
    /// Protocol and port the agent exposes for this VM's console, when it is up.
    public var consoleProtocol: RemoteProtocol?
    public var consolePort: Int?
    public var guestOS: GuestOS?

    public init(
        id: String,
        name: String,
        state: State,
        consoleProtocol: RemoteProtocol? = nil,
        consolePort: Int? = nil,
        guestOS: GuestOS? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.consoleProtocol = consoleProtocol
        self.consolePort = consolePort
        self.guestOS = guestOS
    }
}
