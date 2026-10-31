import Foundation

/// **Une machine qui redémarre repart d'elle-même**, mais pas en boucle.
///
/// **Pourquoi.** Un invité qui redémarre (`reboot`, ou `r` devant l'invite de
/// dinit) finissait sur « La machine a redémarré ; relancez-la. » : il
/// fallait fermer l'écran et toucher la machine de nouveau, là où un vrai PC
/// repart tout seul. La machine repart maintenant d'elle-même, comme lui.
///
/// **Pas en boucle.** Un noyau qui panique avec `panic=5` sur sa ligne de
/// commande redémarre cinq secondes après chaque démarrage, et un invité mal
/// réglé peut faire de même. Sur un téléphone, ce serait la batterie brûlée
/// jusqu'à ce que quelqu'un s'en aperçoive. Au-delà de `limit` redémarrages
/// en `window` secondes, la machine s'arrête et le dit.
///
/// Ce qui est décidé ici l'est sous des tests, sur Linux ; le modèle de vue
/// ne fait que suivre la réponse.
public struct AutomaticRestart: Equatable, Sendable {
    /// Combien de redémarrages d'affilée la machine fait d'elle-même.
    public static let limit = 3
    /// Sur quelle durée on les compte, en secondes.
    public static let window: TimeInterval = 120

    /// Ce que la console dit quand la machine s'arrête au lieu de repartir.
    public static let loopExplanation =
        "La machine redémarre en boucle : trois redémarrages en deux minutes. "
        + "Elle s'arrête là ; relancez-la quand vous voulez."

    /// Les redémarrages faits d'eux-mêmes, encore dans la fenêtre.
    public private(set) var recent: [Date] = []

    public init() {}

    /// Le redémarrage demandé à `now` relance-t-il la machine ? Oui jusqu'à
    /// `limit` dans la fenêtre, non au-delà. Un redémarrage daté d'après
    /// `now` — l'heure du téléphone qui recule — ne compte plus : mieux vaut
    /// un redémarrage de trop qu'une machine arrêtée pour une horloge.
    public mutating func shouldRestart(at now: Date) -> Bool {
        recent = recent.filter { $0 <= now && now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.limit else { return false }
        recent.append(now)
        return true
    }
}
