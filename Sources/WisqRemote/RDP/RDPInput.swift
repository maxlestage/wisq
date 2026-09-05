import Foundation
import WisqCore

/// Ce que le client envoie : les touches, la souris, et les deux demandes qui
/// pilotent ce que le serveur peint.
///
/// **Un événement mal formé ne donne pas d'erreur.** Le serveur lit le nombre
/// annoncé, prend douze octets par événement, et si le compte ne tombe pas
/// juste il interprète les octets suivants comme un autre événement — une
/// touche devient un clic quelque part sur l'écran. C'est pour cela que le
/// compte et la taille sont écrits au même endroit ici.
public enum RDPInput {
    /// Le type d'un événement, tel que ses deux octets le portent.
    public enum Kind: UInt16, Sendable {
        case synchronise = 0x0000
        case scancode = 0x0004
        case unicode = 0x0005
        case mouse = 0x8001
        case extendedMouse = 0x8002
    }

    /// Les drapeaux d'une touche.
    public struct Key: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        /// Le préfixe `E0` des touches ajoutées au clavier d'origine : flèches,
        /// pavé numérique, Ctrl et Alt de droite.
        public static let extended = Key(rawValue: 0x0100)
        /// Une répétition, pas un premier appui.
        public static let repeated = Key(rawValue: 0x4000)
        /// Le relâchement. **Son absence est l'appui** : il n'y a pas de
        /// drapeau « enfoncé », et en inventer un ferait rester la touche
        /// collée côté serveur.
        public static let release = Key(rawValue: 0x8000)
    }

    /// Les drapeaux de la souris.
    public struct Pointer: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let move = Pointer(rawValue: 0x0800)
        public static let down = Pointer(rawValue: 0x8000)
        public static let left = Pointer(rawValue: 0x1000)
        public static let right = Pointer(rawValue: 0x2000)
        public static let middle = Pointer(rawValue: 0x4000)
        public static let wheel = Pointer(rawValue: 0x0200)
        public static let horizontalWheel = Pointer(rawValue: 0x0400)
        /// **La molette porte sa quantité dans les neuf bits bas**, en
        /// complément à deux sur ces neuf bits seulement. Un défilement vers
        /// l'arrière n'est donc pas un nombre négatif ordinaire.
        public static let wheelNegative = Pointer(rawValue: 0x0100)
        static let rotationMask: UInt16 = 0x01FF
    }

    /// Les verrous du clavier, tels que la synchronisation les annonce.
    public struct Toggles: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let scrollLock = Toggles(rawValue: 0x0000_0001)
        public static let numLock = Toggles(rawValue: 0x0000_0002)
        public static let capsLock = Toggles(rawValue: 0x0000_0004)
        public static let kanaLock = Toggles(rawValue: 0x0000_0008)
    }

    /// Un événement, avant emballage.
    public enum Event: Equatable, Sendable {
        case synchronise(Toggles)
        case key(UInt16, Key)
        case character(UInt16, Key)
        case pointer(Pointer, Int, Int)
        case extendedPointer(Pointer, Int, Int)
    }

    /// Combien d'événements tiennent dans un seul PDU.
    ///
    /// Le champ en compte seize bits, mais chaque événement pèse douze octets
    /// et un PDU de partage doit rester lisible d'un coup. Le plafond est celui
    /// qu'un doigt sur un écran peut produire entre deux envois, avec de la
    /// marge — et il vaut mieux refuser que d'écrire une longueur qui déborde
    /// des seize bits de l'en-tête de partage.
    public static let eventLimit = 1024

    static func le16(_ value: UInt16) -> Data { RDPStandardSecurity.le16(value) }
    static func le32(_ value: UInt32) -> Data { RDPStandardSecurity.le32(value) }

    /// **Les coordonnées sont bornées plutôt que repliées.** Un x négatif ou
    /// au-delà de l'écran deviendrait, sur seize bits non signés, un point à
    /// l'autre bout — et le clic partirait là-bas.
    static func coordinate(_ value: Int) -> UInt16 {
        UInt16(min(max(value, 0), Int(UInt16.max)))
    }

    static func slot(_ kind: Kind, _ payload: Data) -> Data {
        // Le temps de l'événement : zéro veut dire « maintenant », et c'est ce
        // que les clients de référence écrivent. Y mettre une horloge ferait
        // rejeter les événements d'un client dont la montre avance.
        le32(0) + le16(kind.rawValue) + payload
    }

    /// Un événement, en douze octets.
    public static func encode(_ event: Event) -> Data {
        switch event {
        case .synchronise(let toggles):
            return slot(.synchronise, le16(0) + le32(toggles.rawValue))
        case .key(let code, let flags):
            return slot(.scancode, le16(flags.rawValue) + le16(code) + le16(0))
        case .character(let code, let flags):
            return slot(.unicode, le16(flags.rawValue) + le16(code) + le16(0))
        case .pointer(let flags, let x, let y):
            return slot(.mouse, le16(flags.rawValue) + le16(coordinate(x)) + le16(coordinate(y)))
        case .extendedPointer(let flags, let x, let y):
            return slot(.extendedMouse, le16(flags.rawValue)
                + le16(coordinate(x)) + le16(coordinate(y)))
        }
    }

    /// Le PDU d'entrées, prêt à emballer.
    public static func events(_ events: [Event], share: UInt32, source: UInt16) throws -> Data {
        guard !events.isEmpty else {
            throw WisqError.malformedMessage("un PDU d'entrées sans événement")
        }
        guard events.count <= eventLimit else {
            throw WisqError.malformedMessage("\(events.count) événements dans un seul PDU")
        }
        var body = le16(UInt16(events.count)) + le16(0)
        for event in events { body += encode(event) }
        return RDPShare.data(.input, share: share, source: source, body)
    }

    /// Une molette : la quantité tient dans les neuf bits bas, signe compris.
    public static func wheel(_ steps: Int, at point: (x: Int, y: Int),
                             horizontal: Bool = false) -> Event {
        var flags: Pointer = horizontal ? .horizontalWheel : .wheel
        let magnitude = UInt16(min(abs(steps) * 120, 255))
        if steps < 0 {
            // Complément à deux sur neuf bits, et non sur seize : les bits
            // hauts appartiennent aux drapeaux.
            //
            // **`wheelNegative` n'est pas posé à part**, et ce n'est pas un
            // oubli : ce drapeau *est* le bit de signe du champ de neuf bits,
            // et le complément à deux le pose déjà. L'ajouter explicitement
            // était une ligne qu'aucun test ne pouvait distinguer d'un vide —
            // un sabotage l'a montrée inerte.
            flags = Pointer(rawValue: flags.rawValue
                | ((~magnitude &+ 1) & Pointer.rotationMask))
        } else {
            flags = Pointer(rawValue: flags.rawValue | (magnitude & Pointer.rotationMask))
        }
        return .pointer(flags, point.x, point.y)
    }

    // MARK: - Les deux demandes

    /// Combien de rectangles une demande de rafraîchissement peut porter. Le
    /// champ n'en compte que huit bits, et l'écrire sans borne tronquerait le
    /// nombre en laissant les rectangles derrière.
    public static let areaLimit = 255

    /// **Demander au serveur de repeindre une zone.** C'est ce qu'on envoie
    /// quand la vue revient au premier plan : sans cela, le serveur ne renvoie
    /// que ce qui change, et ce qui n'a pas changé reste vide.
    public static func refreshRect(_ areas: [(left: Int, top: Int, right: Int, bottom: Int)],
                                   share: UInt32, source: UInt16) throws -> Data {
        guard !areas.isEmpty, areas.count <= areaLimit else {
            throw WisqError.malformedMessage("\(areas.count) zones à rafraîchir")
        }
        var body = Data([UInt8(areas.count), 0, 0, 0])
        for area in areas {
            body += le16(coordinate(area.left)) + le16(coordinate(area.top))
            body += le16(coordinate(area.right)) + le16(coordinate(area.bottom))
        }
        return RDPShare.data(.refreshRect, share: share, source: source, body)
    }

    /// **Dire au serveur d'arrêter de peindre**, ou de reprendre. Un téléphone
    /// dont l'écran s'éteint continue sinon de recevoir des images qu'il ne
    /// montre pas, ce qui se paie en batterie et en données.
    public static func suppressOutput(_ painting: Bool, width: Int, height: Int,
                                      share: UInt32, source: UInt16) -> Data {
        var body = Data([painting ? 1 : 0, 0, 0, 0])
        if painting {
            // Le rectangle n'est présent que quand on redemande des images ;
            // l'ajouter dans l'autre cas fait lire au serveur quatre nombres
            // qui n'ont pas de sens.
            body += le16(0) + le16(0)
            body += le16(coordinate(max(width - 1, 0))) + le16(coordinate(max(height - 1, 0)))
        }
        return RDPShare.data(.suppressOutput, share: share, source: source, body)
    }
}
