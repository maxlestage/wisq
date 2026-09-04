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
    /// Ce que l'invité a vraiment exécuté.
    var retiredInstructions: UInt64 { get }

    /// Charge un noyau, et éventuellement un disque en mémoire.
    ///
    /// Une machine qui ne sait pas prendre de disque en mémoire **refuse** un
    /// disque plutôt que de l'ignorer : l'ignorer donnerait un démarrage qui
    /// échoue plus loin, pour une raison que personne ne relierait à ça.
    func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws

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
}

/// Ce qu'une machine refuse quand on lui demande ce qu'elle ne sait pas faire.
public enum GuestMachineRefusal: Error, Equatable {
    /// Un disque en mémoire donné à une machine qui n'en prend pas.
    case noRamdiskHere(architecture: String)
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

    @discardableResult
    public func runGuest(instructionBudget: UInt64) -> GuestOutcome {
        switch run(instructionBudget: instructionBudget) {
        case .powerOff: return .powerOff
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
    public static func make(
        for core: GuestArchitecture.Core,
        ramSizeBytes: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        riscv: (Int, @escaping @Sendable (Data) -> Void) -> GuestMachine = {
            LinuxMachine(ramSize: UInt32(clamping: $0), onOutput: $1)
        }
    ) -> GuestMachine {
        switch core {
        case .riscv32: return riscv(ramSizeBytes, onOutput)
        case .x86_64: return X86Machine(ramSize: ramSizeBytes, onOutput: onOutput)
        }
    }
}
