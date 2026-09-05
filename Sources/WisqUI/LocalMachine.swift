#if os(iOS)
// `Data` : le protocole `GuestMachine` en prend et en rend, et ce fichier écrit
// une conformance. Aucun des autres types d'ici n'en avait besoin jusque-là.
import Foundation
import WisqVM
#if WISQ_RUST_CORE
import WisqVMRust
#endif

/// Which rv32ima interpreter the app actually runs.
///
/// There are two, and they are held to being interchangeable: the differential
/// test in `WisqVMRustTests` boots the same kernel through both and compares
/// them instruction count by instruction count and console byte by console
/// byte. That test is what makes a one-line switch defensible instead of
/// reckless — without it, swapping the engine under the app would be a change
/// nobody could check.
///
/// The Rust one is the faster of the two — about +8 % over a full boot — so it
/// is the default, and the one the app ships with. `WISQ_SWIFT_CORE=1` picks
/// the Swift one instead, for someone who has Swift and nothing else and only
/// wants to work on the protocol side; the manifest stops the build with the
/// command to run rather than quietly falling back, because which interpreter
/// ships must not depend on whether the build machine happened to have cargo.
///
/// Only the CPU changes. The console is `TerminalGrid` either way — the
/// terminal was never the part that needed rewriting.
/// **Ce que ce nom veut dire depuis qu'il y a deux architectures.**
///
/// C'était un choix à la compilation : la machine locale était l'un des deux
/// interprètes rv32, désigné par un drapeau. Ça suffisait tant qu'il n'y avait
/// qu'une architecture. Maintenant qu'un fichier peut demander un cœur x86-64,
/// le choix se fait à l'**exécution** — voir `GuestMachineFactory` — et ce
/// nom-ci ne désigne plus que « lequel des deux rv32 ».
#if WISQ_RUST_CORE
typealias LocalRISCVMachine = RustLinuxMachine
#else
typealias LocalRISCVMachine = LinuxMachine
#endif

/// Le cœur Rust vu par le protocole commun.
///
/// La conformance vit ici et non dans `WisqVMRust`, parce que ce module-là ne
/// dépend pas de `WisqVM` — et c'est voulu : l'interprète Rust ne doit rien au
/// côté Swift, ce qui est justement ce qui en fait un témoin utilisable.
///
/// **Pas de `@retroactive` ici**, et c'est une leçon payée par une intégration
/// rouge. L'attribut existe pour une conformance dont on ne possède ni le type
/// ni le protocole ; `swiftc` seul, sans savoir de quel paquet vient quoi, le
/// réclame. Le vrai bâti passe `-package-name wisq` : les trois modules sont du
/// même paquet, la conformance n'a donc rien de rétroactif, et l'attribut
/// devient une erreur. Le compilateur a raison — personne d'autre ne peut
/// déclarer celle-ci.
#if WISQ_RUST_CORE
extension RustLinuxMachine: GuestMachine {
    public var ramSizeBytes: Int { Int(ramSize) }

    public func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws {
        // Même refus que le cœur Swift, et pour la même raison : ce chargeur
        // place un noyau et un arbre de périphériques, et un disque en mémoire
        // n'y a aucun champ où être annoncé.
        guard initialRamdisk == nil else {
            throw GuestMachineRefusal.noRamdiskHere(architecture: "RISC-V 32 bits")
        }
        // **L'arbre est construit ici, une fois, pour les deux cœurs.** C'est
        // le seul endroit du programme qui connaît les deux côtés, et c'est
        // donc le seul où « la même carte » peut être autre chose qu'une
        // intention : `RV32DeviceTree` dit la machine, `WisqVMRust` la reçoit
        // en octets sans savoir qui l'a écrite, et le cœur Swift lit la même.
        //
        // **Et c'est ici que le disque devient trouvable.** Le cœur Swift
        // bâtit son propre arbre et décide donc seul ; celui-ci reçoit le
        // sien, et il faut lui demander le nœud. `hasDisk` traverse le FFI
        // pour ça : un arbre sans le nœud décrit une machine sans disque, et
        // l'invité ne sonderait jamais la fenêtre.
        try load(kernelImage: kernelImage,
                 deviceTree: RV32DeviceTree.tree(
                    ramSize: Int(ramSize), commandLine: commandLine,
                    disk: hasDisk).flatten())
    }

    /// Le disque, avant `load` — voir `attach(disk:)`.
    public func attachDisk(_ image: Data) throws { attach(disk: [UInt8](image)) }

    @discardableResult
    public func runGuest(instructionBudget: UInt64) -> GuestOutcome {
        switch run(instructionBudget: instructionBudget) {
        case .powerOff: return .powerOff
        case .reboot: return .reboot
        case .stopped: return .stopped
        }
    }
}
#endif

/// La machine que ce fichier demande, construite.
///
/// **C'est ici que la sélection automatique arrive dans l'application.**
/// `KernelImageKind.core` a lu le fichier ; il ne reste qu'à obéir.
func makeLocalMachine(
    for core: GuestArchitecture.Core, ramSizeBytes: Int,
    onOutput: @escaping @Sendable (Data) -> Void
) -> GuestMachine {
    GuestMachineFactory.make(
        for: core, ramSizeBytes: ramSizeBytes, onOutput: onOutput,
        riscv: { size, output in
            LocalRISCVMachine(ramSize: UInt32(clamping: size), onOutput: output)
        })
}

#endif
