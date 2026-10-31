import Foundation

/// **Le contrôleur de clavier du PC, un i8042, et ses deux appareils** : le
/// clavier sur la ligne 1, la souris PS/2 sur la ligne 12.
///
/// **Pourquoi lui.** Un bureau Linux veut un clavier et un pointeur, et le
/// noyau d'une distribution les cherche d'abord ici — `i8042`, `atkbd`,
/// `psmouse` sont compilés dedans ou chargés tôt. Sans ces deux ports, le
/// noyau disait « i8042: Can't read CTR while initializing i8042 » et
/// renonçait : l'invité n'avait que la console série. Virtio-input aurait
/// demandé un deuxième périphérique PCI et ses files, pour le même résultat.
///
/// **Ce qui est tenu** : le registre de configuration (CTR), les commandes du
/// contrôleur que Linux envoie — lecture et écriture du CTR, tests, activation
/// et désactivation des deux ports, bouclage de la souris (`D3`), envoi à la
/// souris (`D4`) — et celles des deux appareils : remise à zéro,
/// identification, activation, réglages qui se contentent d'un accusé.
///
/// **Les codes de touche** sont ceux du jeu 1, quand le contrôleur traduit
/// (bit 6 du CTR, ce que Linux laisse), et du jeu 2 sinon. La souris parle
/// en paquets de trois octets : boutons et signes, puis X, puis Y, Y vers le
/// haut.
public struct X86PS2Controller: Sendable, Equatable {
    public static let dataPort: UInt16 = 0x60
    public static let commandPort: UInt16 = 0x64
    public static let keyboardLine: UInt8 = 1
    public static let mouseLine: UInt8 = 12

    /// Les bits du CTR.
    static let keyboardInterrupt: UInt8 = 0x01
    static let mouseInterrupt: UInt8 = 0x02
    static let systemFlag: UInt8 = 0x04
    static let keyboardDisabled: UInt8 = 0x10
    static let mouseDisabled: UInt8 = 0x20
    static let translate: UInt8 = 0x40

    /// Ce qu'un BIOS laisse : les deux interruptions, le drapeau système, la
    /// traduction, la souris éteinte jusqu'à ce que le noyau l'allume.
    public var configuration: UInt8 = 0x47 | 0x20

    /// Ce qui attend d'être lu au port 0x60, et de quel appareil. Le premier
    /// octet décide de l'état et de la ligne.
    public var output: [Output] = []

    public struct Output: Sendable, Equatable {
        public var byte: UInt8
        public var fromMouse: Bool
    }

    /// La commande du contrôleur qui attend son octet au port 0x60.
    public var pendingCommand: UInt8?
    /// La commande d'un appareil qui attend son paramètre.
    public var keyboardParameterFor: UInt8?
    public var mouseParameterFor: UInt8?
    /// Le dernier octet écrit l'a été au port de commande : bit 3 de l'état.
    public var lastWriteWasCommand = false

    /// La souris envoie-t-elle ses mouvements (`F4`) ?
    public var mouseReporting = false
    /// Le clavier envoie-t-il ses touches ? Allumé au départ, comme un vrai.
    public var keyboardScanning = true

    /// **La ligne de remise à zéro du processeur**, que le 8042 tient sur le
    /// bit zéro de son port de sortie. Linux la tire pour redémarrer, juste
    /// après ACPI qu'il n'y a pas : `outb(0xfe, 0x64)`, une impulsion sur ce
    /// bit. Sans elle, le noyau passait à la méthode suivante, un saut long
    /// vers le code en mode réel du BIOS (`machine_real_restart`), et la
    /// machine s'arrêtait sur « le groupe 5 /5 » — le saut que ce cœur
    /// n'exécute pas. `X86Machine` la lit après chaque tranche, et rend
    /// `.reboot`.
    public var resetRequested = false

    public init() {}

    // MARK: - Les ports

    /// L'état (0x64) : sortie pleine, système, commande, clavier non
    /// verrouillé, et sortie souris. Le bit 4 à zéro dit « clavier
    /// verrouillé » : Linux l'a vu et l'a écrit, « i8042: Warning: Keylock
    /// active ».
    public func status() -> UInt8 {
        var value: UInt8 = 0x04 | 0x10
        if let first = output.first {
            value |= 0x01
            if first.fromMouse { value |= 0x20 }
        }
        if lastWriteWasCommand { value |= 0x08 }
        return value
    }

    public mutating func readData() -> UInt8 {
        guard !output.isEmpty else { return 0 }
        return output.removeFirst().byte
    }

