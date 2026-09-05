#if canImport(Glibc)
import Foundation

/// Ce qu'un **vrai serveur** a envoyé, octet pour octet.
///
/// **Aucun de ces vecteurs n'est de moi.** Ils sortent d'une session ouverte
/// contre xrdp 0.9 dans ce conteneur, capturée après déchiffrement : la sonde
/// a écrit chaque PDU en clair dans un fichier, et ce fichier est recopié ici.
/// Un vecteur que j'aurais écrit d'après la spécification prouverait seulement
/// que je lis la spécification comme je l'ai codée ; celui-ci prouve qu'un
/// serveur envoie bien ça.
///
/// La session : `xrdp --nodaemon` sur 127.0.0.1:3389, sécurité historique,
/// RC4 128 bits, écran 1024x768 en 24 bits.
enum RDPServerFixtures {
    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// Le premier message que xrdp envoie après le Client Info : une demande de
    /// licence de 318 octets, dont le préambule dit 0x013e.
    static let licenseRequest = bytes(
        "01023e017b3c31a6aee874f6b4a50390e7c2c739ba531c30546e9005d005ce44" +
        "18918381000004002c0000004d006900630072006f0073006f00660074002000" +
        "43006f00720070006f0072006100740069006f006e0000000800000032003300" +
        "360000000d000400010000000300b80001000000010000000100000006005c00" +
        "5253413148000000000200003f0000000100010001c7c9f78e5a38e429c30095" +
        "2ddd4c3e50450b0d9e2a5d186364c42cf78f29d53fc5352234ffad3ae6e39506" +
        "ae5582e3c8c7b4a847c85071742953896d9ced70000000000000000008004800" +
        "a8f431b9ab4be6b4f43989d6b1daf61eecb1f0543b5e3e6a71b4f775c8162f24" +
        "00dee982995f330ba9a694afcb11c3f2db0942682956580156db590369db7d37" +
        "0000000000000000010000000e000e006d6963726f736f66742e636f6d00")

    /// Sa réponse à notre demande : une alerte dont le code est 7,
    /// `STATUS_VALID_CLIENT` — ce qui veut dire que tout va bien.
    static let statusValidClient = bytes(
        "ff021000070000000200000028140000")

    /// Le Demand Active : treize jeux de capacités, 1024x768 en 24 bits.
    static let demandActive = bytes(
        "9a011100ec03ea03010004008401524450000d00000009000800ec03b5e20100" +
        "1800010003000002000000000104000000000000010102001c00180001000100" +
        "0100000400030000010001000000000000000e00040003005800000000000000" +
        "0000000000000000000040420f0001001400000001002f002200010101010000" +
        "0000010001000000000000000100000000000000000100000000a10602004042" +
        "0f0040420f0001000000000000001d005d0004b91b8dca0f004f15589fae2d1a" +
        "87e2d6010300010103122f777672bd6344afb3b73c9c6f788600040000000000" +
        "d4cc44278a9d744e803c0ecbeea19c5400040000000000e64caf1bed9e0c4386" +
        "9acb8b37b662370001004b0a0008000600000008000a000100190019000d0058" +
        "003d010000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "00000000000000000000000000000000000000000006000500001a0008000040" +
        "30001e000800020000001c000c00520000000000000000000000")

    /// La synchronisation que le serveur renvoie après notre Confirm Active.
    static let serverSynchronise = bytes(
        "16001700ec03ea030100000116001f0016000100ea03")

    /// Son contrôle « coopérer » (action 4).
    static let serverControlCooperate = bytes(
        "1a001700ec03ea03010000011a0014001a0004000000ea030000")

    /// Son contrôle « accordé » (action 2) : la session est à nous.
    static let serverControlGranted = bytes(
        "1a001700ec03ea03010000011a0014001a0002000000ea030000")

    /// Sa carte des polices : le dernier message de l'établissement.
    static let serverFontMap = bytes(
        "1a001700ec03ea03010000011a0028001a000000000003000400")

    /// Et sa première mise à jour, qui suit immédiatement.
    static let serverFirstUpdate = bytes(
        "16001700ec03ea030100000116000200160003000000")
}
#endif
