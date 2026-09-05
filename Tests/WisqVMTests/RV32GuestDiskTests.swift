import Foundation
import XCTest

@testable import WisqVM
import WisqVMTestKit

/// **Un invité rv32 qui conduit le disque depuis l'intérieur de la machine.**
///
/// Les tests de la tranche précédente posaient les anneaux depuis Swift et
/// sonnaient la file en appelant `write` sur le périphérique. Ça prouvait que
/// le périphérique sert une vraie requête ; ça ne prouvait rien du chemin par
/// lequel un invité y arrive — le décodeur, la fenêtre MMIO, `mtvec`, la
/// livraison de l'interruption externe, `mret`.
///
/// Ici, tout se passe dans la machine. Le programme est écrit en instructions
/// rv32, chargé comme un noyau, et il **attend l'interruption** avant de
/// regarder son tampon : sans elle il tourne en rond jusqu'à la fin du budget
/// et la console reste vide. C'est ce qui fait de la sortie une preuve.
///
/// La sortie attendue est `OK\n`, et chaque caractère est gagné :
/// - le `O` est le premier octet du secteur 1 du disque, recopié par le
///   périphérique dans la mémoire de l'invité puis relu par l'invité ;
/// - le `K` est `'K' + statut`, donc un `K` seulement si l'octet de statut
///   vaut zéro — n'importe quelle erreur virtio donnerait une autre lettre ;
/// - le saut de ligne fait vider la console, sans quoi on ne verrait rien.
final class RV32GuestDiskTests: XCTestCase {
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Ce qu'un passage laisse derrière lui.
    ///
    /// L'arbre est relu **juste après `load`**, avant que le programme
    /// tourne : il est désigné par `a1`, c'est-à-dire `x11`, et ce programme
    /// se sert de `x11` pour son octet de statut. Lire après coup mesurerait
    /// donc le tampon de statut et pas l'arbre — un piège que seul un invité
    /// qui écrase ses registres de départ pouvait révéler.
    private struct Run {
        let console: String
        let machine: LinuxMachine
        let tree: [UInt8]
    }

    private func run(disk: [UInt8]?, budget: UInt64 = 2_000_000) throws -> Run {
        let console = Console()
        let machine = LinuxMachine { console.append($0) }
        if let disk { machine.attach(disk: disk) }
        try machine.load(kernelImage: RV32Asm.image(RV32DiskGuest.program()))
        let tree = machine.deviceTreeHandedToTheGuest
        _ = machine.run(instructionBudget: budget)
        return Run(console: console.text, machine: machine, tree: tree)
    }

    // MARK: - Ce que ça prouve

    /// **Le chemin entier, d'une instruction de l'invité à son gestionnaire.**
    func testTheGuestDrivesTheQueueAndIsWokenByTheInterrupt() throws {
        let outcome = try run(disk: RV32DiskGuest.disk())
        XCTAssertEqual(outcome.console, "OK\n", """
            « O » est le premier octet du secteur 1, « K » est 'K' + statut : \
            une console vide veut dire que l'interruption n'est jamais arrivée, \
            et une autre lettre que le périphérique a refusé la requête
            """)
        XCTAssertEqual(outcome.machine.disk?.served, UInt64(1),
                       "une requête servie, et une seule")
        XCTAssertEqual(outcome.machine.disk?.refused, UInt64(0))
        XCTAssertFalse(outcome.machine.externalInterruptPending,
                       "la ligne est retombée : le gestionnaire a acquitté")
    }

    /// Et sans disque, la même image ne dit rien.
    ///
    /// Ce n'est pas une redite du test précédent : il montre que la sortie
    /// vient du périphérique et pas du programme. Une fenêtre non décodée
    /// rend zéro, la poignée de main échoue en silence, personne ne sert la
    /// file, aucune interruption n'arrive — et l'invité tourne en rond.
    func testWithoutADiskTheSameGuestNeverGetsPastItsWait() throws {
        let outcome = try run(disk: nil, budget: 300_000)
        XCTAssertEqual(outcome.console, "", "rien à lire, donc rien à dire")
        XCTAssertNil(outcome.machine.disk)
    }

    /// Le nœud de l'arbre suit le disque, et c'est lui qui rend le
    /// périphérique trouvable par un vrai noyau.
    func testTheTreeHandedToTheGuestDeclaresTheDeviceOnlyWithADisk() throws {
        let withDisk = try run(disk: RV32DiskGuest.disk(), budget: 100_000)
        let declared = try DeviceTree.read(withDisk.tree)
        let node = try XCTUnwrap(
            declared.root.child("soc")?.child("virtio_mmio@10001000"),
            "un noyau qui ne trouve pas ce nœud ne sondera jamais la fenêtre")
        XCTAssertEqual(node.property("compatible"), DeviceTree.Value.string("virtio,mmio"))
        XCTAssertEqual(node.property("interrupts"),
                       DeviceTree.Value.cells([UInt32(VirtioBlock.riscv.interruptLine)]))

        let without = try run(disk: nil, budget: 100_000)
        XCTAssertNil(try DeviceTree.read(without.tree)
            .root.child("soc")?.child("virtio_mmio@10001000"),
                     "une carte qui annonce un périphérique absent est une carte qui ment")
    }
}