    public mutating func writeCommand(_ command: UInt8) {
        lastWriteWasCommand = true
        pendingCommand = nil
        switch command {
        case 0x20: reply(configuration)
        case 0x60, 0xD1, 0xD2, 0xD3, 0xD4: pendingCommand = command
        case 0xA7: configuration |= Self.mouseDisabled
        case 0xA8: configuration &= ~Self.mouseDisabled
        case 0xA9, 0xAB: reply(0x00)  // les deux ports se testent bien
        case 0xAA: reply(0x55)  // le contrôleur se teste bien
        case 0xAD: configuration |= Self.keyboardDisabled
        case 0xAE: configuration &= ~Self.keyboardDisabled
        case 0xD0: reply(0x01)  // le port de sortie : la ligne de remise à zéro au repos
        // Une impulsion sur les lignes du port de sortie dont le bit est à
        // zéro : le bit zéro, c'est la remise à zéro.
        case 0xF0...0xFF where command & 0x01 == 0: resetRequested = true
        default: break
        }
    }

    public mutating func writeData(_ byte: UInt8) {
        lastWriteWasCommand = false
        if let command = pendingCommand {
            pendingCommand = nil
            switch command {
            case 0x60: configuration = byte
            // Le port de sortie écrit d'un coup : le bit zéro à zéro tire
            // la même ligne.
            case 0xD1 where byte & 0x01 == 0: resetRequested = true
            case 0xD2: reply(byte)
            // Le bouclage : Linux s'en sert pour savoir s'il y a un port de
            // souris, en lisant l'octet revenu « de la souris ».
            case 0xD3: reply(byte, fromMouse: true)
            case 0xD4: mouseCommand(byte)
            default: break
            }
            return
        }
        keyboardCommand(byte)
    }

    // MARK: - Les appareils

    mutating func keyboardCommand(_ byte: UInt8) {
        if let command = keyboardParameterFor {
            keyboardParameterFor = nil
            reply(0xFA)
            // `F0 00` demande le jeu en cours : le 2, que le contrôleur traduit.
            if command == 0xF0 && byte == 0 { reply(translating ? 0x41 : 0x02) }
            return
        }
        switch byte {
        case 0xFF:
            keyboardScanning = true
            reply(0xFA)
            reply(0xAA)
        case 0xF2:
            // L'identification d'un clavier MF2 : AB 83, que le contrôleur
            // traduit en AB 41.
            reply(0xFA)
            reply(0xAB)
            reply(translating ? 0x41 : 0x83)
        case 0xF4: keyboardScanning = true; reply(0xFA)
        case 0xF5: keyboardScanning = false; reply(0xFA)
        case 0xF6: keyboardScanning = true; reply(0xFA)
        case 0xED, 0xF3, 0xF0: keyboardParameterFor = byte; reply(0xFA)
        case 0xEE: reply(0xEE)
        default: reply(0xFA)
        }
    }

    mutating func mouseCommand(_ byte: UInt8) {
        if mouseParameterFor != nil {
            mouseParameterFor = nil
            reply(0xFA, fromMouse: true)
            return
        }
        switch byte {
        case 0xFF:
            mouseReporting = false
            reply(0xFA, fromMouse: true)
            reply(0xAA, fromMouse: true)
            reply(0x00, fromMouse: true)
        case 0xF2:
            // Une souris standard, sans molette : identifiant zéro.
            reply(0xFA, fromMouse: true)
            reply(0x00, fromMouse: true)
        case 0xF4: mouseReporting = true; reply(0xFA, fromMouse: true)
        case 0xF5: mouseReporting = false; reply(0xFA, fromMouse: true)
        case 0xF6: mouseReporting = false; reply(0xFA, fromMouse: true)
        case 0xF3, 0xE8: mouseParameterFor = byte; reply(0xFA, fromMouse: true)
        case 0xE9:
            // L'état : flux, désactivée ou non, quatre comptes par
            // millimètre, cent paquets par seconde.
            reply(0xFA, fromMouse: true)
            reply(mouseReporting ? 0x20 : 0x00, fromMouse: true)
            reply(0x02, fromMouse: true)
            reply(100, fromMouse: true)
        case 0xEB:
            reply(0xFA, fromMouse: true)
            for byte in Self.packet(dx: 0, dy: 0, buttons: 0) { reply(byte, fromMouse: true) }
        default: reply(0xFA, fromMouse: true)
        }
    }

    mutating func reply(_ byte: UInt8, fromMouse: Bool = false) {
        output.append(Output(byte: byte, fromMouse: fromMouse))
    }

    var translating: Bool { configuration & Self.translate != 0 }

    // MARK: - Ce que l'hôte envoie

