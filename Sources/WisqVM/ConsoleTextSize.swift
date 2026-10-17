import Foundation

/// La taille du texte de la console locale, en points.
///
/// **Pourquoi ce type existe.** La console était écrite en 12 points, sans
/// recours : trop petit pour lire debout dans un train, trop grand pour qu'une
/// ligne de quatre-vingts colonnes tienne sur un téléphone en portrait. Les
/// deux besoins sont réels et opposés ; c'est à la personne de choisir, et le
/// choix doit survivre à la session.
///
/// **Des crans, pas un continuum.** Un pincement donne un facteur quelconque ;
/// la taille retenue est le cran le plus proche. Une police monospace à 12,37
/// points ne se lit pas mieux qu'à 12, et des crans fixes rendent « A+ » et
/// « A− » prévisibles : deux appuis ramènent toujours où l'on était.
///
/// Ce qui est décidé ici l'est sous des tests, sur Linux ; la vue ne fait que
/// lire et écrire un nombre.
public enum ConsoleTextSize {
    /// Les crans, du plus petit au plus grand.
    public static let steps: [Double] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24]
    /// La taille d'avant ce type, gardée comme défaut : rien ne change pour
    /// qui ne touche à rien.
    public static let standard: Double = 12

    /// Le cran le plus proche d'une taille quelconque — une valeur enregistrée
    /// par une version qui avait d'autres crans, ou illisible, retombe sur un
    /// cran valide. À égale distance de deux crans, le plus petit.
    public static func nearest(_ size: Double) -> Double {
        guard size.isFinite else { return standard }
        return steps.min { abs($0 - size) < abs($1 - size) } ?? standard
    }

    /// Un cran au-dessus, ou le plus grand s'il n'y en a plus.
    public static func larger(than size: Double) -> Double {
        let current = nearest(size)
        return steps.first { $0 > current } ?? steps[steps.count - 1]
    }

    /// Un cran au-dessous, ou le plus petit s'il n'y en a plus.
    public static func smaller(than size: Double) -> Double {
        let current = nearest(size)
        return steps.last { $0 < current } ?? steps[0]
    }

    /// Ce que devient `size` sous un pincement de facteur `magnification` —
    /// le cran le plus proche du produit, borné aux crans extrêmes.
    public static func scaled(_ size: Double, by magnification: Double) -> Double {
        guard magnification.isFinite, magnification > 0 else { return nearest(size) }
        return nearest(nearest(size) * magnification)
    }

    public static func canGrow(_ size: Double) -> Bool { nearest(size) < steps[steps.count - 1] }
    public static func canShrink(_ size: Double) -> Bool { nearest(size) > steps[0] }
}
