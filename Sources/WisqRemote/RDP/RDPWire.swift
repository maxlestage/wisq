import Foundation
import WisqCore
import WisqNet

/// Les deux enveloppes que porte toute session RDP, et la seule question qui se
/// pose avant de savoir parler : quelle sécurité.
///
/// **TPKT** (RFC 1006) donne à TCP des messages : quatre octets, dont une
/// longueur de seize bits qui compte l'en-tête. **X.224** (la classe 0 de
/// l'ISO 8073) met par-dessus un octet de longueur et un type. Tout le reste du
/// protocole — MCS, les canaux, les capacités, les pixels — voyage dedans.
///
/// **Et la négociation tient dans le premier paquet.** Le client dit ce qu'il
/// sait faire, le serveur choisit. Trois réponses possibles : rien du tout — la
/// sécurité historique de RDP —, un choix, ou un refus nommé. Un client qui
/// prend le silence pour un accord tacite de TLS se retrouve à parler chiffré à
/// un serveur qui ne l'est pas, et le premier message décodé est du bruit.
public enum RDPWire {
    // MARK: - TPKT

    public static let tpktVersion: UInt8 = 3
    public static let tpktHeaderBytes = 4
    /// La longueur tient sur seize bits, en-tête compris : c'est le plafond, et
    /// il vient du format, pas d'une prudence de notre part.
    public static let tpktMaximum = 0xFFFF

    /// Emballer une charge dans un TPKT.
    public static func frame(_ payload: Data) throws -> Data {
        let total = tpktHeaderBytes + payload.count
        guard total <= tpktMaximum else {
            throw WisqError.malformedMessage("TPKT de \(total) octets, le format en permet \(tpktMaximum)")
        }
        var out = Data([tpktVersion, 0])
        out.append(UInt8(total >> 8))
        out.append(UInt8(total & 0xFF))
        out.append(payload)
        return out
    }

    /// Ce que dit un en-tête TPKT : combien d'octets restent à lire après lui.
    ///
    /// **La version est vérifiée.** Un serveur qui répond en HTTP parce qu'on
    /// s'est trompé de port envoie `HTTP/1.1`, dont le premier octet vaut 0x48 :
    /// le lire comme un TPKT donnerait une longueur de dizaines de milliers
    /// d'octets et une attente qui ne finit pas.
    public static func payloadLength(ofHeader header: Data) throws -> Int {
        let bytes = [UInt8](header)
        guard bytes.count >= tpktHeaderBytes else {
            throw WisqError.malformedMessage("en-tête TPKT tronqué")
        }
        guard bytes[0] == tpktVersion else {
            throw WisqError.malformedMessage(
                "ce n'est pas du RDP : premier octet 0x\(String(bytes[0], radix: 16)) au lieu de 3")
        }
        let total = Int(bytes[2]) << 8 | Int(bytes[3])
        guard total >= tpktHeaderBytes else {
            throw WisqError.malformedMessage("TPKT annonce \(total) octets, moins que son en-tête")
        }
        return total - tpktHeaderBytes
    }

    // MARK: - X.224

    /// Les trois TPDU de la classe 0 que RDP emploie.
    public enum TPDU: UInt8 {
        case connectionRequest = 0xE0
        case connectionConfirm = 0xD0
        case disconnectRequest = 0x80
        case data = 0xF0
    }

    /// L'en-tête d'un X.224 de données : longueur 2, type `data`, EOT.
    ///
    /// Il est constant, et c'est ce qui rend le chemin chaud si court : chaque
    /// message de la session porte ces trois octets et rien d'autre.
    public static let dataHeader = Data([0x02, TPDU.data.rawValue, 0x80])

    /// Emballer une charge de session : X.224 de données, puis TPKT.
    public static func frameData(_ payload: Data) throws -> Data {
        try frame(dataHeader + payload)
    }

