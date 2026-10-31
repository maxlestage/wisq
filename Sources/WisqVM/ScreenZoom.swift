import Foundation

/// **Zoomer sur l'écran de la machine locale**, et ce que devient le doigt
/// qui sert de souris quand on zoome.
///
/// **Pourquoi.** L'écran d'un PC invité fait 1024 pixels de large ou plus ;
/// un iPhone en portrait en montre 390 points. Ajusté à la largeur, le texte
/// qu'un noyau écrit en démarrant tient sur quatre ou cinq points de haut, et
/// une capture du téléphone l'a montré : « ACPI BIOS Error » se devinait, il
/// ne se lisait pas. Pincer grossit jusqu'à `maximum` fois l'ajustement ;
/// glisser à deux doigts déplace la vue ; un doigt reste la souris.
///
/// **Le doigt suit le zoom.** Dix points de glissement déplacent le pointeur
/// de l'invité de dix points *à l'écran*, quel que soit le zoom. Zoomé
/// quatre fois, cela fait quatre fois moins de pixels de l'invité, donc un
/// pointeur plus fin, exactement quand on regarde de près.
///
/// Ce qui est décidé ici l'est sous des tests, sur Linux ; la vue ne fait que
/// lire ces nombres.
public enum ScreenZoom {
    /// Le zoom le plus fort, en multiples de l'ajustement. Six fois : sur un
    /// iPhone en portrait, un caractère de huit pixels sur seize de la
    /// console du noyau fait alors environ dix-huit points sur trente-sept.
    public static let maximum: Double = 6

    /// Combien de points de l'iPhone un pixel de l'invité occupe quand
    /// l'écran entier tient dans la vue : le zoom le plus faible. `nil` tant
    /// que l'invité n'a pas d'écran ou que la vue n'a pas de taille.
    public static func fit(guestWidth: Int, guestHeight: Int, viewWidth: Double, viewHeight: Double) -> Double? {
        guard guestWidth > 0, guestHeight > 0,
              viewWidth.isFinite, viewHeight.isFinite, viewWidth > 0, viewHeight > 0
        else { return nil }
        return min(viewWidth / Double(guestWidth), viewHeight / Double(guestHeight))
    }
}

/// **Le doigt qui sert de souris** : des points parcourus aux pixels de
/// l'invité, sans perdre les fractions.
///
/// Sans le reste, un glissement lent n'avancerait jamais : à trois points
/// par pixel, chaque déplacement d'un point arrondirait à zéro.
public struct ScreenPointer: Equatable {
    /// Le plus grand pas rendu d'un coup. Un pas plus long ne vient que d'un
    /// zoom absurde, et le convertir tel quel en `Int` arrêterait l'app.
    public static let longestStep = 4096

    public private(set) var remainderX: Double = 0
    public private(set) var remainderY: Double = 0

    public init() {}

    /// Le déplacement de l'invité pour `dx`, `dy` points de glissement, ou
    /// `nil` s'il n'a pas encore fait un pixel. `pointsPerPixel` : combien de
    /// points de l'iPhone un pixel de l'invité occupe en ce moment,
    /// l'ajustement multiplié par le zoom. Une échelle nulle ou absurde ne
    /// déplace rien et ne touche pas au reste.
    public mutating func move(dx: Double, dy: Double, pointsPerPixel: Double) -> (dx: Int, dy: Int)? {
        guard pointsPerPixel.isFinite, pointsPerPixel > 0, dx.isFinite, dy.isFinite else { return nil }
        let limit = Double(Self.longestStep)
        let x = min(max(dx / pointsPerPixel + remainderX, -limit), limit)
        let y = min(max(dy / pointsPerPixel + remainderY, -limit), limit)
        let wholeX = Int(x.rounded(.towardZero))
        let wholeY = Int(y.rounded(.towardZero))
        remainderX = x - Double(wholeX)
        remainderY = y - Double(wholeY)
        guard wholeX != 0 || wholeY != 0 else { return nil }
        return (wholeX, wholeY)
    }

    /// Le doigt se lève : le reste ne passe pas au glissement suivant.
    public mutating func lift() {
        remainderX = 0
        remainderY = 0
    }
}
