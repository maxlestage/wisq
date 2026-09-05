import Foundation
import WisqCore

/// L'étape de licence : quatre messages possibles, dont un seul compte pour un
/// client qui ne prétend pas être Windows.
///
/// **Ce que RDP appelle « licence » n'est pas une autorisation d'usage** mais
/// un jeton par poste, qu'un serveur Windows en mode « par périphérique »
/// délivre et réclame ensuite. Les serveurs qui n'en distribuent pas — xrdp,
/// et Windows en mode « par utilisateur » — répondent au premier message par
/// une alerte qui veut dire « passe ton chemin », et la session continue.
///
/// **Un client qui ne répond rien reste là.** Le serveur attend, et rien ne
/// dit à personne pourquoi la connexion ne finit pas de s'établir.
public enum RDPLicensing {
    /// Les types de message, tels que le préambule les porte.
    public enum Message: UInt8 {
        case licenseRequest = 0x01
        case platformChallenge = 0x02
        case newLicense = 0x03
        case upgradeLicense = 0x04
        case licenseInfo = 0x12
        case newLicenseRequest = 0x13
        case platformChallengeResponse = 0x15
        case errorAlert = 0xFF
    }

    /// Ce que l'étape a donné.
    public enum Outcome: Equatable, Sendable {
        /// Le serveur veut une demande de licence.
        case wantsRequest
        /// C'est fini : la session peut continuer.
        case finished
        /// Le serveur a refusé, et voici son code.
        case refused(UInt32)
    }

    /// L'aléa que le serveur envoie dans sa demande, quand il y en a un.
    public static func serverRandom(_ payload: [UInt8]) -> [UInt8]? {
        guard payload.count >= 36 else { return nil }
        return Array(payload[4..<36])
    }

    /// Lire un message de licence, en-tête de sécurité déjà retiré.
    ///
    /// **Le préambule annonce sa taille, et elle borne la lecture.** Un
    /// serveur qui annonce moins qu'il n'envoie laisserait des octets non lus
    /// que le message suivant prendrait pour lui.
    public static func read(_ payload: Data) throws -> Outcome {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else {
            throw WisqError.malformedMessage("message de licence tronqué")
        }
        let size = Int(bytes[2]) | Int(bytes[3]) << 8
        guard size >= 4, size <= bytes.count else {
            throw WisqError.malformedMessage(
                "message de licence de \(size) octets pour \(bytes.count) reçus")
        }
        switch Message(rawValue: bytes[0]) {
        case .licenseRequest:
            return .wantsRequest
        case .errorAlert:
            guard bytes.count >= 12 else {
                throw WisqError.malformedMessage("alerte de licence tronquée")
            }
            let code = RDPStandardSecurity.le32(bytes, 4)
            let transition = RDPStandardSecurity.le32(bytes, 8)
            // **Sept veut dire « client valide », et c'est un succès.** Un
            // code d'erreur qui signifie que tout va bien : le lire comme une
            // panne ferait échouer toutes les connexions aux serveurs qui ne
            // distribuent pas de licence, c'est-à-dire presque tous.
            if code == 0x0000_0007 { return .finished }
            // **Et pour les autres codes, c'est la transition d'état qui
            // décide, pas le code.** Un serveur sans licence à donner envoie
            // une vraie erreur avec « pas de transition », ce qui veut dire
            // « continue quand même » ; seul l'abandon total (1) dit qu'il n'y
            // aura pas de suite. Choisir d'après le code demanderait de tenir
            // la liste des codes bénins, et la liste serait fausse le jour où
            // un serveur en emploie un de plus.
            return transition == 0x0000_0001 ? .refused(code) : .finished
        case .newLicense, .upgradeLicense:
            return .finished
        case .platformChallenge:
            // Un serveur qui distribue vraiment des licences irait plus loin.
            // wisq ne prétend pas être un poste Windows enregistré, et le dire
            // vaut mieux que d'inventer une réponse qui sera refusée.
            throw WisqError.authenticationFailed(
                "ce serveur exige une licence par poste, que wisq ne peut pas présenter")
        default:
            throw WisqError.malformedMessage(
                "message de licence de type 0x\(String(bytes[0], radix: 16))")
        }
    }

    /// Un bloc binaire de licence : un type, une longueur, des octets.
    static func blob(_ type: UInt16, _ payload: Data) -> Data {
        RDPStandardSecurity.le16(type) + RDPStandardSecurity.le16(UInt16(payload.count)) + payload
    }

    /// La demande d'une nouvelle licence.
    ///
    /// **Elle est délibérément la plus simple qui soit valide.** Les serveurs
    /// qui ne distribuent rien ne la lisent pas au-delà de son préambule ;
    /// ceux qui distribuent vraiment demanderont ensuite un défi de plateforme,
    /// auquel wisq répond qu'il ne sait pas — plutôt que d'inventer une
    /// identité de poste Windows.
    public static func newLicenseRequest(user: String, machine: String) -> Data {
        var body = Data()
        body += RDPStandardSecurity.le32(0x0000_0001)   // échange de clés RSA
        body += RDPStandardSecurity.le32(0x0000_0004)   // plateforme : « autre »
        body += Data(repeating: 0, count: 32)           // aléa du client
        body += blob(0x0002, Data(repeating: 0, count: 72))  // pré-secret chiffré
        body += blob(0x000F, Data(user.utf8) + Data([0]))
        body += blob(0x0010, Data(machine.utf8) + Data([0]))

        var out = Data([Message.newLicenseRequest.rawValue, 0x03])
        out += RDPStandardSecurity.le16(UInt16(body.count + 4))
        return out + body
    }
}
