import Foundation

public enum WisqError: Error, Equatable, Sendable {
    case invalidHost(String)
    case invalidPort(Int)
    case connectionFailed(String)
    case connectionClosed
    case timedOut
    case handshakeFailed(String)
    case authenticationFailed(String)
    case authenticationRequired
    case unsupportedProtocol(RemoteProtocol)
    case unsupportedEncoding(Int32)
    case malformedMessage(String)
    case certificateRejected(String)
    case storageFailure(String)
    case agentFailure(String)
    case notImplemented(String)
}

extension WisqError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHost(let h): return "Adresse invalide : « \(h) »."
        case .invalidPort(let p): return "Port invalide : \(p)."
        case .connectionFailed(let m): return "Connexion impossible : \(m)"
        case .connectionClosed: return "La connexion a été fermée par l'hôte."
        case .timedOut: return "Délai d'attente dépassé."
        case .handshakeFailed(let m): return "Échec de la négociation : \(m)"
        case .authenticationFailed(let m): return "Authentification refusée : \(m)"
        case .authenticationRequired: return "Cette machine demande un mot de passe."
        case .unsupportedProtocol(let p): return "\(p.displayName) n'est pas encore pris en charge."
        case .unsupportedEncoding(let e): return "Encodage non pris en charge (\(e))."
        case .malformedMessage(let m): return "Message invalide reçu : \(m)"
        case .certificateRejected(let m): return "Certificat refusé : \(m)"
        case .storageFailure(let m): return "Erreur de stockage : \(m)"
        case .agentFailure(let m): return "L'agent hôte a répondu : \(m)"
        case .notImplemented(let m): return "Pas encore disponible : \(m)"
        }
    }
}
