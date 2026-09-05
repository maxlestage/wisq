import Foundation
import WisqCore

/// Les deux en-têtes que porte tout ce qui suit l'établissement, et la
/// séquence qui le termine.
///
/// **RDP a deux couches d'en-tête au-dessus de MCS**, et elles se ressemblent
/// assez pour qu'on les confonde. Le premier — le contrôle de partage — dit
/// quel genre de PDU c'est, en six octets. Le second — les données de partage
/// — n'existe que pour le genre « données », et ajoute douze octets dont
/// l'identifiant de partage et un second type. Lire le second type dans le
/// premier en-tête est l'erreur qui fait prendre une mise à jour d'écran pour
/// une demande de contrôle.
public enum RDPShare {
    /// Le genre d'un PDU, dans les quatre bits bas du type.
    public enum Kind: UInt16, Sendable {
        case demandActive = 1
        case confirmActive = 3
        case deactivateAll = 6
        case data = 7
        case serverRedirection = 10
    }

    /// Le second type, celui des PDU de données.
    public enum DataKind: UInt8, Sendable {
        case update = 2
        case control = 20
        case pointer = 27
        case input = 28
        case synchronise = 31
        case refreshRect = 33
        case suppressOutput = 35
        case fontList = 39
        case fontMap = 40
        case setErrorInfo = 47
    }

    /// La version que le type porte dans ses bits hauts.
    ///
    /// **Mesuré : xrdp ne la regarde pas.** Un PDU écrit avec une version nulle
    /// est accepté exactement comme les autres. On l'écrit quand même parce
    /// que c'est ce que la spécification demande et ce que les clients de
    /// référence envoient — mais rien ici ne prouve qu'un autre serveur la
    /// vérifie, et personne ne devrait le déduire de ce fichier.
    public static let versionLow: UInt16 = 0x0010

    /// L'identifiant que tout client met dans un Confirm Active. Ce n'est pas
    /// le sien : c'est une constante du protocole.
    ///
    /// **Mesuré : xrdp ne la vérifie pas non plus.** Un Confirm Active portant
    /// notre vrai canal passe. Même raison de l'écrire quand même, et même
    /// prudence : c'est ce que la spécification dit, pas ce qu'on a prouvé.
    public static let confirmOriginator: UInt16 = 0x03EA

    static func le16(_ value: UInt16) -> Data { RDPStandardSecurity.le16(value) }
    static func le32(_ value: UInt32) -> Data { RDPStandardSecurity.le32(value) }

    /// Emballer un PDU de contrôle de partage.
    public static func control(_ kind: Kind, source: UInt16, _ payload: Data) -> Data {
        le16(UInt16(payload.count + 6)) + le16(kind.rawValue | versionLow) + le16(source) + payload
    }

    /// Emballer un PDU de données.
    public static func data(_ kind: DataKind, share: UInt32, source: UInt16,
                            _ payload: Data) -> Data {
        var body = le32(share)
        body += Data([0x00, 0x01])                       // garniture, flux prioritaire
        body += le16(UInt16(payload.count + 18))         // longueur non compressée
        body += Data([kind.rawValue, 0x00])              // type, pas de compression
        body += le16(0)                                  // longueur compressée
        return control(.data, source: source, body + payload)
    }

    /// Ce qu'un PDU reçu est.
    public struct Incoming: Equatable, Sendable {
        public var kind: Kind
        public var dataKind: DataKind?
        /// Le canal d'où le PDU vient, tel que l'en-tête de contrôle le nomme.
        /// C'est lui que la synchronisation du client vise.
        public var source: UInt16
        public var body: Data
    }

    /// Défaire les deux en-têtes.
    public static func read(_ payload: Data) throws -> Incoming {
        let bytes = [UInt8](payload)
        guard bytes.count >= 6 else {
            throw WisqError.malformedMessage("PDU de partage tronqué")
        }
        let total = Int(bytes[0]) | Int(bytes[1]) << 8
        let type = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        let source = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard let kind = Kind(rawValue: type & 0x000F) else {
            throw WisqError.malformedMessage("PDU de partage de type \(type & 0x000F)")
        }
        // **La longueur annoncée borne la lecture.** Un serveur qui en annonce
        // plus qu'il n'envoie ferait lire la mémoire d'après.
        guard total >= 6, total <= bytes.count else {
            throw WisqError.malformedMessage(
                "PDU qui annonce \(total) octets pour \(bytes.count) reçus")
        }
        guard kind == .data else {
            return Incoming(kind: kind, dataKind: nil, source: source,
                            body: Data(bytes[6..<total]))
        }
        guard total >= 18 else {
            throw WisqError.malformedMessage("PDU de données sans son second en-tête")
        }
        // **La compression est refusée plutôt que devinée.** wisq ne l'annonce
        // pas ; un serveur qui l'emploie quand même envoie des octets qu'on ne
        // saurait pas lire, et les afficher comme des pixels ferait un écran de
        // bruit dont personne ne saurait dire d'où il vient.
        let compression = bytes[15]
        guard compression & 0x20 == 0 else {
            throw WisqError.unsupportedEncoding(Int32(compression))
        }
        return Incoming(kind: kind, dataKind: DataKind(rawValue: bytes[14]),
                        source: source, body: Data(bytes[18..<total]))
    }

    // MARK: - La fin de l'établissement

    /// Les quatre messages que le client envoie après avoir confirmé les
    /// capacités, dans l'ordre que la spécification prescrit.
    ///
    /// **De ces quatre, deux sont mesurés comme nécessaires** contre xrdp : la
    /// demande de contrôle avec son action 1, et la liste de polices. Changer
    /// l'une ou l'autre et le serveur n'envoie jamais le premier pixel — il ne
    /// se plaint pas, il attend. Le canal visé par la synchronisation et
    /// l'action de la coopération, eux, passent inaperçus de xrdp ; on les
    /// écrit selon la spécification sans pouvoir dire d'ici qu'ils comptent.
    public static func synchronise(share: UInt32, source: UInt16, target: UInt16) -> Data {
        data(.synchronise, share: share, source: source, le16(1) + le16(target))
    }

    public static func controlCooperate(share: UInt32, source: UInt16) -> Data {
        data(.control, share: share, source: source, le16(4) + le16(0) + le32(0))
    }

    public static func controlRequest(share: UInt32, source: UInt16) -> Data {
        data(.control, share: share, source: source, le16(1) + le16(0) + le32(0))
    }

    /// La liste de polices : vide, parce que wisq ne dessine pas de glyphes
    /// côté client.
    ///
    /// **Le message compte quand même, et c'est mesuré** : envoyé sous un autre
    /// type, xrdp ne renvoie jamais sa carte des polices et ne peint rien.
    /// C'est lui qui dit au serveur que le client a fini de s'installer.
    public static func fontList(share: UInt32, source: UInt16) -> Data {
        data(.fontList, share: share, source: source,
             le16(0) + le16(0) + le16(0x0003) + le16(0x0032))
    }
}
