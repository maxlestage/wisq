import Foundation

/// Ce qu'un clavier d'écran demande à une machine : taper un texte, frapper
/// une touche avec ses modificateurs. `X86Machine` le fait ; les tests en
/// font un faux, en millisecondes.
public protocol ScreenKeyboard: AnyObject {
    /// Un texte, caractère par caractère, jusqu'au premier qui ne tient plus.
    func type(_ text: Substring) -> X86TypingReport
    /// Des frappes qui vont ensemble, toutes ou aucune.
    func press(_ events: [X86Keystrokes.Event]) -> Bool
    /// Les frappes que la machine n'a pas encore jouées.
    var pendingKeystrokes: Int { get }
    /// Jeter ce qui n'a pas encore été joué, sans laisser de touche enfoncée.
    func abandonTyping()
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
///
/// **Et la frappe s'annule** (`cancel`). Ce qui attend passe avant ce qu'on
/// tape ensuite, Ctrl-C compris : un gros fichier collé par erreur, à
/// cinquante millisecondes la touche, tiendrait le clavier des heures. Annuler
/// jette ce qui attend ici **et** ce que la machine n'a pas encore joué, et
/// relâche les touches que l'invité tient (`X86Machine.abandonTyping`).
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
    /// Les frappes que la machine n'avait pas encore jouées à la dernière
    /// action (ou au dernier battement, `resume`).
    public private(set) var queued = 0
    /// La frappe vient d'être annulée, et ce qui attendait encore ici.
    public private(set) var cancelled = false
    public private(set) var abandoned = 0

    /// À partir de combien de frappes encore à jouer la frappe se dit « en
    /// cours » et s'annule : deux cents, cinq secondes au rythme d'une main
    /// (deux frappes toutes les cinquante millisecondes). En dessous, l'avis
    /// clignoterait à chaque touche tapée, pour une attente qu'on ne voit pas.
    public static let busyStrokes = 200

    /// **Une frappe qu'on peut annuler est en cours** : du texte attend ici,
    /// ou la machine a encore des secondes de frappe à jouer.
    public var inProgress: Bool { waitingCount > 0 || queued >= Self.busyStrokes }

    public init() {}

    /// Un texte tapé ou collé sur l'écran : derrière ce qui attend encore.
    public mutating func type(_ text: String, on keyboard: some ScreenKeyboard) {
        begin()
        guard !text.isEmpty else { return }
        var kept = text.prefix(Self.limit - waitingCount)
        if kept.endIndex != text.endIndex {
            // Le texte ne tient pas entier : ce qui en est gardé est **copié**.
            // Une sous-chaîne garde vivant tout le tampon de la chaîne d'où
            // elle vient, la partie refusée comprise, jusqu'à ce qu'elle soit
            // tapée — des heures, et tout le presse-papiers sur le téléphone.
            // Compter le reste parcourt le texte une fois (0,2 s pour 100 Mo
            // mesurés ici), et seulement quand il est trop long.
            refused += text[kept.endIndex...].count
            kept = Substring(String(kept))
        }
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
        defer { queued = keyboard.pendingKeystrokes }
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

    /// **Annuler la frappe en cours** : ce qui attend ici, et ce que la
    /// machine n'a pas encore joué. L'avis dit ce qui n'a pas été tapé, et
    /// s'efface à l'action suivante, qui part aussitôt.
    public mutating func cancel(on keyboard: some ScreenKeyboard) {
        let left = waitingCount
        self = ScreenTypist()
        keyboard.abandonTyping()
        cancelled = true
        abandoned = left
        queued = keyboard.pendingKeystrokes
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
        cancelled = false
        abandoned = 0
    }

    /// **La phrase sous l'écran**, ou `nil` s'il n'y a rien à dire.
    public var note: String? {
        var parts: [String] = []
        if waitingCount > 0 {
            parts.append("Frappe en cours : encore \(Self.characters(waitingCount)) à taper sur l'écran.")
        } else if inProgress {
            parts.append("Frappe en cours sur l'écran.")
        }
        if cancelled {
            parts.append(abandoned > 0
                         ? "Frappe annulée : \(Self.characters(abandoned)) \(Self.verb(abandoned))."
                         : "Frappe annulée.")
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
