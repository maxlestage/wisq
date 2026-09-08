import Foundation

/// **De la prose, posée dans une grille de terminal.**
///
/// Les refus de wisq sont écrits pour une personne : « ce fichier est une image
/// de disque », « ce noyau vise une architecture qu'on n'a pas ». Ils finissent
/// dans une `TerminalGrid`, qui est un **vrai** terminal — elle coupe à la
/// colonne, sans savoir ce qu'est un mot, et elle ne rend aucun balisage.
///
/// Les deux défauts que ce fichier corrige viennent d'une capture d'écran, pas
/// d'une relecture : `**disque**` s'affichait avec ses astérisques, et le
/// retour à la ligne tombait au milieu des mots — « ne changer / a ça ».
///
/// **Ce n'est pas un rendu Markdown**, et il ne faut pas le laisser le devenir.
/// C'est le strict nécessaire pour qu'une phrase écrite dans le code arrive
/// lisible sur un écran de téléphone : les marques d'emphase et de code
/// partent, le texte qu'elles entourent reste, et le repli respecte les mots.
public enum ConsoleProse {
    /// Le texte débarrassé de son balisage et replié à cette largeur.
    ///
    /// Les paragraphes — séparés par une ligne vide — sont préservés : les
    /// fondre en un bloc rendrait le message illisible sur un téléphone.
    public static func plain(_ text: String, columns: Int) -> String {
        let width = max(1, columns)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                // Une ligne vide sépare deux paragraphes, et `wrapped` la
                // rend telle quelle : elle n'a aucun mot à replier.
                wrapped(stripped(String(line)), width: width)
            }
            .joined(separator: "\n")
    }

    /// **Les marques partent, leur contenu reste.**
    ///
    /// Une paire `**…**` ou `` `…` `` disparaît ; un astérisque **seul** ne
    /// bouge pas. La distinction compte : `rm -f /tmp/*.img` est une ligne de
    /// commande, et la traiter comme de l'emphase corromprait ce qu'on affiche.
    private static func stripped(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let opening = rest.range(of: "**") ?? rest.range(of: "`") {
            let marker = String(rest[opening])
            // Sans marque fermante, il n'y a pas de paire : ce qui reste est du
            // texte ordinaire, astérisque compris.
            guard let closing = rest[opening.upperBound...].range(of: marker) else { break }
            out += rest[..<opening.lowerBound]
            out += rest[opening.upperBound..<closing.lowerBound]
            rest = rest[closing.upperBound...]
        }
        return out + rest
    }

    /// **Le repli, sur les espaces.**
    ///
    /// Un mot plus long que la ligne est **coupé** plutôt qu'abandonné : c'est
    /// laid, mais perdre du texte serait faux, et le cas existe — un chemin de
    /// fichier interminable.
    private static func wrapped(_ line: String, width: Int) -> String {
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: true) {
            var word = Substring(word)
            // Le mot qui ne tiendra sur aucune ligne se coupe, autant de fois
            // qu'il le faut, avant même d'essayer de le placer.
            while word.count > width {
                if !current.isEmpty {
                    lines.append(current)
                    current = ""
                }
                let cut = word.index(word.startIndex, offsetBy: width)
                lines.append(String(word[..<cut]))
                word = word[cut...]
            }
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
