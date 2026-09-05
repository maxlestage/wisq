import XCTest

@testable import WisqVM

/// **La sélection automatique, du côté où elle devient une machine.**
///
/// Maxime : « la bonne par rapport à l'image sera automatiquement
/// sélectionnée ». `GuestArchitectureTests` tient la première moitié — lire le
/// fichier et en nommer le cœur. Celle-ci tient la seconde : que le cœur nommé
/// mène vraiment à la machine correspondante, et que le protocole commun aux
/// deux ne perde rien en route.
final class GuestMachineTests: XCTestCase {
    // MARK: - La fabrique

    /// Chaque cœur donne **sa** machine, et pas l'autre.
    ///
    /// C'est le seul endroit où le choix se matérialise. S'il se trompait, un
    /// `bzImage` partirait sur un interprète RISC-V et échouerait à la
    /// première instruction, en disant quelque chose sur le RISC-V — un
    /// message exact et parfaitement trompeur.
    func testEachCoreBuildsItsOwnMachine() {
        let riscv = GuestMachineFactory.make(
            for: .riscv32, ramSizeBytes: 64 << 20, onOutput: { _ in })
        XCTAssertTrue(riscv is LinuxMachine, "attendu la machine RISC-V")
        XCTAssertFalse(riscv is X86Machine)

        let pc = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: 256 << 20, onOutput: { _ in })
        XCTAssertTrue(pc is X86Machine, "attendu la machine PC")
        XCTAssertFalse(pc is LinuxMachine)
    }

    /// La mémoire demandée est celle que la machine a — **par le protocole**,
    /// pas par le champ concret de chacune. Les deux ne portent pas le même
    /// type (`UInt32` d'un côté, `Int` de l'autre) et la conversion est
    /// justement l'endroit où une taille se perd.
    func testTheMemoryAskedForIsTheMemoryGiven() {
        XCTAssertEqual(
            GuestMachineFactory.make(
                for: .riscv32, ramSizeBytes: 64 << 20, onOutput: { _ in }).ramSizeBytes,
            64 << 20)
        XCTAssertEqual(
            GuestMachineFactory.make(
                for: .x86_64, ramSizeBytes: 192 << 20, onOutput: { _ in }).ramSizeBytes,
            192 << 20)
    }

    /// **Le point d'extension sert au RISC-V, et à lui seul.**
    ///
    /// L'application embarque deux interprètes rv32 — un en Swift, un en Rust
    /// — et c'est un drapeau de compilation qui décide lequel part. Si la
    /// fabrique ignorait celui qu'on lui passe, l'application construite avec
    /// le cœur Rust ferait tourner le cœur Swift sans que rien ne le dise :
    /// même sortie, huit pour cent plus lent, et aucun symptôme à chercher.
    func testTheRiscVMakerIsUsedForRiscVAndNowhereElse() {
        let asked = Counter()
        let riscv = GuestMachineFactory.make(
            for: .riscv32, ramSizeBytes: 32 << 20, onOutput: { _ in },
            riscv: { size, output in
                asked.record(size)
                return LinuxMachine(ramSize: UInt32(clamping: size), onOutput: output)
            })
        XCTAssertEqual(asked.sizes, [32 << 20])
        XCTAssertTrue(riscv is LinuxMachine)

        _ = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: 256 << 20, onOutput: { _ in },
            riscv: { size, output in
                asked.record(size)
                return LinuxMachine(ramSize: UInt32(clamping: size), onOutput: output)
            })
        XCTAssertEqual(asked.sizes, [32 << 20], "le cœur PC ne doit pas passer par là")
    }

    // MARK: - Ce que le protocole transporte

    /// **Un disque en mémoire donné à la machine RISC-V est refusé, et nommé.**
    ///
    /// Le chargeur RISC-V place un noyau et un arbre de périphériques ; un
    /// initramfs n'y a aucun champ où être annoncé. L'accepter en silence
    /// donnerait un démarrage qui va jusqu'au bout puis panique faute de
    /// racine — un symptôme à quatre milliards d'instructions de sa cause.
    func testTheRiscVMachineRefusesARamdiskByName() throws {
        let machine: GuestMachine = LinuxMachine(ramSize: 32 << 20, onOutput: { _ in })
        XCTAssertThrowsError(
            try machine.load(
                kernelImage: Data([0x13, 0x00, 0x00, 0x00]), commandLine: nil,
                initialRamdisk: Data([0x1F, 0x8B]))
        ) { error in
            XCTAssertEqual(
                error as? GuestMachineRefusal, .noRamdiskHere(architecture: "RISC-V 32 bits"))
        }
    }

    /// Et le refus arrive **avant** le chargement, pas après.
    ///
    /// La distinction est mesurable : la même image vide, sans disque, échoue
    /// pour une autre raison. Si la garde était placée après le chargement,
    /// c'est cette autre raison qui sortirait — et elle enverrait chercher du
    /// côté de la taille de l'image, qui n'est pas le problème.
    func testTheRamdiskRefusalComesBeforeAnythingIsLoaded() {
        let machine: GuestMachine = LinuxMachine(ramSize: 32 << 20, onOutput: { _ in })
        XCTAssertThrowsError(
            try machine.load(kernelImage: Data(), commandLine: nil, initialRamdisk: Data([0x1F]))
        ) { XCTAssertEqual($0 as? GuestMachineRefusal, .noRamdiskHere(architecture: "RISC-V 32 bits")) }
        XCTAssertThrowsError(
            try machine.load(kernelImage: Data(), commandLine: nil, initialRamdisk: nil)
        ) { XCTAssertEqual($0 as? LinuxMachineError, .imageTooLarge) }
    }

    /// **La machine PC, elle, prend le disque** — et le protocole le lui
    /// transmet vraiment. Vérifié dans les paramètres de démarrage que le
    /// noyau lira : adresse et taille, aux offsets 0x218 et 0x21C.
    func testThePCMachineReceivesTheRamdiskThroughTheProtocol() throws {
        let machine = X86Machine(ramSize: 128 << 20, onOutput: { _ in })
        let disk = Data([UInt8](repeating: 0xAB, count: 4096))
        try (machine as GuestMachine).load(
            kernelImage: X86LocalMachineTests.kernel([0xF4]), commandLine: nil,
            initialRamdisk: disk)

        let parameters = machine.core.registers[6]
        let memory = try XCTUnwrap(machine.core.memory)
        let address = try memory.read(parameters + 0x218, 4)
        XCTAssertEqual(try memory.read(parameters + 0x21C, 4), UInt64(disk.count))
        XCTAssertNotEqual(address, 0, "le noyau n'apprendrait jamais que le disque est là")
        XCTAssertEqual(try memory.read(address, 1), 0xAB, "et ce n'est pas le bon disque")
    }

    /// Le même chargement **sans** disque n'annonce pas de disque. Sans cette
    /// moitié, le test au-dessus passerait sur un chargeur qui écrirait
    /// n'importe quoi à ces deux offsets.
    func testWithoutARamdiskThePCMachineAnnouncesNone() throws {
        let machine = X86Machine(ramSize: 128 << 20, onOutput: { _ in })
        try (machine as GuestMachine).load(
            kernelImage: X86LocalMachineTests.kernel([0xF4]), commandLine: nil,
            initialRamdisk: nil)
        let parameters = machine.core.registers[6]
        let memory = try XCTUnwrap(machine.core.memory)
        XCTAssertEqual(try memory.read(parameters + 0x218, 4), 0)
        XCTAssertEqual(try memory.read(parameters + 0x21C, 4), 0)
    }

    // MARK: - Ce que le protocole rend

    /// **Un refus du cœur traverse le protocole avec son nom.**
    ///
    /// C'est la seule sortie que le RISC-V n'a pas, donc la seule que la
    /// traduction pouvait perdre. La perdre transformerait « l'instruction
    /// telle n'est pas écrite » en « arrêtée », et cette phrase-là n'aide
    /// personne à savoir quelle brique poser ensuite.
    func testAFaultKeepsItsNameThroughTheProtocol() throws {
        let machine = X86Machine(ramSize: 128 << 20, onOutput: { _ in })
        // `UD2` : une instruction volontairement invalide. Sans table
        // d'interruptions, le cœur n'a nulle part où livrer la faute.
        try machine.load(kernelImage: X86LocalMachineTests.kernel([0x0F, 0x0B]))
        let outcome = (machine as GuestMachine).runGuest(instructionBudget: 1000)
        guard case .faulted(let reason) = outcome else {
            return XCTFail("attendu une faute nommée, reçu \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty, "une faute sans nom vaut « arrêtée »")
    }

    /// Une extinction reste une extinction, et le compteur d'instructions
    /// traverse lui aussi.
    func testAPowerOffCrossesOverAndSoDoesTheCount() throws {
        let machine = X86Machine(ramSize: 128 << 20, onOutput: { _ in })
        try machine.load(kernelImage: X86LocalMachineTests.kernel([0xF4]))
        let guest: GuestMachine = machine
        XCTAssertEqual(guest.runGuest(instructionBudget: 1000), .powerOff)
        XCTAssertEqual(guest.retiredInstructions, machine.retiredInstructions)
        XCTAssertGreaterThan(guest.retiredInstructions, 0)
    }

    /// Ce que l'invité écrit arrive à qui regarde, **par la fabrique** : c'est
    /// le chemin que l'application emprunte, et la fermeture de sortie y passe
    /// par un argument de plus qu'ailleurs.
    func testTheOutputClosureSurvivesTheFactory() throws {
        let collected = X86LocalMachineTests.Collector()
        let machine = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: 128 << 20, onOutput: { collected.append($0) })
        try machine.load(
            kernelImage: X86LocalMachineTests.kernel(X86LocalMachineTests.printing("wisq")),
            commandLine: nil, initialRamdisk: nil)
        XCTAssertEqual(machine.runGuest(instructionBudget: 1000), .powerOff)
        XCTAssertEqual(collected.text, "wisq")
    }

    /// Compte les tailles qu'on a demandées au fabricant rv32.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int] = []
        func record(_ size: Int) {
            lock.lock()
            recorded.append(size)
            lock.unlock()
        }
        var sizes: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }
    // MARK: - Le disque

    /// **La machine RISC-V prend un disque, et le nœud suit.**
    ///
    /// Elle le refusait, et le refus était juste : la carte n'avait ni
    /// contrôleur d'interruption pour un périphérique, ni moyen de le déclarer.
    /// Les deux manques ont été comblés. Ce test tient le sens de ce
    /// changement — le disque est là **et** l'arbre remis à l'invité le dit,
    /// parce qu'un disque qu'aucun arbre n'annonce n'existe pas.
    func testTheRiscVMachineTakesADiskAndDeclaresIt() throws {
        let machine = LinuxMachine(ramSize: 32 << 20, onOutput: { _ in })
        XCTAssertNil(machine.disk, "rien avant qu'on en donne un")
        try (machine as GuestMachine).attachDisk(Data(repeating: 0x5A, count: 4096))
        XCTAssertEqual(machine.disk?.sectors, 8)
        try machine.load(kernelImage: Data(repeating: 0, count: 64))
        XCTAssertNotNil(
            try DeviceTree.read(machine.deviceTreeHandedToTheGuest)
                .root.child("soc")?.child("virtio_mmio@10001000"),
            "un noyau qui ne trouve pas ce nœud ne sondera jamais la fenêtre")
    }

    /// **Les deux machines rendent compte de leur disque**, et de la même
    /// façon : c'est ce qui permet à l'application de le dire sans savoir
    /// laquelle tourne.
    func testBothMachinesReportWhatTheirDiskSaw() throws {
        let riscv = LinuxMachine(ramSize: 32 << 20, onOutput: { _ in })
        XCTAssertNil(riscv.diskActivity, "pas de disque, rien à rapporter")
        try (riscv as GuestMachine).attachDisk(Data(repeating: 0, count: 4096))
        XCTAssertEqual(riscv.diskActivity?.served, 0)
        XCTAssertEqual(riscv.diskActivity?.refused, 0)

        let pc = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertNil(pc.diskActivity)
        try (pc as GuestMachine).attachDisk(Data(repeating: 0, count: 4096))
        XCTAssertEqual(pc.diskActivity?.served, 0)
    }

    /// Et le refus qui reste **porte sa phrase**, pas seulement son cas :
    /// c'est ce que l'application affiche.
    func testTheRefusalsCarryTheirOwnSentence() throws {
        let ramdisk = try XCTUnwrap(
            GuestMachineRefusal.noRamdiskHere(architecture: "RISC-V 32 bits").errorDescription)
        XCTAssertTrue(ramdisk.contains("initramfs"), ramdisk)
    }

    /// La machine PC, elle, le prend — et le voit ensuite.
    func testThePCMachineTakesADiskAndKeepsIt() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertNil(machine.disk, "rien avant qu'on en donne un")
        try (machine as GuestMachine).attachDisk(Data(repeating: 0xA5, count: 4096))
        XCTAssertEqual(machine.disk?.sectors, 8)
        XCTAssertEqual(machine.disk?.image.first, 0xA5)
    }
}
