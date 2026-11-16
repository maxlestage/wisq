import Foundation

/// **Les touches qu'une file de frappes laisse enfoncées**, un bit par
/// touche : un code du jeu 1 sur un octet, avec ou sans `E0`.
///
/// C'est l'état de l'invité une fois la file jouée jusqu'au bout. Il sert la
/// seconde règle de la borne : le relâchement d'une touche que la file laisse
/// enfoncée passe toujours (`X86PS2Controller.typingLimit`).
public struct X86HeldKeys: Sendable, Equatable {
    /// Le nombre de touches distinctes, donc le dépassement de la borne au
    /// plus : un relâchement par touche.
    public static let count = 512

    private var words = [UInt64](repeating: 0, count: count / 64)

    public init() {}

    public func contains(_ code: X86ScanCode) -> Bool {
        let (word, bit) = Self.rank(code)
        return words[word] & bit != 0
    }

    /// Aucune touche enfoncée : la file, jouée jusqu'au bout, rend un
    /// clavier au repos.
    public var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    /// Les touches enfoncées, dans l'ordre des codes : de quoi les relâcher
    /// toutes (`X86PS2Controller.abandonTyping`).
    public var codes: [X86ScanCode] {
        var codes: [X86ScanCode] = []
        for index in 0..<Self.count where words[index / 64] & (1 << UInt64(index % 64)) != 0 {
            codes.append(X86ScanCode(UInt8(index & 0xFF), extended: index >= 256))
        }
        return codes
    }

    public mutating func record(_ keystroke: X86PS2Controller.Keystroke) {
        let (word, bit) = Self.rank(keystroke.code)
        if keystroke.down { words[word] |= bit } else { words[word] &= ~bit }
    }

    private static func rank(_ code: X86ScanCode) -> (Int, UInt64) {
        let index = Int(code.set1) | (code.extended ? 256 : 0)
        return (index / 64, 1 << UInt64(index % 64))
    }
}

/// **Ce qu'un texte tapé sur l'écran est devenu** : ce qui est entré dans la
/// file du clavier, ce qu'un clavier QWERTY n'a pas, et ce qui n'a pas tenu.
public struct X86TypingReport: Sendable, Equatable {
    /// Les caractères entrés dans la file, entiers.
    public var typed = 0
    /// Les caractères laissés de côté avant la coupure : `é`, une émoji, un
    /// guillemet typographique — rien sur un clavier américain.
    public var skipped = 0
    /// **Ce qui reste à taper**, à partir du premier caractère qui n'a pas
    /// tenu : vide quand tout est entré. C'est ce que l'application garde
    /// pour le reprendre quand la file se sera vidée (`ScreenTypist`).
    public var untyped: Substring = ""

    public init(typed: Int = 0, skipped: Int = 0, untyped: Substring = "") {
        self.typed = typed
        self.skipped = skipped
        self.untyped = untyped
    }
}

/// **La file des frappes d'`X86Machine`, entre le fil de l'application et
/// celui de l'émulation.**
///
/// L'application tape d'un fil, le contrôleur PS/2 vit sur l'autre : les
/// frappes attendent ici, sous le verrou de la machine, que la tranche
/// suivante les passe au contrôleur (`feed`). Cette file n'avait pas de borne
/// et versait ses frappes une à une dans celle du contrôleur, qui coupait au
/// milieu d'un caractère. Elle a maintenant **la même borne que celle du
/// contrôleur, comptée avec elle** : ce qu'elle admet entre entier dans le
/// contrôleur à la tranche suivante, et c'est ici que l'application apprend,
/// sur-le-champ, ce qui n'a pas tenu.
struct X86TypingHandoff: Sendable {
    typealias Keystroke = X86PS2Controller.Keystroke

    /// Les frappes en attente, à plat, et la taille de chaque groupe.
    private(set) var strokes: [Keystroke] = []
    private(set) var groupSizes: [Int] = []
    /// Les touches que la file **du contrôleur et celle-ci** laissent
    /// enfoncées, jouées jusqu'au bout : tout ce qui est admis passe par ici,
    /// dans l'ordre.
    private(set) var held = X86HeldKeys()

    var count: Int { strokes.count }

    /// Admet un groupe de frappes entier ou pas du tout. `inDevice` : ce que
    /// la file du contrôleur tenait à la dernière tranche — au plus, puisque
    /// le contrôleur ne fait que la vider entre deux tranches.
    ///
    /// Un groupe d'une seule frappe qui relâche une touche tenue passe
    /// toujours, comme dans le contrôleur.
    mutating func admit(_ group: [Keystroke], inDevice: Int) -> Bool {
        guard !group.isEmpty else { return true }
        if inDevice + strokes.count + group.count > X86PS2Controller.typingLimit {
            guard group.count == 1, !group[0].down, held.contains(group[0].code) else { return false }
        }
        for keystroke in group { held.record(keystroke) }
        strokes += group
        groupSizes.append(group.count)
        return true
    }

    /// **Passe au contrôleur tout ce qu'il prend, groupe par groupe, dans
    /// l'ordre**, et s'arrête au premier qu'il refuse : celui-là attend la
    /// tranche suivante, entier. Rien n'est jeté. Par construction
    /// (`admit`), le contrôleur prend tout.
    mutating func feed(into ps2: inout X86PS2Controller) {
        var start = 0
        var groups = 0
        for size in groupSizes {
            let taken: Bool
            if size == 1 {
                taken = ps2.type(strokes[start].code, down: strokes[start].down)
            } else {
                taken = ps2.type(Array(strokes[start..<start + size]))
            }
            guard taken else { break }
            start += size
            groups += 1
        }
        strokes.removeFirst(start)
        groupSizes.removeFirst(groups)
    }
}
