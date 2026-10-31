import Foundation

/// Comment une machine locale se termine, quelle que soit son architecture.
public enum GuestOutcome: Equatable, Sendable {
    /// L'invité s'est éteint, et plus rien ne peut le réveiller.
    case powerOff
    /// L'invité a demandé un redémarrage.
    case reboot
    /// Quelqu'un a demandé l'arrêt, ou le budget s'est épuisé.
    case stopped
    /// Le cœur a refusé quelque chose, **nommé**. Un arrêt sans nom envoie
    /// chercher partout ; celui-ci dit quoi.
    case faulted(String)
}

/// **Où en est une machine, lisible pendant qu'elle tourne.**
///
/// `retiredInstructions` n'est lisible qu'à l'arrêt : le fil d'émulation
/// l'écrit à chaque instruction, et le lire d'ailleurs serait une course. Tous
/// ses appelants sont d'ailleurs des tests, un banc et un instantané — jamais
/// une vue. Celui-ci est **publié** par le fil qui l'écrit, sous verrou, sur
/// une cadence : il est en retard, jamais faux.
///
/// **Pourquoi il existe.** Une capture d'un noyau Arch sous wisq montre
/// quelques lignes puis plus rien pendant dix minutes. « Il tourne en rond »
/// et « il est mort » ne se corrigent pas du tout pareil, et rien à l'écran ne
/// les distinguait — l'application ne montrait aucun signe de vie. Un compteur
/// qui grimpe tranche en une seconde ce qu'une relecture de code ne tranche
/// pas.
public struct GuestProgress: Equatable, Sendable {
    /// Ce que l'invité avait retiré au dernier point de publication.
    public var retired: UInt64
    /// Où il en était. Un compteur qui grimpe dit **que** ça tourne ;
    /// l'adresse dit **où**, ce qui est la moitié qui permet d'agir.
    public var rip: UInt64

    public init(retired: UInt64, rip: UInt64) {
        self.retired = retired
        self.rip = rip
    }
}

/// Ce que l'application attend d'une machine locale — et rien de plus.
///
/// **Pourquoi il existe.** Il y avait un `typealias` : la machine locale était
/// l'un des deux interprètes rv32, choisi à la **compilation** par un drapeau.
/// Ça marchait tant qu'il n'y avait qu'une architecture. Maintenant qu'un
/// fichier peut demander un cœur x86-64 ou un cœur RISC-V, le choix doit se
/// faire à l'**exécution**, sur ce que le fichier dit — voir
/// `GuestArchitecture.core`.
///
/// **Les noms ne sont pas tous ceux des classes**, et c'est délibéré.
/// `runGuest` s'appelle ainsi parce que les deux `run` existants rendent des
/// types différents : une exigence de protocole nommée `run` créerait une
/// surcharge que seul le type de retour distingue, donc un appel ambigu à
/// chaque site. Un nom un peu plus long vaut mieux qu'une ambiguïté que le
/// compilateur résout au hasard.
public protocol GuestMachine: AnyObject, Sendable {
    /// La mémoire de cette machine, en octets.
    var ramSizeBytes: Int { get }
    /// Ce que l'invité a vraiment exécuté. **À lire quand la machine est
    /// arrêtée** : le fil d'émulation écrit ce compteur à chaque instruction.
    /// Pour le regarder pendant qu'elle tourne, voir `liveProgress`.
    var retiredInstructions: UInt64 { get }

    /// Où en est la machine, pendant qu'elle tourne — ou `nil` pour un cœur
    /// qui ne publie pas encore.
    ///
    /// **`nil` plutôt que zéro, et ce n'est pas un détail.** Zéro se lit comme
    /// « rien n'a tourné », c'est-à-dire exactement la confusion que cette
    /// propriété existe pour lever. Un cœur qui ne sait pas répondre doit
    /// faire taire la ligne d'état, pas la remplir d'un chiffre faux.
    ///
    /// Le cœur x86-64 le publie. Les deux cœurs rv32 ne le font pas encore :
    /// celui en Rust demanderait un compteur atomique côté Rust, parce que
    /// lire à travers le FFI pendant que l'autre fil tient un `&mut` n'est pas
    /// permis — et une lecture qu'on croit inoffensive est justement la sorte
    /// de course qui ne se voit qu'en production.
    var liveProgress: GuestProgress? { get }

