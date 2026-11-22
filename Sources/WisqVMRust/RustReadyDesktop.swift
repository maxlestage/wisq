import Foundation
import WisqVM

// MARK: - La machine de l'application

extension RustPCMachine {
    /// **La machine PC en Rust de l'application**, telle que
    /// `makeLocalMachine` la construit : une graine neuve (un bureau repris
    /// du même fichier sur deux téléphones ne doit pas tirer les mêmes
    /// nombres), et la carte réseau branchée sur `network` — le backend de
    /// `MachineNetwork` dans l'application, la passerelle isolée à la
    /// fabrique. L'écran se branche à part (`attachApplicationScreen`),
    /// comme `GuestMachineFactory.attachScreen` pour le cœur Swift. `nil`
    /// quand l'hôte ne peut pas donner la mémoire.
    ///
    /// Ici plutôt que dans l'application : la fabrique des bureaux prêts
    /// (`RustReadyDesktopBuild`) doit fabriquer et vérifier sur **la même**
    /// machine. Une machine sans carte réseau fabrique un bureau que
    /// l'application reprend sans réseau ; une autre taille d'écran, un
    /// bureau que la reprise refuse.
    public static func make(
        ramSize: Int, network: () -> NetworkBackend, onOutput: @escaping @Sendable (Data) -> Void
    ) -> RustPCMachine? {
        guard let machine = RustPCMachine(ramSize: ramSize, onOutput: onOutput) else { return nil }
        machine.seed(UInt64.random(in: .min ... .max))
        try? machine.attachNetwork(network())
        return machine
    }

    /// **L'écran de l'application** (`GuestMachineFactory.screenSize`), et sa
    /// tablette, avant `load` ou la reprise.
    public func attachApplicationScreen() throws {
        try attachDisplay(width: GuestMachineFactory.screenSize.width,
                          height: GuestMachineFactory.screenSize.height)
    }

    /// Voir `GuestMachine.reseed` : l'instantané de cette machine porte
    /// l'état de son générateur, et la reprise le remplace par la graine de
    /// cet appareil.
    public func reseed(_ seed: UInt64) {
        self.seed(seed)
    }
}

// MARK: - Le pilotage par la console

extension RustPCMachine: ScriptableMachine {
    public func advance(_ instructions: UInt64) -> String? {
        switch run(instructionBudget: instructions) {
        case .stopped: return nil
        case .powerOff: return "l'invité s'est éteint"
        case .reboot: return "l'invité a redémarré"
        case .faulted(let reason): return "le cœur a refusé : \(reason)"
        }
    }

    public func nudge(x: Double, y: Double) { _ = touch(x: x, y: y, buttons: 0) }

    public var screenPixels: [UInt8]? { display.map { [UInt8]($0.frame().data) } }
}

// MARK: - La fabrique

/// **Fabriquer un bureau prêt sur la machine PC en Rust** : ce que
/// `ReadyDesktopBuild` fait pour le cœur Swift — la machine de la fabrique,
/// la vérification de l'instantané —, pour le cœur qui démarre maintenant
/// les machines PC neuves. Le déroulé (`ReadyDesktopBuild.voidXfce`),
/// l'assemblage de l'archive (`ReadyDesktopBuild.assemble`) et la fiche sont
/// les mêmes : seuls la machine et l'instantané changent.
///
/// **Pourquoi un bureau à son format** : une session reprend sur le cœur qui
/// l'a écrite (`RustPCSetting.runs`). Un bureau prêt du cœur Swift tourne
/// donc sur le cœur Swift, deux fois plus lent, quel que soit le réglage.
public enum RustReadyDesktopBuild {
    /// Le cœur des entrées que cette fabrique écrit.
    public static let core = ReadyDesktop.Core.rust
    /// Le niveau qu'elle annonce : la version de l'instantané
    /// (`RustPCSnapshot.version`), au-dessus de ce que lisent les
    /// applications d'avant (`ReadyDesktop.Core.firstRustLevel`).
    public static var level: UInt64 { UInt64(RustPCSnapshot.version) }

