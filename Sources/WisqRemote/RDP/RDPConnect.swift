import Foundation
import WisqCore

/// Le second échange : tout ce que le client est, et tout ce que le serveur
/// répond.
///
/// **C'est le paquet le plus dense du protocole.** Une enveloppe MCS en BER,
/// dedans une conférence T.124 en PER, dedans quatre blocs à champs fixes qui
/// disent la taille de l'écran, le clavier, les chiffrements acceptés et les
/// canaux voulus. Trois encodages empilés, et une erreur dans n'importe lequel
/// donne un serveur qui ferme sans rien dire.
///
/// Les valeurs conventionnelles — les paramètres de domaine, l'en-tête de
/// conférence — sont recopiées d'une capture du client de référence, parce
/// qu'elles sont les mêmes chez tout le monde et que les inventer ne servirait
/// personne. Ce qui décrit **wisq** — la taille, le nom, les canaux — est
/// écrit ici et vérifié champ par champ.
public enum RDPConnect {
    // MARK: - Ce que le client annonce

    /// Un canal virtuel demandé au serveur.
    public struct Channel: Equatable, Sendable {
        /// Sept caractères au plus : le champ en fait huit, dont un nul final.
        public var name: String
        public var options: UInt32
        public init(name: String, options: UInt32) {
            self.name = name
            self.options = options
        }
    }

    /// Ce que wisq dit de lui-même.
    public struct ClientDescription: Sendable {
        public var width: Int
        public var height: Int
        /// Le nom de la machine, tel qu'il apparaîtra côté serveur. Quinze
        /// caractères utiles : le champ en fait trente-deux octets UTF-16.
        public var name: String
        public var keyboardLayout: UInt32
        public var colourDepth: Int
        public var channels: [Channel]
        /// Ce que la négociation du premier paquet a donné. Le serveur le
        /// relit ici et refuse si les deux ne concordent pas — c'est sa
        /// protection contre quelqu'un qui aurait réécrit le premier paquet.
        public var selectedProtocol: UInt32

        public init(width: Int = 1024, height: Int = 768, name: String = "wisq",
                    keyboardLayout: UInt32 = 0x0000_0409, colourDepth: Int = 24,
                    channels: [Channel] = [], selectedProtocol: UInt32 = 0) {
            self.width = width
            self.height = height
            self.name = name
            self.keyboardLayout = keyboardLayout
            self.colourDepth = colourDepth
            self.channels = channels
            self.selectedProtocol = selectedProtocol
        }
    }

    /// Les chiffrements que le client accepte, quand la sécurité est celle de
    /// RDP lui-même. Quarante bits, cent vingt-huit, cinquante-six, et le
    /// « FIPS » à trois clés.
    public static let encryptionMethods: UInt32 = 0x0000_001B

    /// L'écran ne peut pas être plus grand que ça, et ce n'est pas une
    /// prudence : les deux champs font seize bits, et MS-RDPBCGR borne
    /// lui-même à 4096 × 2048 dans ce bloc-ci.
    public static let maximumWidth = 4096
    public static let maximumHeight = 2048

    // MARK: - Les quatre blocs

    static func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    /// Une chaîne UTF-16 petit-boutiste, complétée de zéros jusqu'à la taille
    /// du champ — et **coupée sur un caractère entier**, pas au milieu d'une
    /// paire de substitution : la moitié d'un émoji ferait une chaîne que le
    /// serveur ne sait pas décoder.
    static func utf16Field(_ text: String, bytes: Int) -> Data {
        var out = Data()
        for character in text {
            let encoded = Data(Array(String(character).utf16).flatMap {
                [UInt8($0 & 0xFF), UInt8($0 >> 8)]
            })
            // Deux octets réservés au nul final.
            guard out.count + encoded.count <= bytes - 2 else { break }
            out.append(encoded)
        }
        return out + Data(repeating: 0, count: bytes - out.count)
    }

    static func block(_ type: UInt16, _ payload: Data) -> Data {
        le16(Int(type)) + le16(payload.count + 4) + payload
    }