    /// Charge un noyau, et éventuellement un disque en mémoire.
    ///
    /// Une machine qui ne sait pas prendre de disque en mémoire **refuse** un
    /// disque plutôt que de l'ignorer : l'ignorer donnerait un démarrage qui
    /// échoue plus loin, pour une raison que personne ne relierait à ça.
    func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws

    /// Branche un disque, que l'invité verra comme un périphérique bloc.
    ///
    /// Les deux machines savent le faire. Ce qu'aucune ne peut faire, c'est
    /// mettre le pilote bloc dans le noyau de la personne : c'est à quoi
    /// `diskActivity` sert.
    func attachDisk(_ image: Data) throws

    /// Branche un disque **lu sur place**, avec sa couche d'écriture durable
    /// à côté — voir `FileDiskStore`. Rien de la base n'est copié : c'est la
    /// porte par laquelle passe une image de plusieurs gigaoctets.
    func attachDisk(fileAt base: URL, writes: URL) throws

    /// Branche un **second** disque, lu sur place — `/dev/vdb` pour un noyau
    /// Linux. C'est celui sur lequel on installe quand le premier est l'image
    /// d'installation. Seule la machine PC en a un ; les autres refusent en
    /// le disant (voir l'extension par défaut).
    func attachSecondDisk(fileAt base: URL, writes: URL) throws

    /// Pousse ce que l'invité a écrit sur son disque jusqu'au stockage
    /// durable. Chaque écriture y est déjà ; ceci ajoute `fsync`, pour le
    /// passage en arrière-plan.
    func flushDisk()

    /// Combien d'octets de disque l'invité a changés — la couche pour un
    /// disque sur fichier, l'image entière pour un disque en mémoire.
    var diskBytesWritten: Int { get }

    /// Ce que le disque a vu — servies, refusées — ou `nil` s'il n'y en a pas.
    ///
    /// **Zéro et zéro est la réponse qui compte.** wisq ne peut pas mettre un
    /// pilote bloc dans le noyau que quelqu'un apporte ; un noyau qui n'en a
    /// pas ne touchera jamais la fenêtre du périphérique, et sans ce compteur
    /// le symptôme est un disque parfaitement muet — impossible à distinguer
    /// d'un disque cassé. Avec, la machine sait le dire.
    var diskActivity: (served: UInt64, refused: UInt64)? { get }

    /// Fait tourner l'invité jusqu'à ce qu'il s'arrête, qu'on le lui demande,
    /// ou que le budget s'épuise.
    @discardableResult
    func runGuest(instructionBudget: UInt64) -> GuestOutcome

    /// Demande à un `runGuest` en cours de rendre la main. Depuis n'importe
    /// quel fil.
    func stop()
    /// Donne des octets tapés à l'invité. Depuis n'importe quel fil.
    func send(_ data: Data)
    /// La machine entière en octets.
    func snapshot() -> Data
    /// Reprend une machine sauvée.
    func restore(_ data: Data) throws
    /// **Le temps passé hors de la machine** : une session reprise le
    /// lendemain doit savoir quel jour on est. À appeler machine arrêtée,
    /// entre la reprise et le premier tour ; le temps dû se paie ensuite par
    /// pas, pendant que l'invité dort. Voir `GuestClock`.
    func elapse(seconds: TimeInterval)
}

/// Ce que les machines partagent pour rattraper le temps passé dehors.
public enum GuestClock {
    /// Au-delà, la session est de toute façon d'une autre époque ; borner
    /// garde le calcul loin du débordement.
    public static let longestElapse: TimeInterval = 10 * 365 * 86_400

    /// **Le plus grand pas d'un rattrapage**, en secondes : dix.
    ///
    /// Deux bornes. Un noyau convertit l'écart lu à son compteur en
    /// nanosecondes par une multiplication sur soixante-quatre bits, sûre
    /// jusqu'à `max_cycles` : environ 990 s pour le TSC de cette machine, dit
    /// le journal de Debian 13 ; Linux 6.12 traite au-delà, les noyaux
    /// d'avant non. Et **le chien de garde de Linux** : une horloge qui saute
    /// de plus de vingt secondes sans que son fil ait tourné lui fait crier
    /// « BUG: soft lockup - CPU#0 stuck for 280s! [swapper/0:0] », et le
    /// détecteur de RCU fait de même au-delà de vingt et une. C'est ce que
    /// les pas de cinq minutes affichaient sur le téléphone, une ligne par
    /// pas, à la reprise d'une session. Dix secondes restent sous les deux.
    ///
    /// Chaque pas est payé quand l'invité s'est rendormi, c'est-à-dire après
    /// qu'il a compté le précédent et que son chien de garde a tourné.
    ///
    /// **Ce que le rattrapage coûte à l'invité**, mesuré sur le noyau RISC-V
    /// de référence : environ cent mille instructions par seconde rattrapée,
    /// soit un millier par battement à 100 Hz. Ce noyau avance ses battements
    /// un à un, par pas ou d'un seul coup. Trois jours valent donc quelque
    /// vingt-sept milliards d'instructions, payées pendant que l'invité
    /// tourne.
    public static let stepSeconds: TimeInterval = 10

