import XCTest

@testable import WisqVM

/// Le disque dans la machine, et le disque dans l'instantané.
///
/// **Pourquoi ces tests existent.** Le périphérique virtio et le bus PCI
/// existaient, et rien ne les branchait à `X86Machine` : ils ne vivaient que
/// dans la mesure de démarrage. Une machine qui passe en arrière-plan sauve
/// son cœur, sa mémoire et ses périphériques hérités ; si le disque n'y est
/// pas, l'invité repris retrouve une file dont il croit connaître les
/// adresses, un index de disponibles qu'il croit avoir avancé, et un
/// périphérique qui n'a jamais rien vu. Il n'échoue pas tout de suite — il
/// échoue à la requête suivante, très loin de la reprise.
///
/// **Et l'image se sauve avec.** C'est le disque : une reprise qui rendrait
/// les registres sans les octets rendrait une machine qui se croit à jour et
/// lit l'image du début. L'encodage par longueur de suites de zéros, celui de
/// la RAM, suffit : une image ext4 de seize mébioctets fraîchement formatée
/// n'a que treize pages non nulles sur quatre mille quatre-vingt-seize.
final class X86DiskSnapshotTests: XCTestCase {
    /// Une image reconnaissable : chaque secteur rempli de son propre numéro,
    /// modulo 251 pour que deux secteurs voisins ne se ressemblent pas.
    static func image(sectors: Int = 64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: sectors * 512)
        for sector in 0..<sectors {
            for byte in 0..<512 { bytes[sector * 512 + byte] = UInt8((sector + 1) % 251) }
        }
        return bytes
    }

    static func machine(withDisk: Bool = true) -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        if withDisk { machine.attach(disk: image()) }
        return machine
    }

    /// La poignée de main du pilote, puis une lecture servie : c'est le seul
    /// moyen d'obtenir des registres qui ne soient pas ceux du départ.
    static func driveOneRequest(_ machine: X86Machine) throws {
        let memory = try XCTUnwrap(machine.core.memory)
        let disk = try XCTUnwrap(machine.disk)
        X86VirtioBlockTests.start(disk, memory)
        try X86VirtioBlockTests.request(memory, kind: 0, sector: 3,
                                        buffer: .init(at: 0x5000, length: 512, writable: true))
        disk.write(0x050, 4, 0, memory)
    }

    // MARK: - Le disque dans la machine

    /// Sans disque, la machine le dit — et son instantané ne prétend pas le
    /// contraire.
    func testAMachineWithoutADiskStaysWithoutOne() throws {
        let machine = Self.machine(withDisk: false)
        XCTAssertNil(machine.disk)
        let restored = Self.machine(withDisk: true)
        try restored.restore(machine.snapshot())
        XCTAssertNil(restored.disk, "reprendre une machine sans disque en retire un")
    }

    /// Un disque branché répond par la mémoire, comme le pilote l'atteindra.
    func testAnAttachedDiskAnswersThroughMemory() throws {
        let machine = Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        XCTAssertEqual(try memory.read(X86VirtioBlock.base, 4), 0x7472_6976, "« virt »")
        XCTAssertNotNil(memory.bus, "et le bus est là aussi")
        XCTAssertEqual(machine.disk?.sectors, 64)
    }

    // MARK: - L'aller-retour

    /// L'image, octet par octet — y compris ce qu'une requête vient d'y écrire.
    func testTheImageComesBackIncludingWhatWasWrittenThroughTheQueue() throws {
        let machine = Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let disk = try XCTUnwrap(machine.disk)
        X86VirtioBlockTests.start(disk, memory)
        for byte in 0..<UInt64(512) { try memory.write(0x5000 + byte, 1, 0x77) }
        try X86VirtioBlockTests.request(memory, kind: 1, sector: 2,
                                        buffer: .init(at: 0x5000, length: 512, writable: false))
        disk.write(0x050, 4, 0, memory)
        XCTAssertEqual(disk.image[1024], 0x77, "le secteur deux a bien changé")

        let restored = Self.machine(withDisk: false)
        try restored.restore(machine.snapshot())
        XCTAssertEqual(restored.disk?.image, disk.image)
    }

    /// Chaque registre du périphérique, redemandé après l'aller-retour.
    func testEveryRegisterOfTheDiskComesBack() throws {
        let machine = Self.machine()
        try Self.driveOneRequest(machine)
        let before = try XCTUnwrap(machine.disk)
        XCTAssertEqual(before.served, 1, "la mesure part d'un état non vierge")

        let restored = Self.machine(withDisk: false)
        try restored.restore(machine.snapshot())
        let after = try XCTUnwrap(restored.disk)

        XCTAssertEqual(after.status, before.status, "l'état de la poignée de main")
        XCTAssertEqual(after.driverFeatures, before.driverFeatures)
        XCTAssertEqual(after.queueSize, before.queueSize)
        XCTAssertEqual(after.queueReady, before.queueReady)
        XCTAssertEqual(after.descriptorTable, before.descriptorTable)
        XCTAssertEqual(after.availableRing, before.availableRing)
        XCTAssertEqual(after.usedRing, before.usedRing)
        XCTAssertEqual(after.queuePageNumber, before.queuePageNumber)
        XCTAssertEqual(after.interruptStatus, before.interruptStatus)
        XCTAssertEqual(after.nextAvailable, before.nextAvailable, "l'index des disponibles")
        XCTAssertEqual(after.nextUsed, before.nextUsed, "et celui des servies")
        XCTAssertEqual(after.served, before.served)
        XCTAssertEqual(after.refused, before.refused)
    }

    /// Le bus aussi : sans son adresse et sa fenêtre, la configuration se relit
    /// depuis le mauvais registre, et le pilote conclut qu'il n'y a rien.
    func testTheBusComesBackToo() throws {
        let machine = Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus)
        bus.writeAddress(0x8000_1810)  // slot 3, BAR 0
        bus.writeConfiguration(0x1041, 2, 0)  // la commande : ports + maîtrise
        bus.writeAddress(0x8000_1810)
        bus.writeConfiguration(0x0000_2000, 4, 0)  // et une fenêtre ailleurs

        let restored = Self.machine(withDisk: false)
        try restored.restore(machine.snapshot())
        let after = try XCTUnwrap(restored.core.memory?.bus)
        XCTAssertEqual(after.address, bus.address)
        XCTAssertEqual(after.command, bus.command)
        XCTAssertEqual(after.window, bus.window)
        XCTAssertEqual(after.interruptLine, bus.interruptLine)
        XCTAssertTrue(after.storage === restored.disk, "et il pointe le disque repris")
    }

    /// **Une file en vol reprend là où elle s'est arrêtée.** C'est le cas qui
    /// distingue un instantané qui rend des nombres d'un instantané qui rend
    /// une machine : la seconde requête doit être servie comme la deuxième,
    /// pas comme la première.
    func testAQueueInFlightResumesWhereItStopped() throws {
        let machine = Self.machine()
        try Self.driveOneRequest(machine)

        let restored = Self.machine(withDisk: false)
        try restored.restore(machine.snapshot())
        let memory = try XCTUnwrap(restored.core.memory)
        let disk = try XCTUnwrap(restored.disk)

        // La seconde entrée de l'anneau des disponibles, puis son index.
        try memory.write(X86VirtioBlockTests.available + 6, 2, 0)
        try memory.write(X86VirtioBlockTests.available + 2, 2, 2)
        try memory.write(X86VirtioBlockTests.scratch + 8, 8, 1)  // le secteur un
        try memory.write(X86VirtioBlockTests.scratch + 0x800, 1, 0xFF)
        disk.write(0x050, 4, 0, memory)

        XCTAssertEqual(disk.served, 2, "deux servies en tout, pas une")
        XCTAssertEqual(try memory.read(X86VirtioBlockTests.used + 2, 2), 2)
        XCTAssertEqual(try memory.read(0x5000, 1), 2, "le secteur un porte des 2")
    }

    /// **Un instantané d'avant le disque se reprend quand même.** Le disque
    /// est la dernière section ; son absence est la seule chose qui distingue
    /// un instantané d'hier, et refuser de le lire perdrait les machines déjà
    /// sauvées sur les téléphones.
    func testASnapshotWithoutTheDiskSectionStillRestores() throws {
        let machine = Self.machine(withDisk: false)
        machine.core.registers[0] = 0x1234_5678
        let old = machine.snapshot()

        let restored = Self.machine(withDisk: true)
        try restored.restore(old)
        XCTAssertEqual(restored.core.registers[0], 0x1234_5678)
        XCTAssertNil(restored.disk)
    }

    /// **Et une reprise qui échoue ne laisse pas un disque à moitié posé.**
    ///
    /// La coupure est de quatre octets, pas d'un tiers : il faut que la
    /// lecture aille jusqu'au bout du disque et **échoue ensuite**, sur le
    /// bus. Une coupure large fauterait dans la RAM, bien avant que le disque
    /// n'existe, et le test passerait sans jamais avoir visité le chemin
    /// qu'il prétend garder — ce qu'un sabotage a montré du premier jet.
    func testAFailedRestoreLeavesTheDiskAlone() throws {
        let machine = Self.machine()
        try Self.driveOneRequest(machine)
        let disk = try XCTUnwrap(machine.disk)
        let served = disk.served
        var rubbish = [UInt8](machine.snapshot())
        rubbish.removeLast(4)  // la dernière moitié du bus
        XCTAssertThrowsError(try machine.restore(Data(rubbish)))
        XCTAssertTrue(machine.disk === disk, "le disque d'avant est toujours là")
        XCTAssertEqual(machine.disk?.served, served, "et il n'a pas été remplacé")
    }
}
