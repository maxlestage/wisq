import Foundation

/// L'en-tête de démarrage d'un noyau Linux pour PC — un « bzImage ».
///
/// Ce n'est pas une reconnaissance de signature déguisée. Un bzImage porte,
/// dans ses premiers octets, tout ce qu'un chargeur doit savoir pour le
/// démarrer : où le placer, s'il accepte d'être déplacé, quelle taille lui
/// réserver avant de sauter dedans, combien de caractères sa ligne de commande
/// accepte, et — le champ qui nous intéresse le plus ici — s'il possède un
/// point d'entrée 64 bits. Lire ces champs maintenant, c'est écrire la moitié
/// du chargeur du lot 7 avant d'écrire le décodeur.
///
/// **Mesuré, pas recopié.** Les décalages viennent de la documentation du
/// noyau, mais chaque valeur que les tests épinglent a été lue sur un vrai
/// fichier : `vmlinuz-lts` d'Alpine Linux 3.20 pour x86_64,
/// 10 961 920 octets, sha256
/// `e21457092692d8bc581d9d673636e8a9b81f89b2b8bab40dd2eaad22b6a64958`.
///
/// **Les champs apparaissent avec les versions.** Le protocole a grandi ;
/// `xloadflags` n'existe qu'à partir de 2.12, `pref_address` et `init_size` à
/// partir de 2.10. Lire un champ qu'un vieux noyau n'a jamais écrit, ce serait
/// lire le hasard. Chaque champ est donc gardé par la version qui l'a
/// introduit, et vaut zéro en dessous — ce qui est la vérité (« ce noyau ne le
/// dit pas »), pas une supposition.
public struct LinuxBootProtocol: Equatable, Sendable {
    /// La version du protocole, telle que le noyau l'écrit : octet haut la
    /// majeure, octet bas la mineure. 0x020F = 2.15.
    public let version: UInt16
    /// La taille du code de mode réel (« setup »), en tête du fichier.
    public let setupBytes: Int
    /// La taille du reste — le noyau en mode protégé, compressé.
    public let protectedModeBytes: Int
    /// `loadflags` : le bit 0 dit que le noyau va en haut de la mémoire.
    public let loadFlags: UInt8
    /// `xloadflags` : le bit 0 dit qu'il existe un point d'entrée 64 bits.
    /// Zéro avant 2.12, où le champ n'existe pas.
    public let extraLoadFlags: UInt16
    /// Le noyau accepte d'être placé ailleurs qu'à son adresse préférée.
    public let relocatable: Bool
    /// L'adresse où le noyau préfère être chargé. Zéro avant 2.10.
    public let preferredAddress: UInt64
    /// La place totale à réserver à partir de là — le noyau décompressé
    /// occupera bien plus que ce que le fichier pèse. Zéro avant 2.10.
    public let initSize: UInt32
    /// La longueur maximale de la ligne de commande, sans le zéro final.
    /// Zéro avant 2.06.
    public let commandLineLimit: UInt32

    /// Le bit qui distingue un noyau x86-64 d'un noyau x86 : `XLF_KERNEL_64`.
    ///
    /// C'est le seul énoncé du fichier sur son propre mode. Un bzImage n'a pas
    /// d'en-tête ELF qui nommerait sa machine ; il a ce bit, et rien d'autre.
    public var hasSixtyFourBitEntry: Bool { extraLoadFlags & 0x0001 != 0 }

    /// Comment nommer l'architecture à quelqu'un.
    ///
    /// Un noyau d'avant 2.12 n'a pas de `xloadflags` et sera donc nommé
    /// « x86 ». Ce n'est pas un défaut de lecture : du point de vue d'un
    /// chargeur, un tel noyau n'offre que son entrée 32 bits, et c'est
    /// exactement ce que la phrase dit.
    public var architecture: String { hasSixtyFourBitEntry ? "x86-64" : "x86" }