    /// L'écart à rattraper, ou `nil` s'il n'y a rien à faire : le temps de
    /// l'invité ne recule pas, et un écart qui n'est pas un nombre ne se
    /// rattrape pas.
    public static func catchUp(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds > 0, seconds.isFinite else { return nil }
        return min(seconds, longestElapse)
    }
}

/// Ce qu'une machine refuse quand on lui demande ce qu'elle ne sait pas faire.
///
/// **Elle porte ses phrases**, et pas seulement ses cas. L'application affiche
/// `error.localizedDescription` de tout ce qui remonte du démarrage ; sans
/// `LocalizedError`, un refus parfaitement précis arrivait à l'écran sous la
/// forme « The operation couldn't be completed », qui est le contraire de ce
/// que ces cas existent pour dire.
extension GuestMachine {
    /// Le temps écoulé depuis `savedAt`, l'heure de l'instantané repris
    /// (`SuspendedMachine.savedAt`). Sans heure, rien : mieux vaut une heure
    /// en retard qu'un écart inventé.
    public func elapse(since savedAt: Date?, now: Date = Date()) {
        guard let savedAt else { return }
        elapse(seconds: now.timeIntervalSince(savedAt))
    }

    /// Une machine sans second périphérique bloc refuse, et nomme pourquoi :
    /// accepter en silence ferait chercher à l'invité un `vdb` qui n'arrive
    /// jamais.
    public func attachSecondDisk(fileAt base: URL, writes: URL) throws {
        throw GuestMachineRefusal.noSecondDiskHere
    }
}

public enum GuestMachineRefusal: Error, Equatable, LocalizedError {
    /// Un disque en mémoire donné à une machine qui n'en prend pas.
    ///
    /// Il y avait ici un second cas, `noDiskHere`, pour une machine sans
    /// contrôleur à qui parler. Les deux machines en ont un maintenant, et un
    /// cas d'erreur que plus rien ne peut lever est un mensonge qui attend
    /// d'être cru : il est parti avec le refus.
    case noRamdiskHere(architecture: String)
    /// Un second disque donné à une machine qui n'a qu'un périphérique bloc.
    case noSecondDiskHere

    public var errorDescription: String? {
        switch self {
        case .noSecondDiskHere:
            return """
                Cette machine n'a qu'un disque. Un second — celui sur lequel on \
                installe depuis une image — n'existe que sur la machine PC.
                """
        case .noRamdiskHere(let architecture):
            return """
                La machine \(architecture) ne prend pas d'initramfs : son \
                chargeur place un noyau et un arbre de périphériques, et rien \
                d'autre.
                """
        }
    }
}

// MARK: - Les deux machines de ce module

extension LinuxMachine: GuestMachine {
    public var ramSizeBytes: Int { Int(ramSize) }

    public func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws {
        // Le chargeur RISC-V de ce dépôt place un noyau et un arbre de
        // périphériques, et rien d'autre. Un disque en mémoire n'y a pas de
        // champ où être annoncé ; l'accepter en silence ferait échouer le
        // démarrage plus loin, sans rapport visible avec la cause.
        guard initialRamdisk == nil else {
            throw GuestMachineRefusal.noRamdiskHere(architecture: "RISC-V 32 bits")
        }
        try load(kernelImage: kernelImage, commandLine: commandLine)
    }