    /// **La machine de l'application, pour fabriquer** : `RustPCMachine.make`
    /// et l'écran de l'application. Deux écarts, ceux du cœur Swift
    /// (`ReadyDesktopBuild.machine`) : le réseau **isolé**, son NTP à l'heure
    /// figée, et l'horloge CMOS **figée** à `frozenAt` ; et la graine fixée
    /// (`X86Entropy.reproducibleSeed`), pour que deux fabrications se
    /// comparent. Le téléphone remplace cette graine à la reprise
    /// (`PendingSession`, `reseed`).
    public static func machine(
        ramSize: Int, frozenAt: Date?, onOutput: @escaping @Sendable (Data) -> Void
    ) throws -> RustPCMachine {
        let hostClock: @Sendable () -> Date
        if let frozenAt { hostClock = { frozenAt } } else { hostClock = { Date() } }
        guard let machine = RustPCMachine.make(
            ramSize: ramSize, network: { UserNetwork.isolated(hostClock: hostClock) }, onOutput: onOutput)
        else { throw ReadyDesktopBuild.Refusal.notAPC }
        machine.seed(X86Entropy.reproducibleSeed)
        if let frozenAt { machine.freezeHostTime(at: frozenAt) }
        try machine.attachApplicationScreen()
        return machine
    }

    /// Ce qu'une machine reprise donne à voir, pour le verdict.
    public struct Seen: Equatable, Sendable {
        /// La carte réseau est-elle revenue sur le bus ?
        public var network: Bool
        /// L'invité a-t-il pris la tablette ? (Un toucher est-il admis ?)
        public var tablet: Bool
        /// La part allumée de l'écran repris.
        public var lit: Double

        public init(network: Bool, tablet: Bool, lit: Double) {
            self.network = network
            self.tablet = tablet
            self.lit = lit
        }
    }

    /// **Le verdict sur ce qu'on a vu**, dans l'ordre du cœur Swift
    /// (`ReadyDesktopBuild.check`) : la carte réseau, la tablette, l'écran.
    /// Rend la part allumée.
    public static func verdict(_ seen: Seen) throws -> Double {
        guard seen.network else { throw ReadyDesktopBuild.Refusal.noNetwork }
        guard seen.tablet else { throw ReadyDesktopBuild.Refusal.noTablet }
        guard seen.lit > 0.5 else { throw ReadyDesktopBuild.Refusal.darkScreen(lit: seen.lit) }
        return seen.lit
    }

    /// **Reprendre l'instantané dans une machine de l'application neuve**,
    /// comme le fera le téléphone, et vérifier ce qu'il en reviendra : la
    /// version de l'instantané, la mémoire, la reprise elle-même, la carte
    /// réseau, la tablette, l'écran dessiné. Rend la part allumée.
    ///
    /// **Les disques d'abord** : l'instantané les dit « ailleurs », et la
    /// machine refuse une reprise sur d'autres disques que les siens. `disk`
    /// est l'image, `writes` la couche que la fabrication lui a donnée — celle
    /// que l'archive emporte. La reprise ne fait pas tourner l'invité : la
    /// couche n'est pas touchée.
    @discardableResult
    public static func check(_ snapshot: Data, ramSize: Int, disk: URL, writes: URL) throws -> Double {
        let header = RustPCSnapshot.header(of: snapshot)
        guard let header, header.version == RustPCSnapshot.version else {
            throw ReadyDesktopBuild.Refusal.level(saved: header.map { UInt64($0.version) }, expected: level)
        }
        guard header.ramSize == ramSize else {
            throw ReadyDesktopBuild.Refusal.memory(saved: header.ramSize, expected: ramSize)
        }
        guard let machine = RustPCMachine.make(
            ramSize: ramSize, network: { UserNetwork.isolated() }, onOutput: { _ in })
        else { throw ReadyDesktopBuild.Refusal.notAPC }
        do {
            try machine.attachApplicationScreen()
            try machine.attachDisk(fileAt: disk, writes: writes)
            try machine.restore(snapshot)
        } catch {
            throw ReadyDesktopBuild.Refusal.unreadable(String(describing: error))
        }
        // L'écran avant le toucher : rien ne change à l'image tant que
        // l'invité ne tourne pas, mais lire d'abord ne coûte rien.
        let lit = GuestScript.litFraction(machine.screenPixels ?? [])
        return try verdict(Seen(network: machine.networkCounts != nil,
                                tablet: machine.touch(x: 0.5, y: 0.5, buttons: 0), lit: lit))
    }
}
