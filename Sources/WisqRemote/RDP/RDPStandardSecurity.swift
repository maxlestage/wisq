import Foundation
import WisqCore

/// La sécurité d'origine de RDP : l'échange de clés, les clés de session, et
/// la signature de chaque message.
///
/// **Ce que c'est, dit franchement.** RC4 pour chiffrer, MD5 et SHA-1 pour
/// dériver, et un échange de clés qui **n'authentifie pas le serveur** : le
/// certificat propriétaire est signé par une clé que Microsoft a publiée en
/// 1998. N'importe qui sur le chemin peut se mettre au milieu. Ce n'est pas un
/// défaut de cette écriture-ci, c'est ce que le protocole fait.
///
/// **Pourquoi wisq l'écrit quand même.** Un serveur qui n'offre que celle-là
/// ne se laisse pas convaincre, et il en reste — de vieux hyperviseurs, des
/// appliances. wisq demande TLS d'abord, et ne descend ici que si le serveur
/// ne sait rien faire d'autre. Ce qui compte alors est de le **dire** à qui se
/// connecte, pas de faire semblant que la session est protégée.
public struct RDPStandardSecurity {
    /// Les drapeaux de l'en-tête de sécurité, ceux dont RDP se sert vraiment.
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let exchange = Flags(rawValue: 0x0001)
        public static let encrypt = Flags(rawValue: 0x0008)
        public static let resetSequence = Flags(rawValue: 0x0010)
        public static let ignoreSequence = Flags(rawValue: 0x0020)
        public static let info = Flags(rawValue: 0x0040)
        public static let licence = Flags(rawValue: 0x0080)
        public static let licenceEncryptClient = Flags(rawValue: 0x0200)
        public static let secureChecksum = Flags(rawValue: 0x0800)
    }

    /// La clé publique du serveur, sortie de son certificat propriétaire.
    public struct PublicKey: Equatable, Sendable {
        /// Le module, en petit-boutiste, garniture comprise — RDP en met huit
        /// octets nuls à la fin, et le chiffré doit faire la même taille.
        public var modulus: [UInt8]
        public var exponent: [UInt8]
        /// La taille utile, en octets : `bitlen / 8`. Le chiffré fait
        /// exactement ça, plus la garniture.
        public var usefulBytes: Int
    }

    /// Lire la clé publique d'un certificat propriétaire.
    ///
    /// **Seule la version 1 est acceptée.** La version 2 est une chaîne X.509,
    /// que RDP n'emploie que lorsque la sécurité est déjà TLS — auquel cas ce
    /// chemin-ci ne sert pas. Accepter les deux ici voudrait dire écrire un
    /// analyseur X.509 dont personne n'aurait besoin.
    public static func publicKey(fromCertificate certificate: [UInt8]) throws -> PublicKey {
        guard certificate.count >= 16 else {
            throw WisqError.handshakeFailed("certificat du serveur tronqué")
        }
        let version = le32(certificate, 0) & 0x7FFF_FFFF
        guard version == 1 else {
            throw WisqError.handshakeFailed(
                "certificat de version \(version) : wisq ne lit que le format propriétaire ici")
        }
        let blobType = UInt16(certificate[12]) | UInt16(certificate[13]) << 8
        let blobLength = Int(certificate[14]) | Int(certificate[15]) << 8
        guard blobType == 0x0006, 16 + blobLength <= certificate.count, blobLength >= 20 else {
            throw WisqError.handshakeFailed("le certificat ne porte pas de clé publique lisible")
        }
        let blob = Array(certificate[16..<(16 + blobLength)])
        guard Array(blob[0..<4]) == Array("RSA1".utf8) else {
            throw WisqError.handshakeFailed("clé publique qui ne dit pas « RSA1 »")
        }
        let keyLength = Int(le32(blob, 4))
        let bitLength = Int(le32(blob, 8))
        // **Les trois longueurs doivent concorder.** Un certificat qui annonce
        // un module plus grand que son propre bloc ferait une tranche hors
        // bornes, et c'est exactement ce qu'un serveur hostile enverrait.
        guard keyLength >= 8, bitLength > 0, bitLength % 8 == 0,
              bitLength / 8 + 8 == keyLength, 20 + keyLength <= blob.count else {
            throw WisqError.handshakeFailed(
                "clé publique incohérente : \(bitLength) bits pour \(keyLength) octets")
        }
        return PublicKey(modulus: Array(blob[20..<(20 + keyLength)]),
                         exponent: Array(blob[16..<20]),
                         usefulBytes: bitLength / 8)
    }

    // MARK: - Les clés de session

    static let pad1 = [UInt8](repeating: 0x36, count: 40)
    static let pad2 = [UInt8](repeating: 0x5C, count: 48)

    /// Le haché salé de MS-RDPBCGR 5.3.5.1 : un SHA-1 replié dans un MD5.
    static func saltedHash(_ secret: [UInt8], _ salt: [UInt8],
                           _ clientRandom: [UInt8], _ serverRandom: [UInt8]) -> [UInt8] {
        let inner = RDPCrypto.sha1(salt + secret + clientRandom + serverRandom)
        return RDPCrypto.md5(secret + inner)
    }

    static func finalHash(_ key: [UInt8], _ clientRandom: [UInt8], _ serverRandom: [UInt8]) -> [UInt8] {
        RDPCrypto.md5(key + clientRandom + serverRandom)
    }

    /// Tout ce qu'une session chiffrée garde.
    public struct Keys: Sendable {
        public var macKey: [UInt8]
        public var clientToServer: [UInt8]
        public var serverToClient: [UInt8]
        /// Les clés de départ, gardées : le rafraîchissement repart d'elles.
        var initialClientToServer: [UInt8]
        var initialServerToClient: [UInt8]
        var method: UInt32
    }

    /// Dériver les clés, à partir des deux aléas.
    ///
    /// **Les deux moitiés ne sont pas symétriques.** Le pré-secret prend
    /// vingt-quatre octets de chaque aléa ; les hachés en reprennent
    /// trente-deux. Prendre trente-deux partout — l'erreur naturelle — donne
    /// des clés qui ont l'air bonnes et que le serveur rejette au premier
    /// message signé, sans dire pourquoi.
    public static func deriveKeys(clientRandom: [UInt8], serverRandom: [UInt8],
                                  method: UInt32) throws -> Keys {
        guard clientRandom.count >= 32, serverRandom.count >= 32 else {
            throw WisqError.handshakeFailed("aléa de session trop court")
        }
        let client = Array(clientRandom.prefix(32))
        let server = Array(serverRandom.prefix(32))
        // MS-RDPBCGR nomme ces deux valeurs le « pre-master secret » et le
        // « master secret » ; le dépôt refuse ce mot, et les noms d'ici disent
        // la même chose : un pré-secret, puis le secret dont tout le reste sort.
        let preSecret = Array(client.prefix(24)) + Array(server.prefix(24))

        let rootSecret = saltedHash(preSecret, Array("A".utf8), client, server)
            + saltedHash(preSecret, Array("BB".utf8), client, server)
            + saltedHash(preSecret, Array("CCC".utf8), client, server)
        let session = saltedHash(rootSecret, Array("X".utf8), client, server)
            + saltedHash(rootSecret, Array("YY".utf8), client, server)
            + saltedHash(rootSecret, Array("ZZZ".utf8), client, server)

        let macKey = Array(session[0..<16])
        var toServer = finalHash(Array(session[32..<48]), client, server)
        var fromServer = finalHash(Array(session[16..<32]), client, server)

        // Quarante et cinquante-six bits : la clé garde sa taille mais perd
        // ses premiers octets au profit de constantes connues. C'est
        // l'affaiblissement que l'export américain imposait en 1998, et il est
        // encore dans le protocole.
        if method == 1 || method == 8 {
            let weakened = method == 1 ? 3 : 1
            let constants: [UInt8] = method == 1 ? [0xD1, 0x26, 0x9E] : [0xD1]
            for index in 0..<weakened {
                toServer[index] = constants[index]
                fromServer[index] = constants[index]
            }
        }
        return Keys(macKey: macKey, clientToServer: toServer, serverToClient: fromServer,
                    initialClientToServer: toServer, initialServerToClient: fromServer,
                    method: method)
    }

    /// La signature d'un message : huit octets, à mettre devant le chiffré.
    public static func signature(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        let length: [UInt8] = [UInt8(data.count & 0xFF), UInt8((data.count >> 8) & 0xFF),
                               UInt8((data.count >> 16) & 0xFF), UInt8((data.count >> 24) & 0xFF)]
        let inner = RDPCrypto.sha1(key + pad1 + length + data)
        return Array(RDPCrypto.md5(key + pad2 + inner).prefix(8))
    }

    // MARK: - Ce qu'on envoie

    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// L'en-tête de sécurité : deux mots de seize bits, et c'est tout quand le
    /// message n'est pas chiffré.
    public static func header(_ flags: Flags) -> Data {
        le16(flags.rawValue) + le16(0)
    }

    /// Le PDU d'échange de clés : l'aléa du client, chiffré pour le serveur.
    ///
    /// **Le chiffré est en petit-boutiste et fait la taille du module**,
    /// garniture comprise. Le tronquer à la taille utile — ce qui semble
    /// raisonnable — donne un paquet que le serveur lit court et déchiffre en
    /// bruit.
    public static func securityExchange(clientRandom: [UInt8], key: PublicKey) throws -> Data {
        guard clientRandom.count == 32 else {
            throw WisqError.handshakeFailed("l'aléa du client fait 32 octets")
        }
        let encrypted = RDPCrypto.modularPower(base: clientRandom, exponent: key.exponent,
                                               modulus: key.modulus)
        guard !encrypted.isEmpty else {
            throw WisqError.handshakeFailed("la clé publique du serveur est inutilisable")
        }
        var body = header([.exchange, .licenceEncryptClient])
        body += le32(UInt32(key.usefulBytes + 8))
        body += Data(encrypted.prefix(key.usefulBytes))
        body += Data(repeating: 0, count: 8)
        return body
    }

    /// Chiffrer et signer un message de session.
    ///
    /// **La signature porte sur le clair, et se calcule avant le chiffrement.**
    /// L'inverse — signer le chiffré — se compile aussi bien et se fait
    /// refuser à chaque message.
    public mutating func seal(_ payload: Data, flags: Flags = []) -> Data {
        let clear = [UInt8](payload)
        let mac = Self.signature(clear, key: keys.macKey)
        let sealed = toServer.process(clear)
        sent += 1
        return Self.header(flags.union([.encrypt])) + Data(mac) + Data(sealed)
    }

    /// Ouvrir un message venu du serveur, et **vérifier sa signature**.
    ///
    /// Un client qui déchiffre sans vérifier accepte n'importe quels octets
    /// d'un intermédiaire, et les affiche.
    public mutating func open(_ payload: Data) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count >= 12 else {
            throw WisqError.malformedMessage("message chiffré tronqué")
        }
        let flags = Flags(rawValue: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        guard flags.contains(.encrypt) else { return Data(bytes[4...]) }
        let mac = Array(bytes[4..<12])
        let clear = fromServer.process(Array(bytes[12...]))
        guard Self.signature(clear, key: keys.macKey) == mac else {
            throw WisqError.handshakeFailed("signature invalide : le message a été modifié")
        }
        received += 1
        return Data(clear)
    }

    var keys: Keys
    private var toServer: RDPCrypto.RC4
    private var fromServer: RDPCrypto.RC4
    private var sent = 0
    private var received = 0

    public init(keys: Keys) {
        self.keys = keys
        toServer = RDPCrypto.RC4(key: keys.clientToServer)
        fromServer = RDPCrypto.RC4(key: keys.serverToClient)
    }
}