    /// « 2.15 » — la version telle qu'on l'écrit dans une phrase.
    public var versionDescription: String { "\(version >> 8).\(version & 0xFF)" }

    /// Ce que le fichier pèse d'après son propre en-tête.
    public var declaredBytes: Int { setupBytes + protectedModeBytes }

    // Les décalages, tels que Documentation/arch/x86/boot.rst les donne.
    static let setupSectorsOffset = 0x01F1
    static let systemSizeOffset = 0x01F4
    static let bootFlagOffset = 0x01FE
    static let headerMagicOffset = 0x0202
    static let versionOffset = 0x0206
    static let loadFlagsOffset = 0x0211
    static let relocatableOffset = 0x0234
    static let extraLoadFlagsOffset = 0x0236
    static let commandLineSizeOffset = 0x0238
    static let preferredAddressOffset = 0x0258
    static let initSizeOffset = 0x0260
    /// Le dernier champ qui nous intéresse finit à 0x0264 ; en lire jusque-là
    /// suffit à décider.
    static let headerBytes = 0x0264

    /// Les deux marques d'un bzImage : la signature d'un secteur d'amorçage à
    /// 0x1FE, et « HdrS » à 0x202.
    static let bootFlag: UInt16 = 0xAA55
    static let headerMagic = Array("HdrS".utf8)

    /// L'en-tête lu, ou nil si ces octets ne sont pas un bzImage.
    ///
    /// `totalBytes` est la taille réelle du fichier quand l'appelant la
    /// connaît. Elle sert à une vérification que ni « HdrS » ni 0xAA55 ne
    /// donnent : un bzImage **est** son setup suivi de son noyau, donc
    /// `setup + syssize` ne peut pas dépasser le fichier. C'est une inégalité
    /// et non une égalité, parce qu'un noyau signé porte sa signature après —
    /// sur le fichier mesuré ici les deux nombres tombent juste
    /// (20 480 + 10 941 440 = 10 961 920), mais l'exiger refuserait les noyaux
    /// signés d'Ubuntu ou de Fedora.
    public static func read(from bytes: [UInt8], totalBytes: Int? = nil) -> LinuxBootProtocol? {
        guard bytes.count >= headerBytes else { return nil }
        guard u16(bytes, bootFlagOffset) == bootFlag else { return nil }
        guard Array(bytes[headerMagicOffset..<(headerMagicOffset + 4)]) == headerMagic else {
            return nil
        }
        let version = u16(bytes, versionOffset)
        guard version >= 0x0200 else { return nil }

        // setup_sects vaut zéro sur les tout premiers noyaux, et veut alors
        // dire quatre. Le secteur d'amorçage lui-même s'ajoute toujours.
        let sectors = bytes[setupSectorsOffset] == 0 ? 4 : Int(bytes[setupSectorsOffset])
        let setupBytes = (sectors + 1) * 512
        // syssize compte en paragraphes de seize octets.
        let protectedModeBytes = Int(u32(bytes, systemSizeOffset)) * 16
        if let totalBytes, setupBytes + protectedModeBytes > totalBytes { return nil }

        return LinuxBootProtocol(
            version: version,
            setupBytes: setupBytes,
            protectedModeBytes: protectedModeBytes,
            loadFlags: bytes[loadFlagsOffset],
            extraLoadFlags: version >= 0x020C ? u16(bytes, extraLoadFlagsOffset) : 0,
            relocatable: version >= 0x0205 && bytes[relocatableOffset] != 0,
            preferredAddress: version >= 0x020A ? u64(bytes, preferredAddressOffset) : 0,
            initSize: version >= 0x020A ? u32(bytes, initSizeOffset) : 0,
            commandLineLimit: version >= 0x0206 ? u32(bytes, commandLineSizeOffset) : 0)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(into: UInt32(0)) { $0 |= UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(into: UInt64(0)) { $0 |= UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }
}
