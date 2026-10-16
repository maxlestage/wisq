import Foundation

/// Les touches qu'un shell demande et qu'un clavier de téléphone n'a pas.
///
/// **Pourquoi ce type existe.** La console locale n'offrait que « Entrée » et
/// `^C`. Sans tabulation, pas de complétion ; sans flèches, pas d'historique ;
/// sans Échap ni Ctrl, pas d'éditeur. On pouvait lancer des commandes, pas
/// travailler — et c'est précisément ce que la machine locale doit permettre.
///
/// **Ce que la touche envoie est décidé ici**, sur Linux et sous des tests,
/// pas dans la vue : une séquence d'échappement fausse d'un octet ne se voit
/// qu'à l'usage, dans un programme qui l'ignore sans un mot.
public enum TerminalKey: Hashable, Sendable {
    case escape
    case tab
    case up, down, right, left
    case home, end, pageUp, pageDown, delete
    /// Ctrl et une lettre : `^C`, `^D`, `^Z`, `^R`…
    case control(Character)

    /// La barre, dans l'ordre où on la lit : les touches d'édition d'abord,
    /// puis les flèches, puis les combinaisons qu'un shell emploie le plus.
    public static let bar: [TerminalKey] = [
        .escape, .tab, .up, .down, .left, .right,
        .control("c"), .control("d"), .control("z"), .control("r"), .control("l"),
        .control("a"), .control("e"), .control("u"), .control("w"),
        .home, .end, .pageUp, .pageDown, .delete,
    ]

    /// Ce qu'on lit sur la touche.
    public var label: String {
        switch self {
        case .escape: return "esc"
        case .tab: return "tab"
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .left: return "←"
        case .home: return "début"
        case .end: return "fin"
        case .pageUp: return "pg↑"
        case .pageDown: return "pg↓"
        case .delete: return "suppr"
        case .control(let letter): return "^" + String(letter).uppercased()
        }
    }

    /// Ce que la touche dit à un lecteur d'écran — « ^R » ne se prononce pas.
    public var spokenName: String {
        switch self {
        case .escape: return "Échap"
        case .tab: return "Tabulation"
        case .up: return "Flèche haut"
        case .down: return "Flèche bas"
        case .right: return "Flèche droite"
        case .left: return "Flèche gauche"
        case .home: return "Début de ligne"
        case .end: return "Fin de ligne"
        case .pageUp: return "Page précédente"
        case .pageDown: return "Page suivante"
        case .delete: return "Supprimer"
        case .control(let letter): return "Contrôle " + String(letter).uppercased()
        }
    }

    /// Les octets que la touche envoie à l'invité.
    ///
    /// Les séquences sont celles d'un terminal xterm, qui est ce que les
    /// distributions supposent d'une console série sans `TERM` précis. Les
    /// flèches changent de forme en mode application — voir
    /// `TerminalGrid.applicationCursorKeys` — et c'est la seule touche dont la
    /// forme dépend du programme qui écoute.
    public func bytes(applicationCursorKeys: Bool = false) -> [UInt8] {
        let escape: UInt8 = 0x1B
        let cursorIntroducer: [UInt8] = applicationCursorKeys ? [escape, 0x4F] : [escape, 0x5B]
        switch self {
        case .escape: return [escape]
        case .tab: return [0x09]
        case .up: return cursorIntroducer + [0x41]
        case .down: return cursorIntroducer + [0x42]
        case .right: return cursorIntroducer + [0x43]
        case .left: return cursorIntroducer + [0x44]
        case .home: return [escape, 0x5B, 0x48]
        case .end: return [escape, 0x5B, 0x46]
        case .pageUp: return Array("\u{1B}[5~".utf8)
        case .pageDown: return Array("\u{1B}[6~".utf8)
        case .delete: return Array("\u{1B}[3~".utf8)
        case .control(let letter):
            // Ctrl efface les trois bits du haut : `c` (0x63) devient 0x03.
            // Une lettre que la table ASCII ne porte pas n'envoie rien plutôt
            // qu'un octet inventé.
            guard let ascii = letter.lowercased().unicodeScalars.first?.value,
                  letter.lowercased().unicodeScalars.count == 1,
                  (0x61...0x7A).contains(ascii)
            else { return [] }
            return [UInt8(ascii) & 0x1F]
        }
    }

    /// **Ce que la console reçoit quand on touche une touche avec du texte en
    /// cours de saisie.**
    ///
    /// La ligne de commande de l'application est un champ de texte : ce qu'on
    /// y tape ne part qu'à « Entrée ». Une tabulation touchée après `ls /us`
    /// doit compléter `/us`, donc le texte part **d'abord**, sans retour à la
    /// ligne, puis la touche. Sans ça, la complétion porterait sur une ligne
    /// vide et l'historique remplacerait ce qu'on était en train d'écrire.
    public func sending(afterTyped typed: String, applicationCursorKeys: Bool = false) -> Data {
        Data(typed.utf8) + Data(bytes(applicationCursorKeys: applicationCursorKeys))
    }
}
