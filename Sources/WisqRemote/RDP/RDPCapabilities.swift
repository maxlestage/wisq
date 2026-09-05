import Foundation
import WisqCore

/// Ce que les deux côtés savent faire, et l'accord qui en sort.
///
/// **C'est une négociation, pas une déclaration.** Le serveur envoie ce qu'il
/// sait ; le client répond ce qu'il sait ; ce qui suit n'emploie que
/// l'intersection. Annoncer une capacité qu'on n'a pas ne fait pas échouer la
/// connexion — elle fait envoyer au serveur des messages qu'on ne saura pas
/// lire, et le premier est un écran de bruit.
public enum RDPCapabilities {
    public enum Kind: UInt16, Sendable {
        case general = 1
        case bitmap = 2
        case order = 3
        case bitmapCache = 4
        case control = 5
        case activation = 7
        case pointer = 8
        case share = 9
        case colourCache = 10
        case sound = 12
        case input = 13
        case font = 14
        case brush = 15
        case glyphCache = 16
        case offscreenCache = 17
        case virtualChannel = 20
        case multiFragmentUpdate = 26
        case largePointer = 27
        case surfaceCommands = 28
        case bitmapCodecs = 29
        case frameAcknowledge = 30
    }

    /// Ce qu'on retient du Demand Active du serveur.
    public struct ServerOffer: Equatable, Sendable {
        public var shareId: UInt32
        public var source: UInt16
        public var width: Int
        public var height: Int
        public var colourDepth: Int
        /// Les types annoncés, dans l'ordre. Gardés parce qu'un serveur qui
        /// n'annonce pas le pointeur, par exemple, n'enverra jamais de curseur
        /// — et qu'attendre indéfiniment un message qui ne viendra pas est un
        /// défaut qu'on ne voit qu'en le cherchant.
        public var offered: [UInt16]
    }

    /// Combien de jeux de capacités un serveur peut annoncer. Le champ en
    /// compte seize bits ; MS-RDPBCGR en définit trente, et un serveur qui en
    /// annoncerait soixante mille demanderait une boucle de soixante mille
    /// tours sur des octets qu'il n'a pas envoyés.
    static let setLimit = 256

