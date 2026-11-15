import Foundation

/// Ce qu'un clavier d'écran demande à une machine : taper un texte, frapper
/// une touche avec ses modificateurs. `X86Machine` le fait ; les tests en
/// font un faux, en millisecondes.
public protocol ScreenKeyboard: AnyObject {
    /// Un texte, caractère par caractère, jusqu'au premier qui ne tient plus.
    func type(_ text: Substring) -> X86TypingReport
    /// Des frappes qui vont ensemble, toutes ou aucune.
    func press(_ events: [X86Keystrokes.Event]) -> Bool
}

extension X86Machine: ScreenKeyboard {}

/// **Ce qui reste à taper sur l'écran d'une machine PC**, gardé par
/// l'application quand la file du clavier est pleine, et repris quand elle
/// se vide.
///
/// **Pourquoi.** La file du clavier PS/2 est bornée (8 192 frappes, à peu
/// près deux mille caractères), et elle se vide au rythme d'une main : un
/// collage plus long ne tient pas d'un coup. Avant, la file coupait au
/// milieu d'un caractère, laissait Maj et la lettre enfoncées, et jetait la
/// suite sans rien dire. Elle s'arrête maintenant au premier caractère qui ne
/// tient plus (`X86Machine.type`), et ce qui n'a pas tenu attend ici, dans
/// l'ordre : un texte tapé ou une touche de la barre frappée entre-temps
/// passe **derrière**, jamais devant. L'application appelle `resume` à
/// chaque battement de sa ligne d'état.
///
/// Ce qui est gardé est borné aussi (`limit`) ; au-delà, c'est **dit**
/// (`note`), comme ce qu'un clavier américain n'a pas.
public struct ScreenTypist: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        case text(Substring)
        case keys([X86PS2Controller.Keystroke])
    }

    /// Les caractères gardés au plus, une touche de la barre comptant pour
    /// un : un mébioctet de texte, des heures de frappe au rythme d'une main.
    public static let limit = 1 << 20

    /// Ce qui attend, dans l'ordre où la personne l'a tapé.
    public private(set) var waiting: [Item] = []
    /// Combien de caractères (et de touches) attendent.
    public private(set) var waitingCount = 0
    /// Les caractères qu'un clavier américain n'a pas, laissés de côté.
    public private(set) var skipped = 0
    /// Les caractères refusés parce que ce qui attend était déjà à la borne.
    public private(set) var refused = 0

    public init() {}

    /// Un texte tapé ou collé sur l'écran : derrière ce qui attend encore.
    public mutating func type(_ text: String, on keyboard: some ScreenKeyboard) {
        begin()
        let room = Self.limit - waitingCount
        let count = text.count
        guard count > 0 else { return }
        let kept = text.prefix(room)
        refused += count - kept.count
        if !kept.isEmpty {
            waiting.append(.text(kept))
            waitingCount += kept.count
        }
        resume(on: keyboard)
    }

    /// Une touche de la barre, avec ses modificateurs : derrière ce qui
    /// attend encore, elle aussi.
    public mutating func press(_ events: [X86Keystrokes.Event], on keyboard: some ScreenKeyboard) {
        begin()
        guard !events.isEmpty else { return }
        guard waitingCount < Self.limit else {
            refused += 1
            return
        }
        waiting.append(.keys(X86Keystrokes.keystrokes(events)))
        waitingCount += 1
        resume(on: keyboard)
    }

    /// **Reprendre ce qui attend**, autant que la file en prend, dans
    /// l'ordre, et s'arrêter au premier morceau qui ne tient plus.
    public mutating func resume(on keyboard: some ScreenKeyboard) {
        while let first = waiting.first {
            switch first {
            case .text(let text):
                let report = keyboard.type(text)
                skipped += report.skipped
                waitingCount -= report.typed + report.skipped
                guard report.untyped.isEmpty else {
                    waiting[0] = .text(report.untyped)
                    return
                }
            case .keys(let strokes):
                guard keyboard.press(strokes.map { ($0.code, $0.down) }) else { return }
                waitingCount -= 1
            }
            waiting.removeFirst()
        }
    }

    /// Tout oublier : la machine n'est plus là, ou c'en est une autre.
    public mutating func reset() {
        self = ScreenTypist()
    }

    /// Une nouvelle action de la personne : les avis de la précédente
    /// s'effacent, sauf si elle est encore en train de s'écrire.
    private mutating func begin() {
        guard waiting.isEmpty else { return }
        skipped = 0
        refused = 0
    }

    /// **La phrase sous l'écran**, ou `nil` s'il n'y a rien à dire.
    public var note: String? {
        var parts: [String] = []
        if waitingCount > 0 {
            parts.append("Frappe en cours : encore \(Self.characters(waitingCount)) à taper sur l'écran.")
        }
        if refused > 0 {
            parts.append("\(Self.characters(refused)) \(Self.verb(refused)) : le texte est trop long "
                         + "pour le clavier de l'écran ; la console le prend d'un coup.")
        }
        if skipped > 0 {
            parts.append("\(Self.characters(skipped)) \(Self.verb(skipped)) : un clavier américain "
                         + (skipped == 1 ? "ne l'a pas" : "ne les a pas")
                         + " (lettres accentuées, émojis, guillemets typographiques).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func characters(_ count: Int) -> String {
        count == 1 ? "1 caractère" : "\(count) caractères"
    }

    private static func verb(_ count: Int) -> String {
        count == 1 ? "n'a pas été tapé" : "n'ont pas été tapés"
    }
}
