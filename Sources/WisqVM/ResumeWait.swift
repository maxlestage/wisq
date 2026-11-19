import Foundation

/// **L'attente de la première reprise d'un bureau prêt**, dite en une phrase
/// tant que la console n'a pas répondu.
///
/// **Ce qui n'allait pas.** Au banc, la console d'un bureau prêt rend
/// `REPRIS_42` 12,0 s après la reprise (l'entrée du 14 novembre de
/// `docs/JOURNAL.md`) : comptées après `restore`, et après une première
/// commande (`pgrep`, `dmesg`) que le banc tape avant celle-là.
/// L'interprète, encore froid, rejoue l'invité jusqu'à ce que son shell
/// lise ce qu'on lui tape. Avant cela,
/// l'application lit l'image et déplie l'instantané brut de 345,8 Mio, sur
/// le fil principal. Pendant tout ce temps, l'écran montrait le bureau tel
/// que la fabrique l'avait laissé, et rien ne répondait au doigt : un écran
/// figé, juste après un téléchargement de 1,5 Gio. La phrase de
/// `FirstResume.note` n'arrive qu'à la fin du dépliage, dans la console, que
/// l'écran du bureau cache.
///
/// **Ce qui est fait.** Une phrase hors de la console et de l'écran :
/// « Reprise du bureau en cours — 6 s ». **Elle ne se montre qu'une fois le
/// fil principal rendu**, l'image lue et l'instantané déplié : ce travail se
/// fait sur ce fil, et rien ne s'affiche tant qu'il dure. **Ses secondes se
/// comptent depuis le toucher** (`since`, pris en tête de
/// `LocalVMModel.boot`), ce travail compris. Elle se tait au premier octet
/// que l'invité écrit sur sa console : l'écho de la ligne tapée, qui prouve
/// que l'invité lit de nouveau ce qu'on lui envoie. Au-delà de l'attente
/// ordinaire, elle le dit, sans crier à la panne : le signe de vie
/// (`GuestHeartbeat`) dit, lui, si la machine avance.
///
/// Seule la première reprise l'emploie : c'est la seule où une ligne est
/// tapée, donc la seule où un écho est sûr de venir. Une reprise ordinaire
/// retrouve un invité silencieux à son invite, et la phrase ne s'y tairait
/// jamais.
public struct ResumeWait: Equatable, Sendable {
    /// L'attente ordinaire, en secondes, autour des 12,0 s du banc. Ce
    /// n'est pas la mesure de ce que la phrase compte : le banc part après
    /// `restore` et s'arrête à la réponse de sa deuxième commande, quand la
    /// phrase part du toucher (le dépliage compris) et se tait au premier
    /// écho. Ni ce dépliage sur un téléphone, ni ce premier écho n'ont été
    /// mesurés : la fourchette est une estimation, à reprendre sur un iPhone.
    public static let usual: ClosedRange<Int> = 11...15

    /// Le toucher qui a lancé la reprise : pris avant l'image lue et
    /// l'instantané déplié, pas après.
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