    /// **Cette machine-ci n'a pas de disque, et ce n'est pas un oubli.** Le
    /// noyau rv32 « nommu » de cette famille n'a aucun pilote bloc compilé
    /// dedans ; c'est l'instantané de la machine entière qui fait le travail
    /// qu'un disque aurait fait. Un contrôleur virtio ici serait un
    /// périphérique que personne n'énumère.
    /// **Le refus a disparu, et c'est une machine qui a changé, pas un texte.**
    ///
    /// Cette conformance jetait `noDiskHere` : la carte rv32 n'avait ni
    /// contrôleur d'interruption pour un périphérique, ni moyen de le déclarer
    /// — le blob d'arbre était figé. Les deux manques ont été comblés, la
    /// fenêtre est décodée, et le disque sert de vraies requêtes.
    ///
    /// Ce que wisq ne peut toujours pas faire, et qui reste vrai : mettre le
    /// pilote bloc dans le noyau de la personne. Un noyau qui n'en a pas ne
    /// touchera jamais la fenêtre — et le périphérique compte ses requêtes,
    /// donc la machine sait le dire.
    public func attachDisk(_ image: Data) throws { attach(disk: [UInt8](image)) }

    public func attachDisk(fileAt base: URL, writes: URL) throws {
        try attach(diskFileAt: base, writes: writes)
    }

    public func flushDisk() { disk?.flush() }

    public var diskBytesWritten: Int { disk?.store.bytesWritten ?? 0 }

    public var diskActivity: (served: UInt64, refused: UInt64)? {
        disk.map { ($0.served, $0.refused) }
    }

    @discardableResult
    public func runGuest(instructionBudget: UInt64) -> GuestOutcome {
        switch run(instructionBudget: instructionBudget) {
        case .powerOff: return .powerOff
        case .reboot: return .reboot
        case .stopped: return .stopped
        }
    }
}

extension X86Machine: GuestMachine {
    public var ramSizeBytes: Int { ramSize }

    /// Les deux portes de `attach(disk:)` — MMIO et PCI — sont posées d'un
    /// coup ; c'est le noyau qui choisit celle qu'il sait ouvrir.
    public func attachDisk(_ image: Data) throws { attach(disk: [UInt8](image)) }

    public func attachDisk(fileAt base: URL, writes: URL) throws {
        try attach(diskFileAt: base, writes: writes)
    }

    public func attachSecondDisk(fileAt base: URL, writes: URL) throws {
        try attach(secondDiskFileAt: base, writes: writes)
    }

    public func flushDisk() {
        disk?.flush()
        secondDisk?.flush()
    }

    public var diskBytesWritten: Int {
        (disk?.store.bytesWritten ?? 0) + (secondDisk?.store.bytesWritten ?? 0)
    }

    public var diskActivity: (served: UInt64, refused: UInt64)? {
        disk.map { ($0.served, $0.refused) }
    }

    @discardableResult
    public func runGuest(instructionBudget: UInt64) -> GuestOutcome {
        switch run(instructionBudget: instructionBudget) {
        case .powerOff: return .powerOff
        case .reboot: return .reboot
        case .stopped: return .stopped
        case .faulted(let reason): return .faulted(reason)
        }
    }
}

/// Qui fabrique la machine que le fichier a demandée.
///
/// **C'est ici que la sélection automatique devient un objet.**
/// `KernelImageKind.core` dit quel cœur ; celui-ci le construit.
public enum GuestMachineFactory {
    /// La machine pour ce cœur.
    ///
    /// `riscv` est un point d'extension et non une commodité : l'application
    /// embarque **deux** interprètes rv32 — un en Swift et un en Rust —, et
    /// c'est un drapeau de compilation qui décide lequel part. Ce module ne
    /// connaît que le Swift ; l'application passe l'autre quand elle est
    /// construite avec.
    ///
    /// `network` : l'autre bout du câble de la machine PC. Il n'est demandé
    /// que pour elle — la carte RISC-V n'a pas de réseau —, et seulement
    /// quand elle est construite : un réseau ouvre des sockets et des fils.
    public static func make(
        for core: GuestArchitecture.Core,
        ramSizeBytes: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        network: () -> NetworkBackend? = { nil },
        riscv: (Int, @escaping @Sendable (Data) -> Void) -> GuestMachine = {
            LinuxMachine(ramSize: UInt32(clamping: $0), onOutput: $1)
        }
    ) -> GuestMachine {
        switch core {
        case .riscv32: return riscv(ramSizeBytes, onOutput)
        case .x86_64:
            let machine = X86Machine(ramSize: ramSizeBytes, onOutput: onOutput)
            if let backend = network() { machine.attach(network: VirtioNet(backend: backend)) }
            return machine
        }
    }
}

extension GuestMachine {
    /// Le défaut : un cœur qui ne publie pas se tait. Voir `liveProgress`.
    public var liveProgress: GuestProgress? { nil }
}
