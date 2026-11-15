import Foundation

/// **L'attente de la première reprise d'un bureau prêt**, dite en une phrase
/// tant que la console n'a pas répondu.
///
/// **Ce qui n'allait pas.** Au banc, la console d'un bureau prêt répond
/// 12,0 s après la reprise (l'entrée du 14 novembre de `docs/JOURNAL.md`) :
/// l'instantané de 842 Mio se déplie, puis l'interprète, encore froid, rejoue
/// l'invité jusqu'à ce que son shell lise la ligne de `FirstResume`. Pendant
/// ce temps, l'écran montrait le bureau tel que la fabrique l'avait laissé,
/// et rien ne répondait au doigt : un écran figé, juste après un
/// téléchargement de 1,5 Gio. La phrase de `FirstResume.note` n'arrive qu'à
/// la fin du dépliage, dans la console, que l'écran du bureau cache.
///
/// **Ce qui est fait.** Dès le toucher, une phrase hors de la console et de
/// l'écran : « Reprise du bureau en cours — 6 s ». Elle se tait au premier
/// octet que l'invité écrit sur sa console : l'écho de la ligne tapée, qui
/// prouve que l'invité lit de nouveau ce qu'on lui envoie. Au-delà de
/// l'attente ordinaire, elle le dit, sans crier à la panne : le signe de vie
/// (`GuestHeartbeat`) dit, lui, si la machine avance.
///
/// Seule la première reprise l'emploie : c'est la seule où une ligne est
/// tapée, donc la seule où un écho est sûr de venir. Une reprise ordinaire
/// retrouve un invité silencieux à son invite, et la phrase ne s'y tairait
/// jamais.
public struct ResumeWait: Equatable, Sendable {
    /// L'attente ordinaire, en secondes : 12,0 s mesurées au banc, et la
    /// marge d'un téléphone plus lent ou plus chargé que le banc.
    public static let usual: ClosedRange<Int> = 11...15

    /// Le toucher qui a lancé la reprise.
    public let since: Date
    /// Ce que l'invité avait écrit sur sa console au moment du toucher.
    let baseline: Int
    /// La console a répondu : la phrase se tait, pour de bon.
    public private(set) var answered = false

    /// `guestBytes` est ce que l'invité a écrit sur sa console jusqu'ici
    /// (`0` pour une machine qui vient d'être créée).
    public init(since: Date, guestBytes: Int = 0) {
        self.since = since
        baseline = guestBytes
    }

    /// Relevé de ce que l'invité a écrit. Rend `true` la fois où la console
    /// répond ; une phrase de wisq écrite dans la console (`FirstResume.note`)
    /// ne compte pas, elle ne passe pas par ce relevé.
    @discardableResult
    public mutating func observe(guestBytes: Int) -> Bool {
        guard !answered, guestBytes > baseline else { return false }
        answered = true
        return true
    }

    /// La phrase à montrer à `now`, ou `nil` quand la console a répondu.
    public func phrase(now: Date) -> String? {
        guard !answered else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let lower = Self.usual.lowerBound, upper = Self.usual.upperBound
        if seconds <= upper {
            return "Reprise du bureau en cours — \(seconds) s. L'écran ne répond pas encore : "
                + "la console répond d'habitude en \(lower) à \(upper) s."
        }
        return "Reprise du bureau en cours — \(seconds) s, plus long que d'habitude (\(lower) à \(upper) s). "
            + "Le signe de vie, dessous, dit si la machine avance."
    }
}
