import Foundation
import WisqVM
import WisqVMRust
import WisqVMTestKit
import XCTest

/// **Les deux disques servent la même requête, à l'octet près.**
///
/// Le cœur Rust est celui qui tourne sur le téléphone. Un périphérique virtio
/// écrit deux fois — une en Swift, une en Rust — est deux descriptions du même
/// protocole, et elles divergent à la première correction. Ce fichier est ce
/// qui les tient : le **même** programme invité, le **même** disque, et une
/// comparaison qui porte sur la console, sur les compteurs du périphérique, et
/// sur l'instantané complet.
///
/// L'instantané est le plus exigeant des trois. Deux disques d'accord sur ce
/// qu'ils rendent mais pas sur leur index de file, ou pas sur les octets que
/// l'invité y a écrits, seraient d'accord aujourd'hui et faux à la reprise.
final class DifferentialDiskTests: XCTestCase {
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

    private let budget: UInt64 = 2_000_000

    /// La carte que `WisqUI` donne, avec le nœud du disque — c'est
    /// `LocalMachine` qui le demande en vrai, et le raccourci le fait ici pour
    /// que les deux machines partent du même arbre.
    private func rustMachine(disk: [UInt8], console: Console) throws -> RustLinuxMachine {
        let machine = RustLinuxMachine { console.append($0) }
        machine.attach(disk: disk)
        try machine.load(
            kernelImage: RV32Asm.image(RV32DiskGuest.program()),
            deviceTree: RV32DeviceTree.tree(
                ramSize: Int(machine.ramSize), disk: machine.hasDisk).flatten())
        return machine
    }

    private func swiftMachine(disk: [UInt8], console: Console) throws -> LinuxMachine {
        let machine = LinuxMachine { console.append($0) }
        machine.attach(disk: disk)
        try machine.load(kernelImage: RV32Asm.image(RV32DiskGuest.program()))
        return machine
    }

    /// Le chemin entier, sur les deux cœurs, jugé sur ce que l'invité imprime.
    func testBothCoresServeTheSameRequestAndSayTheSameThing() throws {
        let disk = RV32DiskGuest.disk()

        let swiftConsole = Console()
        let swift = try swiftMachine(disk: disk, console: swiftConsole)
        _ = swift.run(instructionBudget: budget)

        let rustConsole = Console()
        let rust = try rustMachine(disk: disk, console: rustConsole)
        _ = rust.run(instructionBudget: budget)

        XCTAssertEqual(swiftConsole.text, "OK\n", "le cœur Swift")
        XCTAssertEqual(rustConsole.text, "OK\n", """
            le cœur Rust : une console vide veut dire que l'interruption n'est \
            jamais arrivée, et une autre lettre que le périphérique a refusé
            """)
        XCTAssertEqual(swift.disk?.served, rust.diskServed, "servies")
        XCTAssertEqual(swift.disk?.refused, rust.diskRefused, "refusées")
        XCTAssertEqual(rust.diskServed, 1)
        XCTAssertEqual(rust.diskRefused, 0)
    }

    /// **Et les deux instantanés coïncident**, disque compris.
    ///
    /// C'est ce qui rend une suspension sûre sur le téléphone : l'instantané
    /// emporte les octets que l'invité a écrits sur son disque, pas ceux du
    /// fichier importé. Un format qui différerait d'un octet entre les deux
    /// cœurs rendrait une machine sauvegardée illisible au prochain
    /// basculement.
    func testTheTwoSnapshotsAgreeDiskIncluded() throws {
        let disk = RV32DiskGuest.disk()

        let swiftConsole = Console()
        let swift = try swiftMachine(disk: disk, console: swiftConsole)
        _ = swift.run(instructionBudget: budget)

        let rustConsole = Console()
        let rust = try rustMachine(disk: disk, console: rustConsole)
        _ = rust.run(instructionBudget: budget)

        XCTAssertEqual(swift.snapshot(), rust.snapshot())
    }

    /// Une machine sauvée **avant** que le disque existe se reprend encore.
    ///
    /// Les téléphones en portent déjà : refuser celles-là pour une section qui
    /// n'y est pas ferait perdre une machine à quelqu'un pour une nouveauté
    /// qu'il n'a pas demandée.
    func testASnapshotWithoutADiskStillRestores() throws {
        let console = Console()
        let before = RustLinuxMachine { console.append($0) }
        try before.load(kernelImage: RV32Asm.image(RV32DiskGuest.program()),
                        deviceTree: RV32DeviceTree.tree(ramSize: Int(before.ramSize)).flatten())
        _ = before.run(instructionBudget: 100_000)
        let saved = before.snapshot()

        let after = RustLinuxMachine { _ in }
        XCTAssertNoThrow(try after.restore(saved))
        XCTAssertFalse(after.hasDisk, "rien à reprendre, donc pas de disque")
    }

    /// Et une machine sauvée **avec** un disque le retrouve, écritures
    /// comprises.
    func testARestoredMachineKeepsTheDiskTheGuestWroteOn() throws {
        let console = Console()
        let machine = try rustMachine(disk: RV32DiskGuest.disk(), console: console)
        _ = machine.run(instructionBudget: budget)
        XCTAssertEqual(console.text, "OK\n")
        let saved = machine.snapshot()

        let resumed = RustLinuxMachine { _ in }
        try resumed.restore(saved)
        XCTAssertTrue(resumed.hasDisk)
        XCTAssertEqual(resumed.diskServed, 1, "le compteur traverse la reprise")
        XCTAssertEqual(resumed.snapshot(), saved, "et rien d'autre n'a bougé")
    }

