import Foundation

/// Ce que la console reçoit quand on colle un texte.
///
/// **Pourquoi ce type existe.** La ligne de commande de l'application est un
/// champ d'une ligne : un script de dix lignes copié depuis une page y arrivait
/// recousu en une seule, ou pas du tout. Coller doit envoyer le texte **tel
/// qu'un terminal l'enverrait**, et ce qu'un terminal envoie a trois règles,
/// toutes décidées ici sous des tests plutôt que dans la vue :
///
/// 1. **Un retour à la ligne s'écrit `\r`**, comme la touche Entrée — c'est ce
///    que fait xterm. `\r\n` venu de Windows n'en fait qu'un, pas deux : un
///    collage ne doit pas inventer des lignes vides.
/// 2. **Aucun caractère de contrôle ne passe**, sauf la tabulation. Un texte
///    copié n'est pas une suite de touches : un `ESC` caché dedans serait
///    exécuté par le programme qui écoute, et `ESC [ 2 0 1 ~` fermerait
///    l'encadrement de la règle suivante de l'intérieur — le texte collé
///    reprendrait alors la main comme s'il était tapé. Les contrôles C1
///    (`U+0080`…`U+009F`) partent aussi : `U+009B` est un `ESC [` sur un octet.
/// 3. **Encadré quand le programme l'a demandé** (`TerminalGrid.bracketedPaste`) :
///    `ESC [ 200 ~`, le texte, `ESC [ 201 ~`. Bash garde alors les lignes
///    collées dans sa ligne d'édition au lieu d'exécuter chacune.
public enum TerminalPaste {
    public static let start = Data("\u{1B}[200~".utf8)
    public static let end = Data("\u{1B}[201~".utf8)

    /// Le texte collé, nettoyé selon les deux premières règles.
    public static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            defer { previousWasCarriageReturn = value == 0x0D }
            switch value {
            case 0x0D:
                scalars.append("\r")
            case 0x0A:
                if !previousWasCarriageReturn { scalars.append("\r") }
            case 0x09:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Les octets à envoyer à l'invité. Un texte que le nettoyage vide
    /// n'envoie rien — pas même un encadrement vide.
    public static func bytes(for text: String, bracketed: Bool) -> Data {
        let body = Data(cleaned(text).utf8)
        guard !body.isEmpty else { return Data() }
        return bracketed ? start + body + end : body
    }

    /// Comme `TerminalKey.sending(afterTyped:)` : ce qui était en cours de
    /// saisie part d'abord, hors de l'encadrement — c'est du texte tapé — puis
    /// le collage.
    public static func sending(
        _ text: String, afterTyped typed: String, bracketed: Bool
    ) -> Data {
        Data(typed.utf8) + bytes(for: text, bracketed: bracketed)
    }
}