    /// `CS_CORE` : la description de l'écran et du clavier.
    static func core(_ client: ClientDescription) -> Data {
        var payload = Data()
        payload += le32(0x0008_000C)                 // version : RDP 5 et au-delà
        payload += le16(min(max(client.width, 1), maximumWidth))
        payload += le16(min(max(client.height, 1), maximumHeight))
        payload += le16(0xCA01)                      // profondeur héritée : 8 bits
        payload += le16(0xAA03)                      // séquence SAS, valeur imposée
        payload += le32(client.keyboardLayout)
        payload += le32(0)                           // build du client
        payload += utf16Field(client.name, bytes: 32)
        payload += le32(4)                           // clavier IBM 101/102
        payload += le32(0)                           // sous-type
        payload += le32(12)                          // touches de fonction
        payload += Data(repeating: 0, count: 64)     // imeFileName
        payload += le16(0xCA01)                      // postBeta2ColorDepth
        payload += le16(1)                           // clientProductId
        payload += le32(0)                           // numéro de série
        payload += le16(client.colourDepth)
        payload += le16(0x000F)                      // les quatre profondeurs
        payload += le16(0x0001)                      // earlyCapabilityFlags : 32 bits
        payload += Data(repeating: 0, count: 64)     // clientDigProductId
        payload += Data([0x07, 0x00])                // type de liaison, et un octet de garniture
        payload += le32(client.selectedProtocol)
        return block(0xC001, payload)
    }

    /// `CS_SECURITY` : ce que le client sait déchiffrer.
    static func security() -> Data {
        block(0xC002, le32(encryptionMethods) + le32(0))
    }

    /// `CS_NET` : les canaux virtuels demandés, huit octets de nom chacun.
    static func network(_ channels: [Channel]) -> Data {
        var payload = le32(UInt32(channels.count))
        for channel in channels {
            var name = Data(channel.name.utf8.prefix(7))
            name += Data(repeating: 0, count: 8 - name.count)
            payload += name + le32(channel.options)
        }
        return block(0xC003, payload)
    }

    /// `CS_CLUSTER` : ce que le client sait faire d'une redirection.
    static func cluster() -> Data {
        block(0xC004, le32(0x0000_000D) + le32(0))
    }

    // MARK: - Le Connect Initial

    /// Les trois jeux de paramètres de domaine, tels que tout client les
    /// envoie. Ils ne décrivent pas wisq : ils décrivent ce que MCS permet, et
    /// le serveur choisit dans l'intervalle.
    static let targetParameters = Data([
        0x02, 0x01, 0x22, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01,
        0x02, 0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x03, 0x00, 0xFF, 0xFF, 0x02, 0x01, 0x02,
    ])
    static let minimumParameters = Data([
        0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01,
        0x02, 0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x02, 0x04, 0x20, 0x02, 0x01, 0x02,
    ])
    static let maximumParameters = Data([
        0x02, 0x03, 0x00, 0xFF, 0xFF, 0x02, 0x03, 0x00, 0xFC, 0x17, 0x02, 0x03, 0x00, 0xFF, 0xFF,
        0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x01, 0x02, 0x03, 0x00, 0xFF, 0xFF,
        0x02, 0x01, 0x02,
    ])

    /// L'en-tête d'une demande de conférence T.124, jusqu'au nom « Duca ».
    /// C'est une constante du protocole ; le seul champ variable qui suit est
    /// la longueur des données du client.
    static let conferenceHeader = Data([
        0x00, 0x05, 0x00, 0x14, 0x7C, 0x00, 0x01,
    ])
    static let conferenceBody = Data([
        0x00, 0x08, 0x00, 0x10, 0x00, 0x01, 0xC0, 0x00,
        0x44, 0x75, 0x63, 0x61,  // « Duca »
    ])

    /// Le paquet entier, prêt à écrire.
    public static func connectInitial(_ client: ClientDescription) throws -> Data {
        let blocks = core(client) + cluster() + security() + network(client.channels)
        let conference = conferenceHeader
            + RDPPER.length(conferenceBody.count + 2 + blocks.count)
            + conferenceBody + RDPPER.length(blocks.count) + blocks

        var body = Data()
        body += RDPBER.octetString(Data([0x01]))     // callingDomainSelector
        body += RDPBER.octetString(Data([0x01]))     // calledDomainSelector
        body += RDPBER.boolean(true)                 // upwardFlag
        body += RDPBER.sequence(targetParameters)
        body += RDPBER.sequence(minimumParameters)
        body += RDPBER.sequence(maximumParameters)
        body += RDPBER.octetString(conference)
        return try RDPWire.frameData(RDPBER.encode(tag: [0x7F, 0x65], body))
    }

    // MARK: - Ce que le serveur répond

    /// Ce que le Connect Response porte, une fois défait de ses trois
    /// enveloppes.
    public struct ServerDescription: Equatable, Sendable {
        /// Le canal par lequel passent les mises à jour de l'écran et les
        /// entrées. **Sans lui rien n'arrive** : c'est l'identifiant que
        /// chaque message de session porte ensuite.
        public var ioChannel: UInt16
        /// Les canaux virtuels, dans l'ordre où ils ont été demandés.
        public var channels: [UInt16]
        public var encryptionMethod: UInt32
        public var encryptionLevel: UInt32
        /// L'aléa du serveur, quand la sécurité est celle de RDP.
        public var serverRandom: Data
        /// Son certificat, sous la forme que RDP lui donne.
        public var certificate: Data
    }

