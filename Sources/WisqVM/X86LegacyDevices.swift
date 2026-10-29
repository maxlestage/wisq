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
    /// Le vrai compte à 1,193182 MHz. Ce nombre dit donc **la vitesse que
    /// l'invité croit à son processeur** : soixante-douze instructions par
    /// battement font un processeur de 86 MHz, ce que le noyau mesure au
    /// démarrage (« Detected 85.908 MHz processor »).
    ///
    /// **Pourquoi trente-six, et plus douze.** Douze donnaient à peu près le
    /// temps réel quand ce cœur exécutait quatorze millions d'instructions par
    /// seconde. Mais les délais des systèmes, eux, sont écrits pour des
    /// machines mille fois plus rapides, et ils se comptent en temps de
    /// l'invité. Fedora 44 compile systemd avec un délai de 45 s, qui borne
    /// aussi ses vingt générateurs : à douze, ils n'y tenaient pas, `SIGALRM`
    /// les tuait, et systemd gelait au démarrage. À trente-six, ils passent
    /// et Fedora va jusqu'au shell de `root`.
    ///
    /// **Ce que ça coûte.** Plus rien pour l'attente : une machine endormie
    /// saute jusqu'au prochain battement (voir `idleStep`), et une seconde
    /// de sommeil ne coûte pas plus d'instructions à l'hôte qu'avant. Pour le
    /// travail, le temps de l'invité avance plus lentement que celui de
    /// l'hôte — c'est le but : un délai de l'invité couvre trois fois plus de
    /// travail. Et un noyau à 1000 Hz traite trois fois moins d'échéances par
    /// instruction.
    ///
    /// **Puis soixante-douze.** NixOS 25.05 attend `/dev/ttyS0` pendant les
    /// 90 s par défaut de systemd, et udevd ne démarre qu'après les services
    /// de `tmpfiles` : à trente-six, ces 90 s valaient 3,9 milliards
    /// d'instructions, elles expiraient avant lui, et la console série
    /// n'avait jamais de getty. À soixante-douze, le périphérique est trouvé,
    /// la session s'ouvre sur la console, et le démarrage entier prend
    /// 35,5 milliards d'instructions au lieu de 48,4 — la génération des clés
    /// SSH, qui se mesure en temps de l'invité, en fait moins. Alpine, lui,
    /// ne bouge pas : 62,5 s avant, 61,1 s après, pour le même shell.
    ///
    /// **C'est le rapport des machines neuves.** Une machine reprise garde le
    /// sien, écrit dans son instantané : son noyau a étalonné son TSC contre
    /// le 8253 au démarrage, et le 8253 garde ses échéances en battements.
    public static let instructionsPerTick: UInt64 = 72

    /// **Le rapport des instantanés qui ne le disent pas** : ils ont été
    /// écrits quand il valait trente-six pour toutes les machines. Les
    /// reprendre à soixante-douze couperait chaque battement en deux sous le
    /// noyau, et ramènerait `ticks` loin derrière les échéances du 8253.
    public static let legacyInstructionsPerTick: UInt64 = 36

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

    /// Le 16550. Voir `X86SerialPort.swift`.
    public var serial = SerialPort()
    /// L'horloge et la mémoire CMOS, aux ports 0x70 et 0x71 : voir
    /// `X86RealTimeClock`. Hors de l'instantané, comme l'heure elle-même.
    public var clock = X86RealTimeClock()

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

    /// Le canal zéro programmé pour **un** coup (modes 0 et 4), et non pour
    /// battre. C'est ce que fait Linux dès que son horloge de référence est le
    /// compteur de cycles : il réarme le canal à chaque échéance, pour la
    /// suivante seulement.
    public var oneShot = false

    /// L'intervalle le plus court qu'on accorde à un coup unique : quatre
    /// millisecondes, le battement d'un noyau à 250 Hz.
    ///
    /// **Pourquoi.** Le noyau d'Ubuntu bat à 1000 Hz. À douze instructions
    /// par battement, une milliseconde faisait quatorze mille instructions
    /// (quarante-trois mille à trente-six), et le traitement
    /// d'une échéance — l'ordonnanceur, les minuteries, la comptabilité de
    /// charge — en prend cinq mille : échantillonné pendant le démarrage
    /// d'Ubuntu 26.04, 37 % des instructions de l'invité y passaient, et udev
    /// ne vidait pas sa file avant l'expiration de systemd. Un noyau en coup
    /// unique ne compte pas les échéances, il lit l'heure au compteur de
    /// cycles et rattrape ce qui est passé : en livrer une sur quatre ne lui
    /// fait rien perdre. Le mode périodique, lui, compte chaque battement
    /// pour avancer `jiffies`, et on n'y touche pas.
    public static let shortestOneShot: UInt64 = 4773

    /// Combien de fois le canal zéro a débordé depuis son rechargement.
    public func expirations(at ticks: UInt64) -> UInt64 {
        guard reload != 0 else { return 0 }
        let period = oneShot ? max(UInt64(reload), Self.shortestOneShot) : UInt64(reload)
        return (ticks &- reloadedAt) / period
    }
}
