import XCTest

@testable import WisqVM

/// Un disque sur la machine rv32 : déclaré, adressable, et qui interrompt.
///
/// **Ce que la page de la feuille de route disait, et pourquoi c'était faux.**
/// « Un virtio-blk parfait n'aurait eu personne à qui parler. » Vrai du noyau
/// de référence, qui n'a pas le pilote — et hors sujet pour la question posée,
/// qui était de savoir si wisq peut en offrir un. Il ne le pouvait pas : la
/// carte ne déclarait aucun périphérique et le cœur n'avait qu'une source
/// d'interruption. Les deux manques sont comblés ; ces tests-ci mesurent le
/// périphérique lui-même, branché sur cette machine-là.
final class RV32DiskTests: XCTestCase {
    private func image(sectors: Int, fill: UInt8 = 0xA5) -> [UInt8] {
        [UInt8](repeating: fill, count: sectors * 512)
    }

    /// Quatre secteurs, chacun rempli de son propre numéro : un secteur lu au
    /// mauvais endroit se voit à l'octet près.
    private func sectorsNumberedFromOne() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4 * 512)
        for sector in 0..<4 {
            for byte in 0..<512 { bytes[sector * 512 + byte] = UInt8(sector + 1) }
        }
        return bytes
    }

    // MARK: - Ce que la carte annonce

    /// **Sans disque, aucun nœud.** Une carte qui annonce un périphérique
    /// absent est une carte qui ment, et le noyau la croirait : il sonderait
    /// une fenêtre vide à chaque démarrage.
    func testTheTreeDeclaresNothingWithoutADisk() throws {
        let tree = try DeviceTree.read(RV32DeviceTree.tree(ramSize: 64 << 20).flatten())
        let soc = try XCTUnwrap(tree.root.child("soc"))
        XCTAssertNil(soc.children.first { $0.name.hasPrefix("virtio") })
    }

    /// **Avec un disque, le nœud dit où et comment prévenir.**
    ///
    /// Les quatre propriétés sont celles que le pilote `virtio_mmio` lit. La
    /// paire `interrupt-parent`/`interrupts` désigne le contrôleur du hart et
    /// le bit onze de `mip` : c'est ce qui remplace un PLIC ici.
    func testTheTreeDeclaresTheDiskAndHowToInterrupt() throws {
        let tree = try DeviceTree.read(
            RV32DeviceTree.tree(ramSize: 64 << 20, disk: true).flatten())
        let node = try XCTUnwrap(
            tree.root.child("soc")?.child("virtio_mmio@10001000"))
        XCTAssertEqual(node.property("compatible"), .string("virtio,mmio"))
        XCTAssertEqual(node.property("reg"), .cells([0, 0x1000_1000, 0, 0x200]))
        XCTAssertEqual(node.property("interrupt-parent"),
                       .cells([RV32DeviceTree.hartInterruptController]))
        XCTAssertEqual(node.property("interrupts"), .cells([11]),
                       "l'externe machine, faute de PLIC")
        // Et le numéro est celui que la machine lève vraiment, pas un jumeau
        // écrit à la main dans l'arbre.
        XCTAssertEqual(UInt32(VirtioBlock.riscv.interruptLine), 11)
        XCTAssertEqual(1 << VirtioBlock.riscv.interruptLine, RV32Core.externalBit)
    }

    /// Et l'arbre avec disque reste un arbre : aligné, relisible, et le reste
    /// inchangé. Un nœud ajouté qui décalerait la mémoire serait pire que pas
    /// de nœud du tout.
    func testAddingTheNodeLeavesTheRestOfTheTreeAlone() throws {
        let without = try DeviceTree.read(RV32DeviceTree.tree(ramSize: 64 << 20).flatten())
        let withDisk = RV32DeviceTree.tree(ramSize: 64 << 20, disk: true).flatten()
        XCTAssertEqual(withDisk.count % 8, 0)
        let parsed = try DeviceTree.read(withDisk)
        XCTAssertEqual(parsed.root.child("memory@80000000"),
                       without.root.child("memory@80000000"))
        XCTAssertEqual(parsed.root.child("cpus"), without.root.child("cpus"))
        XCTAssertEqual(parsed.root.child("soc")?.child("clint@11000000"),
                       without.root.child("soc")?.child("clint@11000000"))
    }

    // MARK: - Ce que la machine porte

    /// La machine prend un disque, et le noyau l'apprend par l'arbre.
    func testAMachineWithADiskDeclaresItToTheGuest() throws {
        let machine = LinuxMachine { _ in }
        machine.attach(disk: image(sectors: 8))
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))

        let tree = try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
        XCTAssertNotNil(tree.root.child("soc")?.child("virtio_mmio@10001000"),
                        "le disque doit être branché **avant** que l'arbre soit posé")
        XCTAssertEqual(machine.disk?.sectors, 8)
    }

    /// **La fenêtre répond.** C'est le premier octet du dialogue : le pilote
    /// lit le nombre magique, et s'il ne le trouve pas il passe son chemin
    /// sans un mot.
    func testTheWindowAnswersTheMagicNumber() {
        let machine = LinuxMachine { _ in }
        XCTAssertEqual(machine.mmioLoad(0x1000_1000), 0,
                       "sans disque, la fenêtre est muette")

        machine.attach(disk: image(sectors: 4))
        XCTAssertEqual(machine.mmioLoad(0x1000_1000), 0x7472_6976, "« virt »")
        XCTAssertEqual(machine.mmioLoad(0x1000_1004), 2, "transport version 2")
        XCTAssertEqual(machine.mmioLoad(0x1000_1008), 2, "périphérique bloc")
        // La capacité, en secteurs de 512 octets, sur deux registres.
        XCTAssertEqual(machine.mmioLoad(0x1000_1100), 4)
    }

    /// Et la fenêtre s'arrête où elle le dit : un octet plus loin appartient à
    /// quelqu'un d'autre.
    func testTheWindowEndsWhereItSaysItDoes() {
        let machine = LinuxMachine { _ in }
        machine.attach(disk: image(sectors: 4))
        XCTAssertEqual(
            machine.mmioLoad(UInt32(VirtioBlock.riscv.base + VirtioBlock.riscv.span)), 0,
            "hors de la fenêtre, le périphérique ne répond pas")
    }

    // MARK: - L'interruption

    /// **Le périphérique lève `mip` bit 11, et l'acquittement le baisse.**
    ///
    /// C'est la moitié que la tranche précédente a posée sans personne pour
    /// s'en servir. Sans elle, un invité qui attend sa requête dort pour
    /// toujours.
    ///
    /// La requête est **vraie** : les anneaux sont posés dans la mémoire de
    /// l'invité et la file est sonnée par une écriture MMIO, comme le pilote
    /// le fait. Un raccourci qui lèverait la ligne à la main ne mesurerait que
    /// lui-même.
    func testARealRequestRaisesTheExternalInterruptAndTheAcknowledgementClearsIt() throws {
        let machine = LinuxMachine { _ in }
        machine.attach(disk: sectorsNumberedFromOne())
        let queue = VirtioQueue(base: UInt64(RV32Core.ramBase))
        let disk = try XCTUnwrap(machine.disk)
        queue.start(disk, machine.guestMemory)
        XCTAssertFalse(machine.externalInterruptPending, "rien à signaler")

        // Lire le secteur deux dans un tampon de l'invité.
        let buffer = queue.scratch + 0x1000
        try queue.request(machine.guestMemory, kind: 0, sector: 2,
                          buffer: .init(at: buffer, length: 512, writable: true))
        _ = machine.mmioStore(UInt32(VirtioBlock.riscv.base + 0x050), 0)  // QueueNotify

        XCTAssertEqual(try queue.status(machine.guestMemory), 0, "la requête a réussi")
        XCTAssertEqual(try machine.guestMemory.read(buffer, 1), 3,
                       "le troisième secteur est rempli de trois")
        XCTAssertTrue(machine.externalInterruptPending,
                      "servie, la requête lève la ligne")

        // Le pilote acquitte en écrivant le bit dans InterruptACK.
        _ = machine.mmioStore(UInt32(VirtioBlock.riscv.base + 0x064), 1)
        XCTAssertFalse(machine.externalInterruptPending,
                       "acquittée, la ligne retombe")
    }

    /// Et une écriture arrive vraiment sur le disque, dans le bon secteur.
    func testAWriteReachesTheDisk() throws {
        let machine = LinuxMachine { _ in }
        machine.attach(disk: sectorsNumberedFromOne())
        let queue = VirtioQueue(base: UInt64(RV32Core.ramBase))
        let disk = try XCTUnwrap(machine.disk)
        queue.start(disk, machine.guestMemory)

        let buffer = queue.scratch + 0x1000
        for byte in 0..<512 {
            try machine.guestMemory.write(buffer + UInt64(byte), 1, 0x5A)
        }
        try queue.request(machine.guestMemory, kind: 1, sector: 1,
                          buffer: .init(at: buffer, length: 512, writable: false))
        _ = machine.mmioStore(UInt32(VirtioBlock.riscv.base + 0x050), 0)

        XCTAssertEqual(try queue.status(machine.guestMemory), 0)
        XCTAssertEqual(disk.image[512], 0x5A, "le second secteur a été écrit")
        XCTAssertEqual(disk.image[511], 1, "et le premier n'a pas bougé")
    }

    /// Retirer le disque retire la ligne avec lui : une interruption qui reste
    /// levée sans personne pour la servir bloque l'invité dans son
    /// gestionnaire.
    func testDetachingTheDiskLowersTheLine() throws {
        let machine = LinuxMachine { _ in }
        machine.attach(disk: sectorsNumberedFromOne())
        let queue = VirtioQueue(base: UInt64(RV32Core.ramBase))
        queue.start(try XCTUnwrap(machine.disk), machine.guestMemory)
        try queue.request(machine.guestMemory, kind: 0, sector: 0,
                          buffer: .init(at: queue.scratch + 0x1000, length: 512, writable: true))
        _ = machine.mmioStore(UInt32(VirtioBlock.riscv.base + 0x050), 0)
        XCTAssertTrue(machine.externalInterruptPending)

        machine.detachDisk()
        XCTAssertFalse(machine.externalInterruptPending)
        XCTAssertEqual(machine.mmioLoad(0x1000_1000), 0)
    }

    // MARK: - L'instantané

    /// **Une machine sauvée porte son disque, et une machine sans disque n'en
    /// invente pas un.**
    ///
    /// L'invité écrit dedans ; sans ça, reprendre une session rendrait un
    /// disque revenu à ce qu'il était au démarrage, ce qui est pire que pas de
    /// disque du tout.
    func testTheSnapshotCarriesTheDiskAndItsAbsence() throws {
        let machine = LinuxMachine { _ in }
        var bytes = image(sectors: 4, fill: 0)
        bytes[600] = 0x77
        machine.attach(disk: bytes)
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        let saved = machine.snapshot()

        let restored = LinuxMachine { _ in }
        try restored.restore(saved)
        XCTAssertEqual(restored.disk?.image[600], 0x77)
        XCTAssertEqual(restored.disk?.sectors, 4)

        // Et l'inverse : reprendre une machine sans disque en retire un.
        let plain = LinuxMachine { _ in }
        try plain.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        let withDisk = LinuxMachine { _ in }
        withDisk.attach(disk: image(sectors: 4))
        try withDisk.restore(plain.snapshot())
        XCTAssertNil(withDisk.disk, "l'instantané ne portait pas de disque")
    }

    /// Un instantané d'avant le disque se reprend encore.
    ///
    /// C'est ce qui distingue une évolution d'une rupture : les machines déjà
    /// sauvées sur les téléphones ne portent pas la section du disque, et
    /// refuser de les reprendre coûterait leur session à des gens pour une
    /// fonctionnalité qu'ils n'ont pas demandée.
    func testASnapshotFromBeforeTheDiskStillResumes() throws {
        let old = LinuxMachine { _ in }
        try old.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        old.run(instructionBudget: 32)
        let saved = old.snapshot()

        let resumed = LinuxMachine { _ in }
        XCTAssertNoThrow(try resumed.restore(saved))
        XCTAssertNil(resumed.disk)
    }
}
