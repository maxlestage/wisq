import Foundation

/// **Ce que la carte d'une machine montre avant son nom** : la distribution
/// qu'elle fait tourner, dite par une forme et une couleur, et si c'est un
/// bureau.
///
/// **Pourquoi ce type existe.** La liste des machines dessinait chaque ligne
/// sous la même icône d'ordinateur : trois machines — un Alpine, un Void Xfce,
/// une Debian — se ressemblaient jusqu'à ce qu'on lise leur nom de fichier.
/// La carte les distingue d'un coup d'œil, et ce choix vit ici, dans un module
/// qui se construit sous Linux et se tient donc par des tests, comme
/// `LibraryEntry` pour le rôle d'un fichier.
///
/// **Aucune marque n'est copiée** : le symbole est un SF Symbol choisi pour
/// évoquer la distribution (une montagne pour Alpine, un tourbillon pour
/// Debian), jamais son logo ; la couleur est une teinte, pas un dessin.
public enum MachineBadge {
    /// Les distributions que wisq sait reconnaître à un nom.
    public enum Distribution: String, CaseIterable, Equatable, Sendable {
        case alpine, void, debian, ubuntu, fedora, arch, opensuse
        /// Rien de reconnu : un Linux, sans plus.
        case linux

        /// Le nom écrit sur la carte.
        public var displayName: String {
            switch self {
            case .alpine: return "Alpine"
            case .void: return "Void"
            case .debian: return "Debian"
            case .ubuntu: return "Ubuntu"
            case .fedora: return "Fedora"
            case .arch: return "Arch"
            case .opensuse: return "openSUSE"
            case .linux: return "Linux"
            }
        }

        /// Le symbole du badge.
        public var symbol: String {
            switch self {
            case .alpine: return "mountain.2.fill"
            case .void: return "circle.dashed"
            case .debian: return "hurricane"
            case .ubuntu: return "sun.max.fill"
            case .fedora: return "f.cursive"
            case .arch: return "triangle.fill"
            case .opensuse: return "leaf.fill"
            case .linux: return "terminal.fill"
            }
        }

        /// La teinte du badge, en composantes de 0 à 1. Assez sombre pour
        /// qu'un symbole blanc s'y lise, en clair comme en sombre.
        public var tint: (red: Double, green: Double, blue: Double) {
            switch self {
            case .alpine: return (0.05, 0.38, 0.56)
            case .void: return (0.22, 0.50, 0.36)
            case .debian: return (0.66, 0.05, 0.22)
            case .ubuntu: return (0.86, 0.33, 0.13)
            case .fedora: return (0.16, 0.36, 0.66)
            case .arch: return (0.07, 0.50, 0.72)
            case .opensuse: return (0.35, 0.56, 0.18)
            case .linux: return (0.33, 0.30, 0.62)
            }
        }

        /// Les mots qui la nomment, dans un nom de fichier ou de machine.
        var words: Set<String> {
            switch self {
            case .alpine: return ["alpine"]
            case .void: return ["void", "voidlinux"]
            case .debian: return ["debian"]
            case .ubuntu: return ["ubuntu", "kubuntu", "xubuntu", "lubuntu"]
            case .fedora: return ["fedora"]
            case .arch: return ["arch", "archlinux"]
            case .opensuse: return ["opensuse", "suse", "tumbleweed", "leap"]
            case .linux: return []
            }
        }
    }

    /// **La distribution que ces noms désignent**, le premier qui en dit une
    /// l'emportant : le nom que la personne a donné à sa machine d'abord,
    /// puis le fichier qu'elle démarre.
    ///
    /// Par mots entiers, pas par sous-chaînes : « archive.img » n'est pas Arch,
    /// « avoid.iso » n'est pas Void.
    public static func distribution(of names: [String]) -> Distribution {
        for name in names {
            let words = Set(self.words(in: name))
            if let found = Distribution.allCases.first(where: { !$0.words.isDisjoint(with: words) }) {
                return found
            }
        }
        return .linux
    }

    /// Les environnements de bureau qu'un nom peut porter.
    static let desktopWords: Set<String> = [
        "xfce", "xfce4", "gnome", "kde", "plasma", "lxqt", "lxde", "mate", "cinnamon", "desktop", "bureau",
    ]

    /// **Est-ce un bureau ?** Un nom qui porte un environnement graphique, ou
    /// un bureau prêt (`ReadyDesktop`, une archive `.wisqmachine`).
    public static func isDesktop(_ names: [String]) -> Bool {
        names.contains { !desktopWords.isDisjoint(with: words(in: $0)) }
    }

    /// Les mots d'un nom, en minuscules : des lettres seules, que les
    /// chiffres, les points, les tirets et les soulignés séparent.
    static func words(in name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }
}

/// **L'état d'une machine, dit sur sa carte** : en marche, à reprendre, à
/// l'arrêt, ou jamais lancée — et la couleur que la pastille prend.
public enum MachineState: Equatable, Sendable {
    /// Sa session est sauvée : la toucher la reprend où on l'a laissée.
    case sessionSaved
    /// Lancée au moins une fois, sans session à reprendre : la toucher la
    /// redémarre.
    case stopped
    /// Jamais lancée.
    case neverStarted

    /// La décision : une session sauvée l'emporte sur tout — c'est la
    /// différence entre retrouver son travail et redémarrer.
    public static func of(savedSessions: Int, lastStartedAt: Date?) -> MachineState {
        if savedSessions > 0 { return .sessionSaved }
        return lastStartedAt == nil ? .neverStarted : .stopped
    }

    /// Ce que la pastille écrit.
    public var word: String {
        switch self {
        case .sessionSaved: return "Session sauvée"
        case .stopped: return "Éteinte"
        case .neverStarted: return "Jamais lancée"
        }
    }

    /// Le symbole de la pastille.
    public var symbol: String {
        switch self {
        case .sessionSaved: return "pause.circle.fill"
        case .stopped: return "power.circle"
        case .neverStarted: return "sparkles"
        }
    }

    /// Ce que fait le bouton principal de la carte.
    public var action: String {
        switch self {
        case .sessionSaved: return "Reprendre"
        case .stopped, .neverStarted: return "Démarrer"
        }
    }
}

/// **Les petites phrases des cartes et des progressions**, au même endroit
/// pour que deux écrans ne disent pas la même chose de deux façons.
public enum MachineCardText {
    /// « x86-64 · 2,0 Gio » : le cœur, puis la mémoire, puis ce qu'il y a à
    /// dire du disque. Les morceaux absents ne laissent pas de séparateur.
    public static func specs(core: String?, memory: UInt64?, disk: String?) -> String {
        [core, memory.map(KernelMemory.describe), disk]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Le pourcentage reçu, arrondi vers le bas et borné à 0…100 : « 100 % »
    /// ne se lit qu'une fois tout arrivé, jamais à 99,6 %.
    public static func percent(have: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let clamped = min(max(have, 0), total)
        // En double largeur : `clamped * 100` déborde au-delà de 92 Pio, et
        // un flottant rendrait 28 pour 29 sur 100.
        return total.dividingFullWidth(clamped.multipliedFullWidth(by: 100)).quotient
    }

    /// « 612,0 Mio sur 1,7 Gio · 35 % »
    public static func progress(have: Int, total: Int) -> String {
        "\(LocalStorage.describe(bytes: have)) sur \(LocalStorage.describe(bytes: total))"
            + " · \(percent(have: have, total: total)) %"
    }
}