    /// Combien de canaux un serveur peut annoncer. Le champ en compte seize
    /// bits ; MCS n'en adresse pas plus de mille et quelques, et une réponse
    /// qui en annoncerait soixante mille demanderait une allocation que
    /// personne n'a demandée.
    static let channelLimit = 1000

    public static func readConnectResponse(_ payload: Data) throws -> ServerDescription {
        let outer = [UInt8](try RDPWire.unwrapData(payload))
        let response = try RDPBER.read(outer, at: 0)
        guard response.tag == [0x7F, 0x66] else {
            throw WisqError.handshakeFailed(
                "réponse MCS de type \(response.tag.map { String($0, radix: 16) }.joined())")
        }
        // Le premier champ est le verdict : zéro veut dire « accepté ».
        let result = try RDPBER.read(outer, at: response.range.lowerBound)
        guard result.tag == [0x0A], let verdict = outer[result.range].first, verdict == 0 else {
            throw WisqError.handshakeFailed("le serveur a refusé la conférence MCS")
        }
        guard let userData = try RDPBER.find([0x04], in: outer,
                                             from: result.end, to: response.range.upperBound) else {
            throw WisqError.handshakeFailed("la réponse MCS ne porte aucune donnée serveur")
        }
        return try readServerBlocks(Array(outer[userData.range]))
    }

    /// Les blocs du serveur, derrière l'en-tête de conférence.
    static func readServerBlocks(_ bytes: [UInt8]) throws -> ServerDescription {
        // L'en-tête T.124 de la réponse finit par « McDn » ; ce qui suit est
        // une longueur PER puis les blocs. Le chercher plutôt que de compter
        // les champs PER un par un : les champs d'avant sont facultatifs, et
        // leur nombre change d'un serveur à l'autre.
        guard let mark = bytes.firstRange(of: Array("McDn".utf8)) else {
            throw WisqError.handshakeFailed("réponse de conférence sans « McDn »")
        }
        var index = mark.upperBound
        let declared = try RDPPER.readLength(bytes, at: &index)
        let end = min(bytes.count, index + declared)

        var ioChannel: UInt16?
        var channels: [UInt16] = []
        var method: UInt32 = 0
        var level: UInt32 = 0
        var serverRandom = Data()
        var certificate = Data()

        while index + 4 <= end {
            let type = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2]) | Int(bytes[index + 3]) << 8
            guard length >= 4, index + length <= end else {
                throw WisqError.handshakeFailed("bloc serveur de longueur \(length)")
            }
            let body = Array(bytes[(index + 4)..<(index + length)])
            switch type {
            case 0x0C03:  // SC_NET
                guard body.count >= 4 else { break }
                ioChannel = UInt16(body[0]) | UInt16(body[1]) << 8
                let count = Int(body[2]) | Int(body[3]) << 8
                guard count <= channelLimit else {
                    throw WisqError.handshakeFailed("le serveur annonce \(count) canaux")
                }
                for slot in 0..<count where 4 + slot * 2 + 1 < body.count {
                    channels.append(UInt16(body[4 + slot * 2]) | UInt16(body[5 + slot * 2]) << 8)
                }
            case 0x0C02:  // SC_SECURITY
                guard body.count >= 8 else { break }
                method = le32(body, 0)
                level = le32(body, 4)
                guard body.count >= 16 else { break }
                let randomLength = Int(le32(body, 8))
                let certificateLength = Int(le32(body, 12))
                guard randomLength >= 0, certificateLength >= 0,
                      16 + randomLength + certificateLength <= body.count else {
                    throw WisqError.handshakeFailed(
                        "le bloc de sécurité annonce \(randomLength) + \(certificateLength) octets")
                }
                serverRandom = Data(body[16..<(16 + randomLength)])
                certificate = Data(body[(16 + randomLength)..<(16 + randomLength + certificateLength)])
            default:
                break
            }
            index += length
        }
        guard let ioChannel else {
            throw WisqError.handshakeFailed("le serveur n'a nommé aucun canal d'entrée-sortie")
        }
        return ServerDescription(ioChannel: ioChannel, channels: channels,
                                 encryptionMethod: method, encryptionLevel: level,
                                 serverRandom: serverRandom, certificate: certificate)
    }

    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

extension Array where Element == UInt8 {
    /// Où se trouve cette suite d'octets, si elle s'y trouve.
    func firstRange(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        for start in 0...(count - needle.count) where Array(self[start..<(start + needle.count)]) == needle {
            return start..<(start + needle.count)
        }
        return nil
    }
}
