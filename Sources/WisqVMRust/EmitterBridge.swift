import Foundation
import WisqVM

/// **Ce que la page de la machine de l'émetteur dit, et ce qu'on lui dit**,
/// sans la vue.
///
/// La page poste des messages (`web/machine.js`) et l'application lui répond
/// en JavaScript évalué. Les deux sens sont du calcul : lire un dictionnaire,
/// écrire une chaîne. Ici, ils se jugent sous Linux ; `EmitterDesktop` ne fait
/// que les relayer.
///
/// **Rien de ce qui vient de l'application n'est recollé tel quel** dans le
/// JavaScript : les nombres traversent en nombres, le texte en littéral JSON
/// (`JSONSerialization`), jamais entre deux guillemets posés à la main.
public enum EmitterBridge {
    /// Ce que la page peut dire.
    public enum Message: Equatable, Sendable {
        /// La RAM est posée, les registres écrits : la machine peut partir.
        case ready(pages: Int, pieces: Int)
        /// Des octets du port série, et combien ont été jetés avant eux.
        case console(Data, lost: Int)
        /// L'écran de l'invité a pris ce mode.
        case screen(width: Int, height: Int)
        /// La machine s'est arrêtée, et dit pourquoi et où ; `refusal` est la
        /// dernière région refusée, s'il y en a eu une.
        case stopped(why: String, at: UInt64, refusal: String?)
        /// La page est tombée en panne, sous ce nom.
        case failure(String)
    }

    /// Pourquoi un message n'a pas pu être lu : la page est engendrée par
    /// wisq, donc ce sont des défauts — les deux moitiés ont divergé.
    public enum Unreadable: Error, Equatable, Sendable {
        case noKind
        case unknownKind(String)
        case missingField(String)
    }

    /// Lire un message tel que `WKScriptMessage.body` le livre.
    public static func message(from body: [String: Any]) throws -> Message {
        guard let kind = body["kind"] as? String else { throw Unreadable.noKind }
        switch kind {
        case "prête":
            return .ready(pages: try int(body, "pages"), pieces: try int(body, "segments"))
        case "console":
            guard let text = body["octets"] as? String, let octets = Data(base64Encoded: text) else {
                throw Unreadable.missingField("octets")
            }
            return .console(octets, lost: (try? int(body, "perdus")) ?? 0)
        case "écran":
            return .screen(width: try int(body, "largeur"), height: try int(body, "hauteur"))
        case "arrêt":
            guard let why = body["stopped"] as? String else { throw Unreadable.missingField("stopped") }
            // **L'adresse arrive en texte** : au-delà de deux puissance
            // cinquante-trois, un nombre JavaScript perd ses bits, et un noyau
            // vit plus haut.
            guard let text = body["at"] as? String, let at = UInt64(text) else {
                throw Unreadable.missingField("at")
            }
            var refusal: String?
            if let dernier = body["refus"] as? [String: Any],
               let where_ = dernier["a"] as? String, let pourquoi = dernier["pourquoi"] as? String {
                refusal = "\(where_) : \(pourquoi)"
            }
            return .stopped(why: why, at: at, refusal: refusal)
        case "panne":
            guard let why = body["pourquoi"] as? String else { throw Unreadable.missingField("pourquoi") }
            return .failure(why)
        default:
            throw Unreadable.unknownKind(kind)
        }
    }

    /// Un entier du message : `WKScriptMessage` livre les nombres en
    /// `NSNumber`, et `as? Int` les lit ; un `Double` entier aussi.
    private static func int(_ body: [String: Any], _ field: String) throws -> Int {
        if let value = body[field] as? Int { return value }
        if let value = body[field] as? Double, value == value.rounded(), abs(value) < 1e15 { return Int(value) }
        throw Unreadable.missingField(field)
    }

    // MARK: - Ce qu'on dit à la page

    /// **Des touches du clavier PS/2**, dans l'ordre : chaque événement est
    /// une touche du jeu 1 enfoncée ou relâchée (`X86Keystrokes`).
    public static func keys(_ events: [X86Keystrokes.Event]) -> String {
        let list = events.map { "[\($0.code.set1),\($0.code.extended),\($0.down)]" }.joined(separator: ",")
        return "window.wisq.touches([\(list)])"
    }

