import Foundation
import WisqCore

/// Le premier message chiffré : qui se connecte, et comment il veut sa session.
///
/// **C'est ici que le mot de passe traverse.** Il ne doit apparaître nulle part
/// ailleurs — ni dans une description, ni dans un journal, ni dans une erreur.
/// Le type ne le garde pas : il l'écrit dans le paquet et l'oublie.
public enum RDPClientInfo {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let mouse = Flags(rawValue: 0x0000_0001)
        public static let disableCtrlAltDelete = Flags(rawValue: 0x0000_0002)
        public static let unicode = Flags(rawValue: 0x0000_0010)
        public static let maximiseShell = Flags(rawValue: 0x0000_0020)
        public static let logonNotify = Flags(rawValue: 0x0000_0040)
        public static let compression = Flags(rawValue: 0x0000_0080)
        public static let enableWindowsKey = Flags(rawValue: 0x0000_0100)
        public static let forceEncryptedCSPDU = Flags(rawValue: 0x0000_4000)
        /// Sans lui le serveur ne lit pas la partie étendue, où vivent le
        /// fuseau horaire et la version du client.
        public static let extended = Flags(rawValue: 0x8000_0000)
    }

    /// Ce que wisq annonce par défaut : la souris, l'Unicode, la fenêtre
    /// maximisée, la notification d'ouverture de session, et la touche Windows.
    /// **Pas la compression** — elle demande un décompresseur que cette tranche
    /// n'a pas, et l'annoncer ferait envoyer au serveur des paquets qu'on ne
    /// saurait pas lire.
    public static let defaultFlags: Flags = [
        .mouse, .unicode, .maximiseShell, .logonNotify, .enableWindowsKey, .disableCtrlAltDelete,
    ]

    /// Une chaîne UTF-16 petit-boutiste avec son nul final, telle que le champ
    /// la veut — et sa longueur **sans** le nul, telle que l'en-tête la compte.
    /// Les deux conventions dans un même paquet : c'est l'erreur qui décale
    /// tout ce qui suit.
    static func field(_ text: String) -> (bytes: Data, declaredLength: Int) {
        var out = Data()
        for unit in Array(text.utf16) {
            out.append(UInt8(unit & 0xFF)); out.append(UInt8(unit >> 8))
        }
        let declared = out.count
        out.append(contentsOf: [0, 0])
        return (out, declared)
    }

    /// Combien de caractères chaque champ accepte, d'après MS-RDPBCGR 2.2.1.11.
    /// Ce sont des bornes du protocole, pas des précautions : un serveur refuse
    /// au-delà.
    static let domainLimit = 52
    static let userLimit = 512
    static let passwordLimit = 512
    static let shellLimit = 512
    static let directoryLimit = 512

    /// Le paquet, prêt à chiffrer.
    public static func packet(domain: String = "", user: String,
                              password: String, shell: String = "", directory: String = "",
                              flags: Flags = defaultFlags) -> Data {
        let domainField = field(String(domain.prefix(domainLimit)))
        let userField = field(String(user.prefix(userLimit)))
        let passwordField = field(String(password.prefix(passwordLimit)))
        let shellField = field(String(shell.prefix(shellLimit)))
        let directoryField = field(String(directory.prefix(directoryLimit)))

        var out = Data()
        out += RDPStandardSecurity.le32(0)                    // codePage
        out += RDPStandardSecurity.le32(flags.rawValue)
        out += RDPStandardSecurity.le16(UInt16(domainField.declaredLength))
        out += RDPStandardSecurity.le16(UInt16(userField.declaredLength))
        out += RDPStandardSecurity.le16(UInt16(passwordField.declaredLength))
        out += RDPStandardSecurity.le16(UInt16(shellField.declaredLength))
        out += RDPStandardSecurity.le16(UInt16(directoryField.declaredLength))
        out += domainField.bytes + userField.bytes + passwordField.bytes
        out += shellField.bytes + directoryField.bytes
        out += extended()
        return out
    }

    /// **La partie étendue n'est pas facultative dès qu'on annonce RDP 5.**
    ///
    /// Mesuré : sans elle, xrdp répond
    /// « Parsing TS_EXTENDED_INFO_PACKET clientAddressFamily and
    /// cbClientAddress — Not enough bytes in the stream » et raccroche. Le
    /// bloc central de la connexion — `CS_CORE` — dit `0x0008000C`, donc le
    /// serveur lit la suite ; ne pas l'écrire est une contradiction entre deux
    /// paquets, pas un champ oublié.
    static func extended() -> Data {
        var out = Data()
        out += RDPStandardSecurity.le16(0x0002)      // AF_INET
        // L'adresse et le répertoire du client. wisq n'en dit rien de vrai :
        // ce sont des indices que le serveur journalise, et une adresse
        // inventée serait un mensonge sans usage. Un champ vide est deux
        // octets de nul, et sa longueur les compte.
        out += RDPStandardSecurity.le16(2) + Data([0, 0])
        out += RDPStandardSecurity.le16(2) + Data([0, 0])
        // Le fuseau horaire : cent soixante-douze octets dont le serveur se
        // sert pour l'horloge de la session. Zéro veut dire UTC sans heure
        // d'été, ce qui est faux pour presque tout le monde — mais deviner le
        // fuseau du téléphone appartient à la couche qui le connaît, et
        // l'inventer ici serait pire.
        out += Data(repeating: 0, count: 172)
        out += RDPStandardSecurity.le32(0)           // clientSessionId
        out += RDPStandardSecurity.le32(performanceFlags)
        out += RDPStandardSecurity.le16(0)           // pas de témoin de reconnexion
        return out
    }

    /// Ce qu'on demande au serveur de ne pas dessiner.
    ///
    /// **Ce sont des économies de réseau, pas des préférences.** Un fond
    /// d'écran retransmis à chaque changement de fenêtre, une fenêtre entière
    /// redessinée pendant qu'on la déplace, des menus animés image par image :
    /// sur un téléphone en 4G, chacun coûte plus que ce qu'il donne. Le thème
    /// et l'ombre du curseur restent, parce qu'ils ne coûtent qu'une fois.
    public static let performanceFlags: UInt32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004
}
