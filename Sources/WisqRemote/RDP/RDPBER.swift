import Foundation
import WisqCore

/// Juste assez d'ASN.1 pour MCS, et rien de plus.
///
/// **Pourquoi pas une bibliothèque.** MCS n'emploie que six formes — un
/// entier, une chaîne d'octets, un booléen, un énuméré, une séquence, et une
/// étiquette d'application à deux octets — et toujours en longueur définie.
/// Un décodeur général saurait lire des choses que RDP n'envoie jamais, et
/// c'est précisément la surface qu'un serveur hostile viendrait chercher.
///
/// **T.125 encode en BER, T.124 en PER, et les deux voyagent dans le même
/// paquet** : la charge utile du Connect Initial est du PER emballé dans une
/// chaîne d'octets BER. Les deux sont ici, séparés, parce que les confondre
/// est l'erreur qui coûte le plus cher à trouver — les longueurs se ressemblent
/// et ne se lisent pas pareil.
enum RDPBER {
    // MARK: - Écrire

    /// Une longueur BER : courte sous 128, longue au-delà, sur le nombre
    /// d'octets qu'il faut.
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func encode(tag: [UInt8], _ payload: Data) -> Data {
        Data(tag) + length(payload.count) + payload
    }

    /// Un entier BER, dans le plus petit nombre d'octets qui le dit — c'est ce
    /// que fait le client de référence, et deux encodages du même nombre
    /// donneraient deux paquets différents pour une même intention.
    static func integer(_ value: UInt32) -> Data {
        var bytes: [UInt8] = []
        var rest = value
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        // Un octet de tête ≥ 0x80 se lirait négatif : BER veut un zéro devant.
        if bytes[0] >= 0x80 { bytes.insert(0, at: 0) }
        return encode(tag: [0x02], Data(bytes))
    }

    static func octetString(_ payload: Data) -> Data { encode(tag: [0x04], payload) }
    static func boolean(_ value: Bool) -> Data { encode(tag: [0x01], Data([value ? 0xFF : 0x00])) }
    static func sequence(_ payload: Data) -> Data { encode(tag: [0x30], payload) }

    // MARK: - Lire

    /// Ce qu'on vient de lire : son étiquette, et où sa charge se trouve.
    struct Element {
        var tag: [UInt8]
        var range: Range<Int>
        /// Là où l'élément suivant commence.
        var end: Int
    }

    /// Lire une étiquette et sa longueur à partir de `at`.
    ///
    /// **Les longueurs sont bornées par ce qui reste.** Un serveur qui annonce
    /// quatre gibioctets dans deux octets de longueur ne fait pas tomber le
    /// client : il se fait refuser ici, avant qu'on ait réservé quoi que ce
    /// soit — la même règle que les plafonds de RFB.
    static func read(_ bytes: [UInt8], at start: Int) throws -> Element {
        var index = start
        func byte() throws -> UInt8 {
            guard index < bytes.count else { throw WisqError.malformedMessage("BER tronqué") }
            defer { index += 1 }
            return bytes[index]
        }
        var tag: [UInt8] = [try byte()]
        // Une étiquette dont les cinq bits bas valent 31 continue sur l'octet
        // suivant : c'est la forme que prend `[APPLICATION 101]`.
        if tag[0] & 0x1F == 0x1F { tag.append(try byte()) }
        let first = try byte()
        var count = Int(first)
        if first & 0x80 != 0 {
            let width = Int(first & 0x7F)
            guard width >= 1, width <= 4 else {
                throw WisqError.malformedMessage("longueur BER sur \(width) octets")
            }
            count = 0
            for _ in 0..<width { count = count << 8 | Int(try byte()) }
        }
        guard count >= 0, index + count <= bytes.count else {
            throw WisqError.malformedMessage(
                "BER annonce \(count) octets, il en reste \(bytes.count - index)")
        }
        return Element(tag: tag, range: index..<(index + count), end: index + count)
    }

    /// Descendre dans une suite d'éléments jusqu'à celui qui porte l'étiquette
    /// voulue, sans regarder plus loin que le conteneur.
    static func find(_ tag: [UInt8], in bytes: [UInt8],
                     from start: Int, to end: Int) throws -> Element? {
        var index = start
        while index < end {
            let element = try read(bytes, at: index)
            if element.tag == tag { return element }
            index = element.end
        }
        return nil
    }
}

/// Les deux formes de longueur que T.124 emploie, et rien d'autre.
///
/// PER encode une longueur soit sur un octet quand elle tient sous 128, soit
/// sur deux avec les bits de tête `10`. **Ce n'est pas du BER** : `81 48` y
/// vaut 0x148, pas « un octet de longueur suivi de 0x48 ». Les lire avec le
/// mauvais décodeur donne un paquet qui commence bien et se termine douze
/// octets trop tôt.
enum RDPPER {
    static func length(_ count: Int) -> Data {
        count < 0x80 ? Data([UInt8(count)])
                     : Data([0x80 | UInt8(count >> 8), UInt8(count & 0xFF)])
    }

    static func readLength(_ bytes: [UInt8], at index: inout Int) throws -> Int {
        guard index < bytes.count else { throw WisqError.malformedMessage("PER tronqué") }
        let first = bytes[index]; index += 1
        guard first & 0x80 != 0 else { return Int(first) }
        guard index < bytes.count else { throw WisqError.malformedMessage("PER tronqué") }
        let second = bytes[index]; index += 1
        return Int(first & 0x3F) << 8 | Int(second)
    }
}