    /// Retirer l'en-tête X.224 d'un message de données déjà défait de son TPKT.
    public static func unwrapData(_ payload: Data) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3 else { throw WisqError.malformedMessage("X.224 tronqué") }
        let length = Int(bytes[0])
        guard bytes[1] == TPDU.data.rawValue else {
            throw WisqError.malformedMessage(
                "X.224 de type 0x\(String(bytes[1], radix: 16)) là où des données étaient attendues")
        }
        // La longueur compte les octets **après** elle-même. Pour un TPDU de
        // données elle vaut deux ; la lire plutôt que la supposer laisse passer
        // les variantes, et la borner évite qu'elle désigne au-delà du message.
        guard length + 1 <= bytes.count else {
            throw WisqError.malformedMessage("X.224 annonce plus long que son message")
        }
        return Data(bytes[(length + 1)...])
    }

    // MARK: - La négociation de sécurité

    /// Ce qu'un client peut proposer, et ce qu'un serveur peut choisir.
    public struct SecurityProtocols: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// La sécurité historique de RDP, celle qui chiffre avec RC4 et une clé
        /// négociée dans le protocole lui-même. Elle vaut zéro : c'est
        /// l'absence de demande, pas un bit.
        public static let standard = SecurityProtocols([])
        public static let tls = SecurityProtocols(rawValue: 0x0000_0001)
        /// CredSSP — « NLA ». Sans lui, aucun Windows moderne n'accepte.
        public static let credSSP = SecurityProtocols(rawValue: 0x0000_0002)
        public static let rdstls = SecurityProtocols(rawValue: 0x0000_0004)
        public static let credSSPWithEarlyUserAuth = SecurityProtocols(rawValue: 0x0000_0008)
    }

    /// Pourquoi un serveur a refusé. Les codes sont ceux de MS-RDPBCGR 2.2.1.2.2.
    public enum NegotiationFailure: UInt32, Sendable {
        case sslRequiredByServer = 1
        case sslNotAllowedByServer = 2
        case sslCertificateNotOnServer = 3
        case inconsistentFlags = 4
        case hybridRequiredByServer = 5
        case sslWithUserAuthenticationRequiredByServer = 6

        public var explanation: String {
            switch self {
            case .sslRequiredByServer: return "ce serveur exige TLS"
            case .sslNotAllowedByServer: return "ce serveur refuse TLS"
            case .sslCertificateNotOnServer: return "ce serveur n'a pas de certificat"
            case .inconsistentFlags: return "la demande était contradictoire"
            case .hybridRequiredByServer: return "ce serveur exige l'authentification réseau (NLA)"
            case .sslWithUserAuthenticationRequiredByServer:
                return "ce serveur exige TLS avec authentification de l'utilisateur"
            }
        }
    }

    /// Ce que le serveur a répondu au premier paquet.
    public enum Confirm: Equatable, Sendable {
        /// Aucune structure de négociation : le serveur parle la sécurité
        /// historique de RDP. **Le silence est une réponse**, et c'en est une
        /// précise — pas un défaut de réponse.
        case standardSecurity
        /// Le serveur a choisi.
        case selected(SecurityProtocols, flags: UInt8)
        /// Le serveur a refusé, en disant pourquoi.
        case refused(NegotiationFailure?, code: UInt32)
    }

    /// Ce que wisq accepte de mettre dans le témoin `mstshash`.
    ///
    /// **Le client de référence a l'injection, et c'est mesuré.** FreeRDP 2.11,
    /// à qui l'on donne un nom d'utilisateur contenant un retour à la ligne,
    /// écrit ceci dans son en-tête X.224 :
    ///
    ///     Cookie: mstshash=bob\r\nCookie: mstshash=admin\r\n
    ///
    /// Deux témoins pour une connexion. Le témoin n'est pas un secret — le nom
    /// voyage en clair dans ce paquet-ci de toute façon —, mais c'est lui
    /// qu'une ferme de serveurs lit pour renvoyer quelqu'un vers la machine où
    /// sa session dort. Un nom fabriqué choisit donc la destination. C'est la
    /// même famille que l'identifiant de VM qui arrivait à `virsh` sans
    /// validation, et wisq ne la reproduit pas.
    ///
    /// On filtre plutôt que de refuser : le témoin n'est qu'un indice de
    /// routage, et un nom inhabituel ne doit pas empêcher de se connecter.
    static func cookie(from user: String) -> String {
        String(user.filter { character in
            guard let byte = character.asciiValue else { return false }
            return byte >= 0x20 && byte != 0x7F
        }.prefix(cookieLimit))
    }

    /// **La borne vient du format, pas de la prudence.** La longueur X.224 est
    /// *un octet* : tout ce qui suit doit tenir dans 255. Six pour le type, les
    /// références et la classe ; huit pour la demande de sécurité ; dix-neuf
    /// pour « Cookie: mstshash= » et son `\r\n`. Le reste est au nom.
    ///
    /// Mesuré aussi : le client de référence ne tronque pas du tout — un nom de
    /// trente-six caractères part entier. Il n'y a donc pas de limite de
    /// protocole à respecter ici, seulement celle de l'octet de longueur.
    static let cookieLimit = 255 - 6 - 8 - 19

    /// Le premier paquet : qui l'on prétend être, et ce qu'on sait chiffrer.
    ///
    /// **Le témoin est facultatif et sert un répartiteur**, pas la sécurité :
    /// une ferme de serveurs s'en sert pour renvoyer quelqu'un vers la machine
    /// où sa session dort déjà. Le mettre ne dit rien de secret — le nom
    /// d'utilisateur voyage de toute façon en clair dans ce paquet-ci, avant
    /// que TLS n'existe — mais l'omettre quand on n'a pas de nom évite
    /// d'annoncer « mstshash= » suivi de rien, ce que certains serveurs
    /// refusent.
    public static func connectionRequest(user: String?,
                                         requesting protocols: SecurityProtocols) throws -> Data {
        var tpdu = Data()
        tpdu.append(TPDU.connectionRequest.rawValue)
        tpdu.append(contentsOf: [0x00, 0x00])   // DST-REF
        tpdu.append(contentsOf: [0x00, 0x00])   // SRC-REF
        tpdu.append(0x00)                        // classe 0
        if let user, !cookie(from: user).isEmpty {
            tpdu.append(contentsOf: Array("Cookie: mstshash=\(cookie(from: user))\r\n".utf8))
        }
        // **La demande ne s'écrit que si elle demande quelque chose.** Le client
        // de référence l'omet entièrement pour la sécurité historique, et un
        // serveur qui reçoit une demande de zéro protocole peut la lire comme
        // une contradiction (`inconsistentFlags`).
        if !protocols.isEmpty {
            tpdu.append(0x01)                    // TYPE_RDP_NEG_REQ
            tpdu.append(0x00)                    // pas de drapeau
            tpdu.append(contentsOf: [0x08, 0x00])  // longueur, petit-boutiste
            for shift in stride(from: 0, to: 32, by: 8) {
                tpdu.append(UInt8((protocols.rawValue >> UInt32(shift)) & 0xFF))
            }
        }
        var out = Data([UInt8(tpdu.count)])      // LI : ce qui suit cet octet
        out.append(tpdu)
        return try frame(out)
    }

    /// Lire la réponse, TPKT déjà retiré.
    public static func readConnectionConfirm(_ payload: Data) throws -> Confirm {
        let bytes = [UInt8](payload)
        guard bytes.count >= 7 else {
            throw WisqError.handshakeFailed("réponse de connexion tronquée")
        }
        guard bytes[1] == TPDU.connectionConfirm.rawValue else {
            throw WisqError.handshakeFailed(
                "le serveur a répondu 0x\(String(bytes[1], radix: 16)) au lieu d'une confirmation")
        }
        let length = Int(bytes[0])
        guard length + 1 <= bytes.count else {
            throw WisqError.handshakeFailed("la confirmation annonce plus long qu'elle n'est")
        }
        // Sept octets — longueur, type, deux références, classe — et rien
        // derrière : le serveur n'a pas négocié.
        guard length >= 6 + 8 else { return .standardSecurity }
        let structure = Array(bytes[7..<min(bytes.count, 15)])
        guard structure.count == 8 else { return .standardSecurity }
        let value = UInt32(structure[4]) | UInt32(structure[5]) << 8
            | UInt32(structure[6]) << 16 | UInt32(structure[7]) << 24
        switch structure[0] {
        case 0x02:  // TYPE_RDP_NEG_RSP
            return .selected(SecurityProtocols(rawValue: value), flags: structure[1])
        case 0x03:  // TYPE_RDP_NEG_FAILURE
            return .refused(NegotiationFailure(rawValue: value), code: value)
        default:
            throw WisqError.handshakeFailed(
                "structure de négociation de type \(structure[0]), inconnue")
        }
    }
}
