import Foundation
import WisqCore

/// Les quatre échanges qui ouvrent le domaine MCS, et l'enveloppe que porte
/// ensuite chaque message de la session.
///
/// **Ils sont minuscules et personne ne peut les sauter.** Douze octets pour
/// demander à joindre un canal, quinze pour la réponse ; le protocole n'avance
/// pas tant que le canal d'entrée-sortie n'est pas joint, et un client qui
/// oublie la « Erect Domain » se fait fermer la porte sans explication.
///
/// L'encodage n'est plus du BER ici : ce sont des PDU T.125 en PER, où le type
/// tient dans les six bits hauts du premier octet.
public enum RDPMCS {
    /// Le premier canal que MCS attribue à un utilisateur. Les identifiants de
    /// canal virtuel commencent au-dessus.
    public static let userChannelBase: UInt16 = 1001

    /// Dire au serveur qu'il n'y a personne au-dessus de nous dans la
    /// hiérarchie MCS. Deux entiers à zéro, et c'est tout.
    public static func erectDomainRequest() throws -> Data {
        try RDPWire.frameData(Data([0x04, 0x01, 0x00, 0x01, 0x00]))
    }

    /// Demander un identifiant d'utilisateur.
    public static func attachUserRequest() throws -> Data {
        try RDPWire.frameData(Data([0x28]))
    }

    /// L'identifiant que le serveur a donné, et le canal qui va avec.
    ///
    /// **Le canal de l'utilisateur n'est pas l'identifiant.** MCS rend un
    /// numéro à partir de zéro ; le canal est ce numéro plus mille un. Les
    /// confondre fait joindre le mauvais canal, et le serveur répond
    /// correctement à des messages que personne ne lit.
    public static func readAttachUserConfirm(_ payload: Data) throws -> UInt16 {
        let bytes = [UInt8](try RDPWire.unwrapData(payload))
        guard bytes.count >= 2 else { throw WisqError.handshakeFailed("réponse MCS tronquée") }
        guard bytes[0] >> 2 == 0x0B else {
            throw WisqError.handshakeFailed(
                "attendu une confirmation d'utilisateur, reçu 0x\(String(bytes[0], radix: 16))")
        }
        // **Le résultat est un octet à lui seul.** Le premier octet ne porte
        // que le type et le drapeau du champ facultatif ; PER aligné met
        // l'énuméré du résultat dans l'octet suivant. Le lire à cheval sur les
        // deux — ce qu'un premier jet faisait — rendait « refusé » pour la
        // réponse que la capture montre comme acceptée.
        let result = Int(bytes[1])
        guard result == 0 else {
            throw WisqError.handshakeFailed("le serveur a refusé l'utilisateur MCS (\(result))")
        }
        guard bytes.count >= 4 else {
            throw WisqError.handshakeFailed("confirmation d'utilisateur sans identifiant")
        }
        let initiator = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        return initiator &+ userChannelBase
    }

    /// Demander à joindre un canal.
    public static func channelJoinRequest(user: UInt16, channel: UInt16) throws -> Data {
        let initiator = user &- userChannelBase
        return try RDPWire.frameData(Data([
            0x38,
            UInt8(initiator >> 8), UInt8(initiator & 0xFF),
            UInt8(channel >> 8), UInt8(channel & 0xFF),
        ]))
    }

    /// Vérifier que le canal joint est bien celui qu'on demandait.
    ///
    /// **Le serveur nomme le canal dans sa réponse, et il faut le lire.** Une
    /// confirmation pour un autre canal, prise pour la bonne, laisse croire
    /// qu'on écoute le presse-papiers alors qu'on écoute le son.
    public static func readChannelJoinConfirm(_ payload: Data, expecting channel: UInt16) throws {
        let bytes = [UInt8](try RDPWire.unwrapData(payload))
        guard bytes.count >= 8 else { throw WisqError.handshakeFailed("confirmation de canal tronquée") }
        guard bytes[0] >> 2 == 0x0F else {
            throw WisqError.handshakeFailed(
                "attendu une confirmation de canal, reçu 0x\(String(bytes[0], radix: 16))")
        }
        let result = Int(bytes[1])
        guard result == 0 else {
            throw WisqError.handshakeFailed("le canal \(channel) a été refusé (\(result))")
        }
        let joined = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard joined == channel else {
            throw WisqError.handshakeFailed("le serveur a joint le canal \(joined), pas \(channel)")
        }
    }

    // MARK: - L'enveloppe de la session

    /// Emballer une charge pour un canal : `Send Data Request`.
    public static func sendData(user: UInt16, channel: UInt16, _ payload: Data) throws -> Data {
        let initiator = user &- userChannelBase
        var out = Data([0x64])
        out.append(UInt8(initiator >> 8)); out.append(UInt8(initiator & 0xFF))
        out.append(UInt8(channel >> 8)); out.append(UInt8(channel & 0xFF))
        out.append(0x70)  // priorité haute, segmentation début et fin
        // La longueur est sur un octet sous 128, sinon deux avec le bit de
        // tête — la même forme que PER, et pas celle du BER d'à côté.
        out += RDPPER.length(payload.count)
        out += payload
        return try RDPWire.frameData(out)
    }

    /// Ce qu'un `Send Data Indication` porte : le canal, et la charge.
    public struct Indication: Equatable, Sendable {
        public var channel: UInt16
        public var payload: Data
    }

    /// Défaire l'enveloppe d'un message venant du serveur.
    ///
    /// Le serveur peut aussi annoncer la fin du domaine — c'est ainsi qu'il dit
    /// « la session est finie » avant de fermer la socket, et le distinguer
    /// d'une coupure évite d'annoncer une panne là où il y a eu un au revoir.
    public enum Incoming: Equatable, Sendable {
        case data(Indication)
        case disconnected(reason: UInt8)
    }

    public static func readIncoming(_ payload: Data) throws -> Incoming {
        let bytes = [UInt8](try RDPWire.unwrapData(payload))
        guard let first = bytes.first else { throw WisqError.malformedMessage("message MCS vide") }
        // **Les types se comptent en index de choix PER, pas en octets.** Le
        // premier octet porte le type dans ses six bits hauts : la fin de
        // domaine vaut 8 (donc 0x20), l'indication 26 (0x68). Écrire 0x19 pour
        // la fin de domaine — l'index de `Send Data Request` — ferait prendre
        // chaque message du client pour un au revoir, ce qui ne se verrait
        // jamais chez le client et immédiatement chez un serveur.
        switch first >> 2 {
        case 0x08:  // Disconnect Provider Ultimatum
            return .disconnected(reason: bytes.count > 1 ? (bytes[0] & 0x01) << 1 | bytes[1] >> 7 : 0)
        case 0x1A:  // Send Data Indication
            guard bytes.count >= 7 else {
                throw WisqError.malformedMessage("indication MCS tronquée")
            }
            let channel = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
            var index = 6
            let declared = try RDPPER.readLength(bytes, at: &index)
            guard index + declared <= bytes.count else {
                throw WisqError.malformedMessage(
                    "l'indication annonce \(declared) octets, il en reste \(bytes.count - index)")
            }
            return .data(Indication(channel: channel,
                                    payload: Data(bytes[index..<(index + declared)])))
        default:
            throw WisqError.malformedMessage(
                "PDU MCS de type \(first >> 2), inattendu dans une session")
        }
    }
}
