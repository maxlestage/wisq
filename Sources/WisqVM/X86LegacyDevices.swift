import Foundation

/// Le 8259 et le 8253 : le strict nécessaire pour qu'un noyau Linux trouve une
/// horloge.
///
/// **Pourquoi ces deux-là et pas un APIC.** Le noyau d'Alpine s'arrêtait sur
/// `Failed to register legacy timer interrupt`, après avoir écrit
/// `Using NULL legacy PIC` : sa sonde du contrôleur d'interruptions avait
/// échoué, donc il n'avait personne à qui demander l'interruption zéro. La
/// sonde est trois lignes — écrire un masque dans le port 0x21 et le relire —
/// et tout le reste en découle. Un APIC aurait demandé dix fois plus de code
/// pour la même conclusion.
///
/// **Le temps de l'invité vient du compteur d'instructions.** Il n'y a pas
/// d'horloge dans un interprète, et en brancher une vraie rendrait les
/// exécutions irreproductibles — deux démarrages du même noyau ne donneraient
/// plus la même chose, et un instantané ne rendrait plus la machine telle
/// quelle. C'est une **décision**, comme ce que `CPUID` annonce, et pas une
/// mesure : le 8253 avance d'un cran tous les `X86LegacyDevices.instructionsPerTick`
/// instructions retirées.
public struct X86LegacyDevices: Sendable, Equatable {
    /// Combien d'instructions valent un battement du 8253.
    ///
    /// Le vrai compte à 1,193182 MHz. À la vitesse mesurée de ce cœur — autour
    /// de quatorze millions d'instructions par seconde — douze instructions
    /// par battement donneraient à peu près le temps réel. C'est le chiffre
    /// retenu : ni si petit que le noyau passe son temps dans son gestionnaire,
    /// ni si grand que ses attentes durent une éternité.
    public static let instructionsPerTick: UInt64 = 12

    /// Un 8259. Deux en cascade forment le contrôleur d'un PC.
    public struct Controller: Sendable, Equatable {
        /// Les lignes masquées. Toutes, tant que le noyau n'a rien dit.
        public var mask: UInt8 = 0xFF
        /// Les lignes qui demandent, et celles qui sont en cours de service.
        public var request: UInt8 = 0
        public var service: UInt8 = 0
        /// Le vecteur de la ligne zéro. Linux met le maître à 0x20.
        public var vectorBase: UInt8 = 0
        /// Où en est la séquence d'initialisation : ICW1 la lance, puis ICW2,
        /// ICW3 et ICW4 arrivent par le port de données. Sans ce compte, le
        /// premier octet écrit après ICW1 serait pris pour un masque.
        public var initialisationStep = 0
        /// Ce que le port de commande rend : le registre de demande, ou celui
        /// de service. C'est OCW3 qui choisit.
        public var readsService = false
    }

    public var primary = Controller()
    public var secondary = Controller()

    // MARK: - Le 8253

    /// La valeur de rechargement du canal zéro, celui qui bat.
    public var reload: UInt16 = 0
    /// L'état d'accès du canal zéro : le 8253 se lit et s'écrit un octet à la
    /// fois, et se souvient duquel c'est le tour.
    public var writeHighNext = false
    public var readHighNext = false
    /// La valeur figée par une commande de verrouillage, s'il y en a une.
    public var latched: UInt16?
    /// Le nombre de battements au dernier rechargement, pour compter à partir
    /// de là.
    public var reloadedAt: UInt64 = 0
    /// Le canal deux, celui du haut-parleur — et celui par lequel Linux
    /// étalonne son compteur de cycles. Il ne bat pas : il compte une fois
    /// jusqu'à zéro, et le port 0x61 dit quand c'est fait.
    public var speakerReload: UInt16 = 0
    public var speakerWriteHighNext = false
    public var speakerReadHighNext = false
    public var speakerStartedAt: UInt64 = 0
    public var speakerGate = false

    /// Ce que le bit 5 du port 0x61 rend : « le canal deux est arrivé à zéro ».
    public func speakerFinished(at ticks: UInt64) -> Bool {
        guard speakerGate, speakerReload != 0 else { return false }
        return ticks &- speakerStartedAt >= UInt64(speakerReload)
    }

    /// Ce qu'une lecture du canal deux rend.
    public func speakerCount(at ticks: UInt64) -> UInt16 {
        guard speakerGate, speakerReload != 0 else { return speakerReload }
        let elapsed = ticks &- speakerStartedAt
        return elapsed >= UInt64(speakerReload) ? 0 : speakerReload &- UInt16(elapsed)
    }

    /// Combien d'interruptions zéro ont déjà été levées. C'est ce compteur qui
    /// évite d'en lever deux pour le même battement.
    public var raised: UInt64 = 0

    /// Le compte du canal zéro, tel qu'une lecture le verrait.
    public func count(at ticks: UInt64) -> UInt16 {
        guard reload != 0 else { return 0 }
        let elapsed = (ticks &- reloadedAt) % UInt64(reload)
        return UInt16(UInt64(reload) &- elapsed)
    }

    /// Combien de fois le canal zéro a débordé depuis son rechargement.
    public func expirations(at ticks: UInt64) -> UInt64 {
        guard reload != 0 else { return 0 }
        return (ticks &- reloadedAt) / UInt64(reload)
    }
}