    /// Une touche de la barre de la console, sur le clavier de l'écran.
    public static func key(_ key: TerminalKey) -> String {
        keys(X86Keystrokes.key(key))
    }

    /// **Un texte**, tapé au rythme d'une main sur un clavier américain par la
    /// carte elle-même (`taperTexte`). En littéral JSON : un guillemet, une
    /// barre oblique ou un saut de ligne dans le texte restent du texte.
    public static func typing(_ text: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [text], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return "window.wisq.taper(\(literal)[0])"
    }

    /// **Un toucher**, de 0 à 1 sur chaque axe, les boutons en bits ; ce qui
    /// sort de l'écran est ramené au bord, et ce qui n'est pas un nombre à
    /// son milieu — une coordonnée `NaN` écrite dans le JavaScript serait un
    /// identifiant, pas un nombre.
    public static func touch(x: Double, y: Double, buttons: UInt8) -> String {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0.5 }
        return "window.wisq.toucher(\(clamp(x)),\(clamp(y)),\(buttons))"
    }

    /// **Une touche du clavier matériel**, par le keysym X11 que
    /// `KeyboardCaptureView` rend : la touche du jeu 1 enfoncée ou relâchée,
    /// sans les modificateurs autour (ils arrivent par leurs propres
    /// keysyms). Les caractères d'un clavier américain, les touches
    /// d'édition, les flèches, F1 à F12 et les modificateurs ; rien pour le
    /// reste, plutôt qu'une touche au hasard.
    public static func events(forKeysym keysym: UInt32, down: Bool) -> [X86Keystrokes.Event] {
        let code: X86ScanCode?
        switch keysym {
        case 0xFF08: code = .backspace
        case 0xFF09: code = .tab
        case 0xFF0D: code = .enter
        case 0xFF1B: code = .escape
        case 0xFF50: code = .home
        case 0xFF51: code = .left
        case 0xFF52: code = .up
        case 0xFF53: code = .right
        case 0xFF54: code = .down
        case 0xFF55: code = .pageUp
        case 0xFF56: code = .pageDown
        case 0xFF57: code = .end
        case 0xFFFF: code = .delete
        case 0xFFE1, 0xFFE2: code = .leftShift
        case 0xFFE3, 0xFFE4: code = .leftControl
        case 0xFFE9, 0xFFEA: code = .leftAlt
        case 0xFFEB, 0xFFEC: code = .leftMeta
        case 0xFFBE...0xFFC9: code = X86ScanCode.function(Int(keysym - 0xFFBE) + 1)
        // Les keysyms des caractères imprimables sont leurs points de code
        // Latin-1 ; la touche est la même, Maj ou non.
        case 0x20...0x7E:
            code = Unicode.Scalar(keysym).flatMap { X86ScanCode.typing(Character($0))?.code }
        default: code = nil
        }
        guard let code else { return [] }
        return [(code, down)]
    }

    /// **Arrêter la machine** à la fin de sa tranche ; rien quand la page n'a
    /// pas encore de conducteur.
    public static let stop = "window.wisq && window.wisq.arreter()"

    /// La molette, en crans, positifs vers le haut.
    public static func scroll(notches: Int) -> String {
        "window.wisq.defiler(\(max(min(notches, 127), -127)))"
    }
}

/// **Le réglage qui ouvre une machine dans l'émetteur**, éteint par défaut.
///
/// La clé est celle de `UserDefaults`, que la vue lit par `@AppStorage`. Le
/// verdict — cette image s'ouvre-t-elle dans l'émetteur ? — est ici, jugé sous
/// Linux : le réglage allumé, une image que la machine PC démarre (un noyau
/// x86-64 ou une image de disque à déballer), une construction qui porte le
/// module. Une machine installée garde son disque et sa session : elle reste
/// au cœur Swift, qui sait la suspendre et la reprendre, ce que l'émetteur
/// ne sait pas encore.
public enum EmitterSetting {
    public static let key = "wisq.machine.emetteur"
    /// Éteint : l'application ne bascule pas.
    public static let defaultValue = false

    public static func opens(
        _ kind: KernelImageKind?, enabled: Bool, installed: Bool, moduleEmbedded: Bool
    ) -> Bool {
        guard enabled, !installed, moduleEmbedded, let kind else { return false }
        if case .discImage = kind { return true }
        return kind.core == .x86_64
    }
}