    /// Une touche, en codes du jeu 1 — `E0` compris pour les touches
    /// étendues —, enfoncée ou relâchée. Traduite en jeu 2 quand le noyau a
    /// coupé la traduction.
    public mutating func key(_ code: X86ScanCode, down: Bool) {
        guard keyboardScanning, configuration & Self.keyboardDisabled == 0 else { return }
        if translating {
            if code.extended { reply(0xE0) }
            reply(down ? code.set1 : code.set1 | 0x80)
        } else {
            guard let set2 = X86ScanCode.set2[code.set1] else { return }
            if code.extended { reply(0xE0) }
            if !down { reply(0xF0) }
            reply(set2)
        }
    }

    /// Un mouvement de souris, en comptes, Y vers le **bas** comme à l'écran ;
    /// le paquet le retourne. Découpé en pas de ±255, ce qu'un paquet porte.
    public mutating func mouse(dx: Int, dy: Int, buttons: UInt8) {
        guard mouseReporting, configuration & Self.mouseDisabled == 0 else { return }
        var restX = dx, restY = -dy
        repeat {
            let stepX = max(-255, min(255, restX)), stepY = max(-255, min(255, restY))
            restX -= stepX
            restY -= stepY
            for byte in Self.packet(dx: stepX, dy: stepY, buttons: buttons) { reply(byte, fromMouse: true) }
        } while restX != 0 || restY != 0
    }

    static func packet(dx: Int, dy: Int, buttons: UInt8) -> [UInt8] {
        var first: UInt8 = 0x08 | (buttons & 0x07)
        if dx < 0 { first |= 0x10 }
        if dy < 0 { first |= 0x20 }
        return [first, UInt8(truncatingIfNeeded: dx), UInt8(truncatingIfNeeded: dy)]
    }

    // MARK: - Les lignes

    /// La ligne 1 : un octet du clavier attend, et le noyau veut être
    /// prévenu. À niveau, comme le port série.
    public var keyboardInterrupting: Bool {
        guard let first = output.first, !first.fromMouse else { return false }
        return configuration & Self.keyboardInterrupt != 0
    }

    /// La ligne 12 : de même, pour la souris.
    public var mouseInterrupting: Bool {
        guard let first = output.first, first.fromMouse else { return false }
        return configuration & Self.mouseInterrupt != 0
    }
}

/// **Une touche du PC**, par son code du jeu 1 et son préfixe `E0`.
public struct X86ScanCode: Sendable, Equatable, Hashable {
    public let set1: UInt8
    public let extended: Bool

    public init(_ set1: UInt8, extended: Bool = false) {
        self.set1 = set1
        self.extended = extended
    }

    public static let escape = X86ScanCode(0x01)
    public static let backspace = X86ScanCode(0x0E)
    public static let tab = X86ScanCode(0x0F)
    public static let enter = X86ScanCode(0x1C)
    public static let leftControl = X86ScanCode(0x1D)
    public static let leftShift = X86ScanCode(0x2A)
    public static let leftAlt = X86ScanCode(0x38)
    public static let space = X86ScanCode(0x39)
    public static let leftMeta = X86ScanCode(0x5B, extended: true)
    public static let up = X86ScanCode(0x48, extended: true)
    public static let down = X86ScanCode(0x50, extended: true)
    public static let left = X86ScanCode(0x4B, extended: true)
    public static let right = X86ScanCode(0x4D, extended: true)
    public static let home = X86ScanCode(0x47, extended: true)
    public static let end = X86ScanCode(0x4F, extended: true)
    public static let pageUp = X86ScanCode(0x49, extended: true)
    public static let pageDown = X86ScanCode(0x51, extended: true)
    public static let delete = X86ScanCode(0x53, extended: true)

    /// F1 à F12.
    public static func function(_ number: Int) -> X86ScanCode? {
        switch number {
        case 1...10: return X86ScanCode(UInt8(0x3A + number))
        case 11: return X86ScanCode(0x57)
        case 12: return X86ScanCode(0x58)
        default: return nil
        }
    }

    /// **Un caractère, sur un clavier américain** — la disposition qu'un
    /// invité prend par défaut : la touche, et s'il faut Maj. Rien pour ce
    /// qu'un clavier QWERTY n'a pas.
    public static func typing(_ character: Character) -> (code: X86ScanCode, shift: Bool)? {
        guard let entry = layout[character] else { return nil }
        return (X86ScanCode(entry.0), entry.1)
    }