    /// Lire un Demand Active.
    public static func readDemandActive(_ body: Data, source: UInt16) throws -> ServerOffer {
        let bytes = [UInt8](body)
        guard bytes.count >= 12 else {
            throw WisqError.handshakeFailed("Demand Active tronqué")
        }
        let shareId = RDPStandardSecurity.le32(bytes, 0)
        let descriptorLength = Int(bytes[4]) | Int(bytes[5]) << 8
        let capabilitiesLength = Int(bytes[6]) | Int(bytes[7]) << 8
        var index = 8 + descriptorLength
        guard index + 4 <= bytes.count, index + capabilitiesLength <= bytes.count + 4 else {
            throw WisqError.handshakeFailed("Demand Active dont les longueurs ne concordent pas")
        }
        let count = Int(bytes[index]) | Int(bytes[index + 1]) << 8
        guard count <= setLimit else {
            throw WisqError.handshakeFailed("le serveur annonce \(count) jeux de capacités")
        }
        index += 4

        var width = 0, height = 0, depth = 0
        var offered: [UInt16] = []
        for _ in 0..<count {
            guard index + 4 <= bytes.count else { break }
            let type = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2]) | Int(bytes[index + 3]) << 8
            guard length >= 4, index + length <= bytes.count else {
                throw WisqError.handshakeFailed("jeu de capacités de longueur \(length)")
            }
            offered.append(type)
            if type == Kind.bitmap.rawValue, length >= 16 {
                depth = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8
                width = Int(bytes[index + 12]) | Int(bytes[index + 13]) << 8
                height = Int(bytes[index + 14]) | Int(bytes[index + 15]) << 8
            }
            index += length
        }
        guard width > 0, height > 0 else {
            throw WisqError.handshakeFailed("le serveur n'a pas dit la taille de son écran")
        }
        return ServerOffer(shareId: shareId, source: source, width: width, height: height,
                           colourDepth: depth, offered: offered)
    }

    // MARK: - Ce que wisq annonce

    static func set(_ kind: Kind, _ payload: Data) -> Data {
        RDPStandardSecurity.le16(kind.rawValue)
            + RDPStandardSecurity.le16(UInt16(payload.count + 4)) + payload
    }

    static func le16(_ value: Int) -> Data { RDPStandardSecurity.le16(UInt16(truncatingIfNeeded: value)) }
    static func le32(_ value: UInt32) -> Data { RDPStandardSecurity.le32(value) }

    /// Les jeux que wisq envoie, dans l'ordre où un client les envoie.
    ///
    /// **Ce qui n'y est pas est délibéré.** Pas de cache bitmap, pas de cache
    /// de glyphes, pas de commandes de surface : wisq peint des rectangles
    /// bruts, et annoncer un cache qu'on ne tient pas ferait envoyer au serveur
    /// des références à des images qu'on n'a jamais gardées.
    public static func clientCapabilities(width: Int, height: Int, depth: Int) -> Data {
        var out = Data()
        var count = 0
        func add(_ kind: Kind, _ payload: Data) { out += set(kind, payload); count += 1 }

        // GENERAL : le système, la version, et **aucune compression**.
        add(.general, le16(1) + le16(3) + le16(0x0200) + le16(0)
            + le16(0) + le16(0) + le16(0) + le16(0) + le16(0) + le16(0))

        // BITMAP : la taille de l'écran, telle que le serveur l'a dite. On la
        // renvoie inchangée : un client peut demander autre chose, ce qui
        // déclenche une renégociation que wisq ne sait pas encore conduire.
        // **La profondeur, elle, n'est pas vérifiée par xrdp** — annoncer huit
        // bits pour un écran qui en a vingt-quatre passe sans un mot, et ce
        // qu'on recevrait serait faux sans que rien ne le dise.
        add(.bitmap, le16(depth) + le16(1) + le16(1) + le16(1)
            + le16(width) + le16(height) + le16(0) + le16(1)
            + le16(0) + le16(1) + le16(0) + le16(0))

        // ORDER : aucun ordre de dessin. wisq ne sait pas exécuter les
        // primitives de GDI ; le serveur enverra donc des bitmaps, ce qui est
        // plus gros et ce qu'on sait lire.
        var order = Data(repeating: 0, count: 16)       // terminalDescriptor
        order += le32(0) + le16(1) + le16(20) + le16(0) + le16(1) + le16(0) + le16(0x0002)
        order += Data(repeating: 0, count: 32)          // aucun ordre pris en charge
        order += le16(0) + le16(0) + le32(0) + le32(230_400) + le32(0) + le32(0)
        add(.order, order)

        // POINTER : le curseur en couleur, et un cache petit mais réel.
        add(.pointer, le16(1) + le16(25) + le16(25))

        // INPUT : le clavier et la souris, avec la disposition demandée.
        var input = le16(0x0001 | 0x0004)               // scancodes, unités de souris
        input += le16(0) + le32(4) + le32(0) + le32(12)
        input += Data(repeating: 0, count: 64)          // imeFileName
        add(.input, input)

        // BRUSH, GLYPHCACHE, OFFSCREEN, SOUND : les minimums que le serveur
        // attend de voir, même vides.
        add(.brush, le32(0))
        add(.sound, le16(0) + le16(0))
        add(.share, le16(0) + le16(0))
        add(.colourCache, le16(6) + le16(0))
        add(.font, le16(1) + le16(0))
        add(.virtualChannel, le32(0) + le32(0))

        return le16(count) + le16(0) + out
    }

    /// Le Confirm Active, prêt à emballer.
    ///
    /// **L'identifiant d'origine n'est pas le canal du client** mais `0x03EA`,
    /// une constante du protocole. Mesuré contre xrdp : ni cette constante ni
    /// l'identifiant de partage qu'on y renvoie ne sont vérifiés — les deux
    /// peuvent être faux sans que la session s'en aperçoive. On les écrit
    /// justes parce que la spécification les demande, et parce qu'un serveur
    /// qui les vérifierait ne dirait pas pourquoi il refuse.
    public static func confirmActive(offer: ServerOffer, source: UInt16,
                                     width: Int, height: Int, depth: Int) -> Data {
        let capabilities = clientCapabilities(width: width, height: height, depth: depth)
        var body = le32(offer.shareId)
        body += RDPStandardSecurity.le16(RDPShare.confirmOriginator)
        body += le16(4)                                  // longueur du descripteur
        body += le16(capabilities.count)
        body += Data("RDP\u{0}".utf8)
        body += capabilities
        return RDPShare.control(.confirmActive, source: source, body)
    }
}
