import Foundation

/// **Combien attendre avant de repeindre la console.**
///
/// L'invité écrit sur son propre fil, par morceaux, et chaque morceau demandait
/// une mise à jour de la console dès que la précédente était prise. Pendant un
/// démarrage bavard, le fil principal ne faisait plus que ça : la console se
/// repeignait aussi vite qu'il le pouvait, et le clavier, le défilement et
/// l'écran attendaient derrière.
///
/// **Trente fois par seconde au plus**, comme l'écran : une mise à jour qui
/// arrive moins de 1/30 s après la précédente attend la fin de l'intervalle, et
/// tous les morceaux arrivés entre-temps partent avec elle. **Une frappe isolée
/// part tout de suite** : la précédente est loin, il n'y a rien à attendre, et
/// l'écho reste immédiat.
///
/// Une valeur, et des instants en nanosecondes donnés par l'appelant : la règle
/// se teste sans horloge.
public struct ConsolePacer: Sendable, Equatable {
    /// L'intervalle le plus court entre deux mises à jour.
    public static let interval: UInt64 = 33_333_333

    /// L'instant de la dernière mise à jour, s'il y en a eu une.
    public private(set) var lastRefresh: UInt64?

    public init() {}

    /// Ce qu'une mise à jour demandée à `now` doit attendre : zéro si la
    /// précédente date d'au moins un intervalle, le reste de l'intervalle
    /// sinon.
    public func delay(at now: UInt64) -> UInt64 {
        guard let lastRefresh, now >= lastRefresh else { return 0 }
        let elapsed = now - lastRefresh
        return elapsed >= Self.interval ? 0 : Self.interval - elapsed
    }

    /// La console vient d'être repeinte.
    public mutating func refreshed(at now: UInt64) {
        lastRefresh = now
    }
}
