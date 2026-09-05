import Foundation
import SwiftUI

/// Le texte d'un refus, avec l'accent qu'il a été écrit pour avoir.
///
/// **Le défaut que ça corrige.** `Text(_:)` et `Label(_:systemImage:)` ont
/// deux surcharges, et c'est le compilateur qui tranche : un littéral choisit
/// `LocalizedStringKey`, qui lit le markdown ; une **variable** choisit
/// `String`, qui ne le lit pas. Les refus de wisq sont tous écrits en
/// markdown léger — `**en mémoire**`, `` `/dev/vda` `` — et arrivaient à
/// l'écran avec leurs étoiles et leurs accents graves, à côté de littéraux
/// voisins qui, eux, se rendaient très bien. Rien ne prévient : les deux
/// lignes ont la même tête.
///
/// **Pourquoi pas `Text(.init(chaîne))`**, le raccourci qui force
/// `LocalizedStringKey`. Une clé passe aussi par le formatage, et un `%` y
/// devient une spécification. Or « 50%.iso » est un nom de fichier valide, et
/// le refus recopie le nom du fichier : c'est précisément le seul endroit du
/// texte où ce caractère peut venir de quelqu'un d'autre que nous.
/// `AttributedString` ne formate rien.
///
/// **L'analyse est inline et préserve les blancs**, pas en blocs : un refus
/// dit quoi, puis pourquoi, séparés par une ligne vide, et l'analyse en blocs
/// referait la mise en page à sa façon.
enum RefusalText {
    static func rendered(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        // Le pire cas est le texte tel quel — avec ses étoiles, donc, mais
        // lisible. Un refus qu'on n'a pas su analyser reste un refus qu'il
        // faut lire.
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// Un refus, tel que l'écran le montre : l'icône, et le texte rendu.
///
/// La vue existe pour que le prochain endroit qui affiche un refus n'ait pas
/// à retrouver seul l'histoire ci-dessus.
struct RefusalLabel: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"

    var body: some View {
        Label {
            Text(RefusalText.rendered(text))
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