    static let layout: [Character: (UInt8, Bool)] = {
        var table: [Character: (UInt8, Bool)] = [:]
        let rows: [(String, String, UInt8)] = [
            ("1234567890-=", "!@#$%^&*()_+", 0x02),
            ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
            ("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1E),
            ("\\zxcvbnm,./", "|ZXCVBNM<>?", 0x2B),
        ]
        for (plain, shifted, first) in rows {
            for (offset, character) in plain.enumerated() { table[character] = (first + UInt8(offset), false) }
            for (offset, character) in shifted.enumerated() { table[character] = (first + UInt8(offset), true) }
        }
        table[" "] = (0x39, false)
        table["\n"] = (0x1C, false)
        table["\r"] = (0x1C, false)
        table["\t"] = (0x0F, false)
        return table
    }()

    /// Le jeu 1 vers le jeu 2, pour les touches de base : l'inverse de la
    /// table de traduction du contrôleur (IBM PC AT, reprise par
    /// `drivers/input/keyboard/atkbd.c`).
    static let set2: [UInt8: UInt8] = {
        let fromSet2: [UInt8] = [
            0xFF, 0x43, 0x41, 0x3F, 0x3D, 0x3B, 0x3C, 0x58, 0x64, 0x44, 0x42, 0x40, 0x3E, 0x0F, 0x29, 0x59,
            0x65, 0x38, 0x2A, 0x70, 0x1D, 0x10, 0x02, 0x5A, 0x66, 0x71, 0x2C, 0x1F, 0x1E, 0x11, 0x03, 0x5B,
            0x67, 0x2E, 0x2D, 0x20, 0x12, 0x05, 0x04, 0x5C, 0x68, 0x39, 0x2F, 0x21, 0x14, 0x13, 0x06, 0x5D,
            0x69, 0x31, 0x30, 0x23, 0x22, 0x15, 0x07, 0x5E, 0x6A, 0x72, 0x32, 0x24, 0x16, 0x08, 0x09, 0x5F,
            0x6B, 0x33, 0x25, 0x17, 0x18, 0x0B, 0x0A, 0x60, 0x6C, 0x34, 0x35, 0x26, 0x27, 0x19, 0x0C, 0x61,
            0x6D, 0x73, 0x28, 0x74, 0x1A, 0x0D, 0x62, 0x6E, 0x3A, 0x36, 0x1C, 0x1B, 0x75, 0x2B, 0x63, 0x76,
            0x55, 0x56, 0x77, 0x78, 0x79, 0x7A, 0x0E, 0x7B, 0x7C, 0x4F, 0x7D, 0x4B, 0x47, 0x7E, 0x7F, 0x6F,
            0x52, 0x53, 0x50, 0x4C, 0x4D, 0x48, 0x01, 0x45, 0x57, 0x4E, 0x51, 0x4A, 0x37, 0x49, 0x46, 0x54,
        ]
        var table: [UInt8: UInt8] = [:]
        for (set2, set1) in fromSet2.enumerated() where set1 != 0xFF && table[set1] == nil {
            table[set1] = UInt8(set2)
        }
        return table
    }()
}

/// **Ce qu'on tape, en événements du clavier PS/2.**
///
/// L'application reçoit du texte — le clavier de l'iPhone — et des touches
/// de sa barre ; l'invité attend des touches enfoncées puis relâchées, Maj
/// et Ctrl compris. Ici, et pas dans la vue, pour que ça se teste.
public enum X86Keystrokes {
    public typealias Event = (code: X86ScanCode, down: Bool)

    /// Une touche frappée, avec ses modificateurs autour.
    public static func press(_ code: X86ScanCode, shift: Bool = false, control: Bool = false) -> [Event] {
        var events: [Event] = []
        if control { events.append((.leftControl, true)) }
        if shift { events.append((.leftShift, true)) }
        events += [(code, true), (code, false)]
        if shift { events.append((.leftShift, false)) }
        if control { events.append((.leftControl, false)) }
        return events
    }

    /// Un texte, caractère par caractère, sur un clavier américain. Ce qu'un
    /// clavier QWERTY n'a pas est laissé de côté.
    public static func typing(_ text: String) -> [Event] {
        text.flatMap { character -> [Event] in
            guard let key = X86ScanCode.typing(character) else { return [] }
            return press(key.code, shift: key.shift)
        }
    }

    /// Une touche de la barre de la console.
    public static func key(_ key: TerminalKey) -> [Event] {
        switch key {
        case .escape: return press(.escape)
        case .tab: return press(.tab)
        case .up: return press(.up)
        case .down: return press(.down)
        case .left: return press(.left)
        case .right: return press(.right)
        case .home: return press(.home)
        case .end: return press(.end)
        case .pageUp: return press(.pageUp)
        case .pageDown: return press(.pageDown)
        case .delete: return press(.delete)
        case .control(let letter):
            guard let key = X86ScanCode.typing(Character(letter.lowercased())) else { return [] }
            return press(key.code, control: true)
        }
    }
}
