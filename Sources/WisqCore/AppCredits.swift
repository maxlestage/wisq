import Foundation

/// **Qui a fait wisq, et ce qu'il doit à d'autres** — ce que l'application
/// montre au démarrage animé et dans « À propos ».
///
/// Les deux listes ne se mélangent pas, pour la raison que le pied du site
/// donne déjà (`crates/wisq-site/src/shell.rs`) : une ligne qui dit ce qui
/// est à l'auteur ne doit jamais se lire comme une revendication sur ce qui
/// ne l'est pas. Le texte des emprunts suit `NOTICE` mot pour mot ou presque,
/// et un test les confronte.
public enum AppCredits {
    /// L'auteur, en entier.
    public static let author = "Maxime Nathan Lestage"
    /// La mention au-dessus du nom.
    public static let role = "Conçu et développé par"
    /// « Copyright 2026 Maxime Nathan Lestage », comme `NOTICE` et le
    /// manifeste de l'application.
    public static let copyright = "© 2026 \(author). Tous droits réservés."
    /// D'où vient le code, comme le pied du site le dit.
    public static let crafted = "Fabriqué en Swift et en Rust, en France."

    /// Un emprunt : à qui, et ce qui en a été pris.
    public struct Acknowledgement: Equatable, Sendable {
        public let name: String
        public let detail: String
    }

    /// Ce que `NOTICE` crédite.
    public static let acknowledgements = [
        Acknowledgement(
            name: "mini-rv32ima, de Charles Lohr (MIT)",
            detail: "La sémantique d'exécution rv32ima, réécrite en Swift et en Rust, et son arbre de "
                + "périphériques sixtyfourmb.dtb, embarqué tel quel. Aucun code source de mini-rv32ima "
                + "n'est inclus."),
        Acknowledgement(
            name: "UTM (Apache 2.0)",
            detail: "Le modèle tactile du client a été éclairé par l'étude d'UTM. Aucun code source "
                + "d'UTM n'est inclus."),
    ]
}