    // MARK: - Le disque sur fichier

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **La même écriture, sur les deux cœurs, donne la même couche — octet
    /// pour octet.** `writes` et `writes.map` sont le format que l'application
    /// rouvre au lancement suivant, sur l'un ou l'autre cœur : un octet de
    /// différence, et un disque écrit par le Rust serait relu de travers par
    /// le Swift.
    func testBothCoresWriteTheSameOverlayByteForByte() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("base.img")
        try Data(RV32DiskGuest.disk()).write(to: base)
        let before = try Data(contentsOf: base)
        let swiftWrites = folder.appendingPathComponent("swift.writes")
        let rustWrites = folder.appendingPathComponent("rust.writes")

        let swiftConsole = Console()
        let swift = LinuxMachine { swiftConsole.append($0) }
        try swift.attach(diskFileAt: base, writes: swiftWrites)
        try swift.load(kernelImage: RV32Asm.image(RV32DiskGuest.program(kind: 1)))
        _ = swift.run(instructionBudget: budget)
        swift.flushDisk()

        let rustConsole = Console()
        let rust = RustLinuxMachine { rustConsole.append($0) }
        try rust.attach(diskFileAt: base, writes: rustWrites)
        try rust.load(
            kernelImage: RV32Asm.image(RV32DiskGuest.program(kind: 1)),
            deviceTree: RV32DeviceTree.tree(
                ramSize: Int(rust.ramSize), disk: rust.hasDisk).flatten())
        _ = rust.run(instructionBudget: budget)
        rust.flushDisk()

        XCTAssertEqual(swiftConsole.text, "WK\n", "le cœur Swift a écrit, et le dit")
        XCTAssertEqual(rustConsole.text, "WK\n", "le cœur Rust aussi")
        XCTAssertEqual(swift.diskBytesWritten, 512)
        XCTAssertEqual(rust.diskBytesWritten, 512)

        let swiftOverlay = try Data(contentsOf: swiftWrites)
        XCTAssertEqual(swiftOverlay, try Data(contentsOf: rustWrites), "la couche")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: swiftWrites.path + ".map")),
                       try Data(contentsOf: URL(fileURLWithPath: rustWrites.path + ".map")),
                       "et la carte")
        XCTAssertEqual(swiftOverlay.count, 2 * 512,
                       "jusqu'à la fin du secteur écrit, et pas plus loin : le fichier est épars")
        XCTAssertEqual(Array(swiftOverlay[512..<516]), [0x57, 0x57, 0x57, 0x57],
                       "le secteur 1 porte ce que l'invité a écrit")
        XCTAssertEqual(try Data(contentsOf: base), before, "et la base n'a pas bougé")
    }

    /// **Les deux instantanés coïncident aussi sur un disque sur fichier**,
    /// et ils sont petits : ils portent la marque « le contenu vit ailleurs »,
    /// pas les octets. Puis la reprise, sur chaque cœur, retrouve le disque
    /// que l'application a rebranché — écritures comprises.
    func testFileBackedSnapshotsAgreeAndRestoreOntoTheReattachedDisk() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("base.img")
        try Data(RV32DiskGuest.disk()).write(to: base)
        let swiftWrites = folder.appendingPathComponent("swift.writes")
        let rustWrites = folder.appendingPathComponent("rust.writes")

        let swift = LinuxMachine { _ in }
        try swift.attach(diskFileAt: base, writes: swiftWrites)
        try swift.load(kernelImage: RV32Asm.image(RV32DiskGuest.program(kind: 1)))
        _ = swift.run(instructionBudget: budget)

        let rust = RustLinuxMachine { _ in }
        try rust.attach(diskFileAt: base, writes: rustWrites)
        try rust.load(
            kernelImage: RV32Asm.image(RV32DiskGuest.program(kind: 1)),
            deviceTree: RV32DeviceTree.tree(
                ramSize: Int(rust.ramSize), disk: rust.hasDisk).flatten())
        _ = rust.run(instructionBudget: budget)

        let saved = swift.snapshot()
        XCTAssertEqual(saved, rust.snapshot())
        XCTAssertLessThan(saved.count, 1 << 20, "pas l'image dedans : \(saved.count) octets")

        // La reprise, comme l'application la fait : le disque d'abord, puis
        // l'instantané par-dessus.
        let resumedRust = RustLinuxMachine { _ in }
        try resumedRust.attach(diskFileAt: base, writes: rustWrites)
        try resumedRust.restore(saved)
        XCTAssertTrue(resumedRust.hasDisk)
        XCTAssertEqual(resumedRust.diskServed, 1)
        XCTAssertEqual(resumedRust.diskBytesWritten, 512, "la couche est là, avec son secteur")

        let resumedSwift = LinuxMachine { _ in }
        try resumedSwift.attach(diskFileAt: base, writes: swiftWrites)
        try resumedSwift.restore(saved)
        XCTAssertEqual(resumedSwift.disk?.served, 1)
        XCTAssertEqual(resumedSwift.disk?.store.read(at: 512, count: 4), [0x57, 0x57, 0x57, 0x57])

        // Et sans disque rebranché, la machine revient — avec un disque vide,
        // pas un plantage. C'est le fichier supprimé entre deux sessions.
        let bare = RustLinuxMachine { _ in }
        try bare.restore(saved)
        XCTAssertTrue(bare.hasDisk, "le périphérique est là")
        XCTAssertEqual(bare.diskBytesWritten, 0, "mais il n'a rien dedans")
    }
}
