import Foundation
import XCTest

@testable import WisqVM

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
    // MARK: - La carte que le programme se donne

    private static let device: UInt32 = 0x1000_1000
    private static let uart: UInt32 = 0x1000_0000

    /// Des pages rondes, loin les unes des autres, dans la RAM de l'invité.
    /// Un débordement se voit alors plutôt que de tomber dans le voisin.
    private static let descriptors: UInt32 = 0x8000_1000
    private static let available: UInt32 = 0x8000_2000
    private static let used: UInt32 = 0x8000_3000
    private static let header: UInt32 = 0x8000_4000
    private static let buffer: UInt32 = 0x8000_5000
    private static let statusByte: UInt32 = 0x8000_6000
    private static let seen: UInt32 = 0x8000_7000

    /// Le gestionnaire vit à une adresse fixe, et le programme principal est
    /// complété de `nop` jusque-là. Calculer l'adresse depuis la longueur du
    /// code marcherait aussi, et se casserait à chaque instruction ajoutée.
    private static let handlerOffset = 0x200

    /// Le premier octet du secteur 1. Choisi pour être lisible dans la
    /// console : une valeur qu'on reconnaît vaut mieux qu'un octet à décoder.
    private static let mark = UInt8(ascii: "O")

    // MARK: - Le programme

    // Les registres, nommés une fois pour que le programme se lise.
    private static let dev = 1, tty = 2, tmp = 5, feat = 6
    private static let hdr = 7, desc = 8, buf = 9, ring = 12
    private static let stat = 11, flag = 13, got = 14, byte = 15

    private static func program() -> [UInt32] {
        typealias Asm = RV32Asm
        var code: [UInt32] = [
            Asm.lui(dev, device >> 12),
            Asm.lui(tty, uart >> 12),

            // Le vecteur de trappe, en mode direct : les deux bits du bas à
            // zéro veulent dire « toutes les causes au même endroit ».
            Asm.lui(tmp, 0x80000),
            Asm.addi(tmp, tmp, Int32(handlerOffset)),
            Asm.csrw(Asm.mtvec, tmp),

            // N'autoriser que l'externe. Le timer partage le même
            // gestionnaire, et le laisser passer ferait entrer le programme
            // dedans avant que ses registres soient prêts.
            Asm.addi(tmp, 0, 1),
            Asm.slli(tmp, tmp, 11),
            Asm.csrw(Asm.mie, tmp),
            Asm.addi(tmp, 0, 8),
            Asm.csrw(Asm.mstatus, tmp),

            // La poignée de main, dans son ordre. Se tromper d'une écriture
            // fait dire au vrai noyau « does not support VIRTIO_F_VERSION_1 »
            // et le disque n'existe jamais.
            Asm.sw(0, 0x070, dev),                 // remise à zéro
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 0x070, dev),               // ACKNOWLEDGE
            Asm.addi(tmp, 0, 3),
            Asm.sw(tmp, 0x070, dev),               // | DRIVER
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 0x014, dev),               // les bits 32 à 63…
            Asm.sw(tmp, 0x024, dev),
            Asm.lw(feat, 0x010, dev),
            Asm.sw(feat, 0x020, dev),
            Asm.addi(tmp, 0, 11),
            Asm.sw(tmp, 0x070, dev),               // | FEATURES_OK
            Asm.sw(0, 0x030, dev),                 // la file zéro
            Asm.addi(tmp, 0, 8),
            Asm.sw(tmp, 0x038, dev),
            Asm.lui(feat, descriptors >> 12),
            Asm.sw(feat, 0x080, dev),
            Asm.sw(0, 0x084, dev),
            Asm.lui(feat, available >> 12),
            Asm.sw(feat, 0x090, dev),
            Asm.sw(0, 0x094, dev),
            Asm.lui(feat, used >> 12),
            Asm.sw(feat, 0x0A0, dev),
            Asm.sw(0, 0x0A4, dev),
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 0x044, dev),               // la file est prête
            Asm.addi(tmp, 0, 15),
            Asm.sw(tmp, 0x070, dev),               // | DRIVER_OK

            // L'en-tête : lire, secteur 1.
            Asm.lui(hdr, header >> 12),
            Asm.sw(0, 0, hdr),
            Asm.sw(0, 4, hdr),
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 8, hdr),
            Asm.sw(0, 12, hdr),

            // L'octet de statut, mis à une valeur qui n'est ni réussite ni
            // échec : sans ça, « zéro » pourrait vouloir dire « jamais écrit ».
            Asm.lui(stat, statusByte >> 12),
            Asm.addi(tmp, 0, -1),
            Asm.sb(tmp, 0, stat),

            // Les trois descripteurs. `flags` et `next` sont deux demi-mots
            // voisins, écrits d'un seul `sw` : `next` en haut, `flags` en bas.
            Asm.lui(desc, descriptors >> 12),
            Asm.sw(hdr, 0, desc),
            Asm.sw(0, 4, desc),
            Asm.addi(tmp, 0, 16),
            Asm.sw(tmp, 8, desc),
            Asm.lui(tmp, 0x10),                    // next = 1
            Asm.addi(tmp, tmp, 1),                 // flags = NEXT
            Asm.sw(tmp, 12, desc),

            Asm.lui(buf, buffer >> 12),
            Asm.sw(buf, 16, desc),
            Asm.sw(0, 20, desc),
            Asm.addi(tmp, 0, 512),
            Asm.sw(tmp, 24, desc),
            Asm.lui(tmp, 0x20),                    // next = 2
            Asm.addi(tmp, tmp, 3),                 // flags = NEXT | WRITE
            Asm.sw(tmp, 28, desc),

            Asm.sw(stat, 32, desc),
            Asm.sw(0, 36, desc),
            Asm.addi(tmp, 0, 1),
            Asm.sw(tmp, 40, desc),
            Asm.addi(tmp, 0, 2),                   // flags = WRITE, pas de suite
            Asm.sw(tmp, 44, desc),

            // L'anneau des disponibles : l'entrée d'abord, puis l'index qui la
            // publie. L'inverse offrirait au périphérique une entrée qui n'est
            // pas encore écrite.
            Asm.lui(ring, available >> 12),
            Asm.sw(0, 4, ring),
            Asm.lui(tmp, 0x10),                    // idx = 1, flags = 0
            Asm.sw(tmp, 0, ring),

            Asm.lui(flag, seen >> 12),
            Asm.sw(0, 0, flag),

            // On sonne. Le périphérique sert, et lève la ligne.
            Asm.sw(0, 0x050, dev),

            // Et on attend le gestionnaire. **C'est ici que le test tient** :
            // sans interruption livrée, le programme ne sort jamais de ces
            // deux instructions et la console reste vide.
            Asm.lw(got, 0, flag),
            Asm.beq(got, 0, -4),

            // Ce que le disque a donné, et ce que le périphérique en a dit.
            Asm.lbu(byte, 0, buf),
            Asm.sb(byte, 0, tty),
            Asm.lbu(byte, 0, stat),
            Asm.addi(byte, byte, 0x4B),            // 'K' — et seulement si zéro
            Asm.sb(byte, 0, tty),
            Asm.addi(byte, 0, 10),
            Asm.sb(byte, 0, tty),                  // le saut de ligne vide la console
            Asm.beq(0, 0, 0),                      // et on s'arrête là, sans parler
        ]
        XCTAssertLessThan(code.count * 4, handlerOffset,
                          "le programme principal déborde sur le gestionnaire")
        while code.count * 4 < handlerOffset { code.append(Asm.addi(0, 0, 0)) }
        code += [
            // Le gestionnaire. Lire le statut d'interruption puis l'acquitter
            // est ce qui fait retomber la ligne ; poser le drapeau est ce qui
            // laisse le programme principal repartir.
            Asm.lw(got, 0x060, dev),
            Asm.sw(got, 0x064, dev),
            Asm.addi(got, 0, 1),
            Asm.sw(got, 0, flag),
            Asm.mret,
        ]
        return code
    }

    /// Un disque dont chaque secteur porte sa propre marque, pour qu'une
    /// lecture au mauvais endroit se voie à l'octet près.
    private static func disk(sectors: Int = 8) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: sectors * 512)
        for sector in 0..<sectors {
            for offset in 0..<512 { image[sector * 512 + offset] = UInt8(0x30 + sector) }
        }
        for offset in 0..<512 { image[512 + offset] = mark }
        return image
    }

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
        try machine.load(kernelImage: RV32Asm.image(Self.program()))
        let tree = machine.deviceTreeHandedToTheGuest
        _ = machine.run(instructionBudget: budget)
        return Run(console: console.text, machine: machine, tree: tree)
    }

    // MARK: - Ce que ça prouve

    /// **Le chemin entier, d'une instruction de l'invité à son gestionnaire.**
    func testTheGuestDrivesTheQueueAndIsWokenByTheInterrupt() throws {
        let outcome = try run(disk: Self.disk())
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
        let withDisk = try run(disk: Self.disk(), budget: 100_000)
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
