import CWisqVM
import Foundation
@testable import WisqVM
import WisqVMTestKit
@testable import WisqVMRust
import XCTest

/// **Les formats d'image de disque sur la machine PC en Rust** : un qcow2, un
/// VMDK, un VDI, un VHD, un VHDX et une appliance OVA écrits par `qemu-img`
/// (les fixtures de `WisqVMTestKit`), lus par un invité. Le pilote disque
/// minimal (`Tests/Fixtures/pc-noyau-disque.bin`, que
/// `crates/wisq-vm/tests/pc_disque.rs` vérifie octet pour octet) lit 1 024
/// octets du premier disque et les écrit au port série. Ce qu'il dit doit
/// être ce que le lecteur Swift du format rend à cet endroit — et ce que dit
/// le même pilote sur le cœur Swift, dont le disque passe par
/// `FileDiskStore`.
final class RustPCDiskImageTests: XCTestCase {
    private var folder: URL!
    private static let frozen = Date(timeIntervalSince1970: 1_795_230_600)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-rust-pc-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Le pilote disque minimal, réglé pour lire à partir de `sector`. Son
    /// secteur est le dernier quadruplet de son code : 1 024 octets d'amorce
    /// et de setup, 0x200 avant l'entrée 64 bits, 335 octets de code.
    private static func diskGuest(readingFrom sector: UInt64) throws -> Data {
        var kernel = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pc-noyau-disque.bin"))
        let at = 1024 + 0x200 + 335
        XCTAssertEqual(Array(kernel[at..<at + 8]), [7, 0, 0, 0, 0, 0, 0, 0], "le secteur de la fixture")
        kernel.replaceSubrange(at..<at + 8, with: withUnsafeBytes(of: sector.littleEndian) { Array($0) })
        return kernel
    }

    /// Une fixture, décompressée et posée dans un fichier.
    private func image(_ base64: String, size: Int, name: String) throws -> URL {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        let bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: size))
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Une console recueillie de n'importe quel fil.
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }
        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    /// Ce que dit le pilote, sur l'un ou l'autre cœur, le disque `url` en
    /// premier disque, sa couche à côté.
    private func guestReads(_ url: URL, sector: UInt64, rust: Bool) throws -> Data {
        let console = Console()
        let machine: GuestMachine
        if rust {
            let pc = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { console.append($0) })
            pc.freezeHostTime(at: Self.frozen)
            machine = pc
        } else {
            let pc = X86Machine(ramSize: 128 << 20) { console.append($0) }
            pc.frozenHostTime = Self.frozen
            machine = pc
        }
        let writes = folder.appendingPathComponent("\(url.lastPathComponent)-\(rust ? "rust" : "swift").couche")
        try machine.attachDisk(fileAt: url, writes: writes)
        try machine.load(kernelImage: try Self.diskGuest(readingFrom: sector), commandLine: nil,
                         initialRamdisk: nil)
        XCTAssertEqual(machine.runGuest(instructionBudget: 50_000_000), .powerOff, url.lastPathComponent)
        XCTAssertEqual(machine.diskBytesWritten, 0, "une lecture n'écrit rien")
        return console.data
    }

    /// **Chaque format, lu par un invité du cœur Rust, rend ce que son
    /// lecteur Swift rend**, et ce que le cœur Swift fait lire au même
    /// invité : là où les fixtures portent leurs motifs (à cheval sur deux
    /// clusters de 4 Kio, au bout du disque), dans des clusters compressés
    /// (qcow2 et VMDK « stream »), marqués zéro, et à un gibioctet dans un
    /// disque de deux.
    func testEveryImageFormatIsReadByAGuestOfTheRustCore() throws {
        let cases: [(name: String, base64: String, size: Int, sector: UInt64)] = [
            ("a-v3-4k.qcow2", Qcow2Fixtures.a, 32768, 136),
            ("b-v3-4k-comp.qcow2", Qcow2Fixtures.b, 21504, 136),
            ("c-v2-64k.qcow2", Qcow2Fixtures.c, 524_288, 0),
            ("d-v3-64k-comp.qcow2", Qcow2Fixtures.d, 329_216, 2045),
            ("e-zero.qcow2", Qcow2Fixtures.e, 32768, 6),
            ("f-2g.qcow2", Qcow2Fixtures.f, 393_216, 2_097_151),
            ("a-sparse.vmdk", VmdkFixtures.a, 262_144, 136),
            ("b-stream.vmdk", VmdkFixtures.b, 132_096, 2045),
            ("d-2g.vmdk", VmdkFixtures.d, 393_216, 2_097_152),
            ("dyn.vdi", VdiFixtures.dynamic, 2_098_176, 136),
            ("dyn.vhd", VhdFixtures.exact, 4_197_888, 136),
            ("dyn.vhdx", VhdxFixtures.dynamic, 10_485_760, 136),
            ("a-ustar.ova", OvaFixtures.a, 81920, 136),
        ]
        for (name, base64, size, sector) in cases {
            let url = try image(base64, size: size, name: name)
            let reader = try XCTUnwrap(VirtualDiskImages.disk(fileAt: url), name)
            XCTAssertFalse(reader is RawDiskImage, "\(name) est lu par son format")
            var expected = [UInt8](repeating: 0xEE, count: 1024)
            XCTAssertTrue(reader.read(into: &expected, at: sector * 512), name)
            if name != "e-zero.qcow2" {
                XCTAssertTrue(expected.contains { $0 != 0 }, "\(name) : un endroit qui porte quelque chose")
            } else {
                XCTAssertEqual(expected, [UInt8](repeating: 0, count: 1024), "le cluster marqué zéro")
            }
            let rust = try guestReads(url, sector: sector, rust: true)
            XCTAssertEqual(rust, Data(expected + Array("0".utf8)), "\(name), cœur Rust")
            let swift = try guestReads(url, sector: sector, rust: false)
            XCTAssertEqual(swift, rust, "\(name) : le cœur Swift lit pareil")
        }
    }

    /// **Une table qui mène hors du fichier est une erreur d'entrée-sortie
    /// pour l'invité**, pas des zéros donnés pour vrais : la table L1 d'un
    /// qcow2 désigne une table L2 à un pétaoctet, que le fichier n'a pas. Le
    /// lecteur Swift rend « non », le cœur Rust le dit à l'invité (statut
    /// « 1 »), comme le cœur Swift.
    func testATableOutsideTheFileIsAnIOErrorForTheGuest() throws {
        let url = try image(Qcow2Fixtures.a, size: 32768, name: "hors.qcow2")
        var bytes = [UInt8](try Data(contentsOf: url))
        let l1 = Int(bytes[40..<48].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        bytes.replaceSubrange(l1..<l1 + 8, with: [0x00, 0x04, 0, 0, 0, 0, 0, 0])
        try Data(bytes).write(to: url)
        let reader = try XCTUnwrap(VirtualDiskImages.disk(fileAt: url))
        var piece = [UInt8](repeating: 0, count: 512)
        XCTAssertFalse(reader.read(into: &piece, at: 136 * 512), "le lecteur refuse")
        let rust = try guestReads(url, sector: 136, rust: true)
        XCTAssertEqual(rust.count, 1025)
        XCTAssertEqual(rust.last, UInt8(ascii: "1"), "une erreur d'entrée-sortie")
        XCTAssertEqual(try guestReads(url, sector: 136, rust: false).last, UInt8(ascii: "1"), "comme le cœur Swift")
    }

    /// **Une image en second disque est le second disque** : le premier, brut,
    /// reste celui que l'invité lit sur `vda` ; l'image se branche à côté.
    func testAnImageAsTheSecondDiskLeavesTheFirstInPlace() throws {
        var raw = [UInt8](repeating: 0, count: 64 * 512)
        for index in raw.indices { raw[index] = UInt8(truncatingIfNeeded: index * 3 + 1) }
        let first = folder.appendingPathComponent("premier.img")
        try Data(raw).write(to: first)
        let second = try image(Qcow2Fixtures.a, size: 32768, name: "second.qcow2")
        let console = Console()
        let machine = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { console.append($0) })
        machine.freezeHostTime(at: Self.frozen)
        try machine.attachDisk(fileAt: first, writes: folder.appendingPathComponent("premier.couche"))
        try machine.attachSecondDisk(fileAt: second, writes: folder.appendingPathComponent("second.couche"))
        try machine.load(kernelImage: try Self.diskGuest(readingFrom: 0), commandLine: nil, initialRamdisk: nil)
        XCTAssertEqual(machine.runGuest(instructionBudget: 50_000_000), .powerOff)
        XCTAssertEqual(console.data, Data(raw[0..<1024] + Array("0".utf8)), "vda est le disque brut")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("second.couche.map").path), "l'image a sa couche")
    }

    /// **Un système installé sur un qcow2 démarre et lit son disque sur le
    /// cœur Rust**, par le chemin de l'application : `IsoBoot.decide` lit le
    /// noyau, l'initramfs et la ligne de commande dans l'image (son
    /// `extlinux.conf`), à travers le lecteur qcow2 ; la machine PC en Rust
    /// démarre avec l'image en premier disque, que l'initramfs monte en
    /// racine ; puis la connexion, et l'invité lit des fichiers du disque.
    /// `WISQ_PC_INSTALLED_DISK` : l'image ; `WISQ_PC_INSTALLED_PROOF` : ce
    /// que `cat /root/preuve.txt` doit dire. Se tait bruyamment sans elle.
    func testASystemInstalledOnAQcow2BootsOnTheRustCore() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WISQ_PC_INSTALLED_DISK"] else {
            print("disque installé absent : définir WISQ_PC_INSTALLED_DISK pour ce test")
            return
        }
        let disk = URL(fileURLWithPath: path)
        let boot = try IsoBoot.decide(disk, into: folder, ceiling: .max).get()
        XCTAssertEqual(boot.disk, disk, "l'image est son propre disque")
        let console = Console()
        let machine = try XCTUnwrap(RustPCMachine(ramSize: max(512 << 20, boot.minimumRAM)) {
            console.append($0)
        })
        try machine.attachDisk(fileAt: disk, writes: folder.appendingPathComponent("installee.couche"))
        try machine.load(kernelImage: try Data(contentsOf: boot.kernel), commandLine: boot.commandLine,
                         initialRamdisk: try boot.initrd.map { try Data(contentsOf: $0) })
        print("ligne : \(boot.commandLine ?? "")")
        let start = Date()
        func until(_ text: String, after: Int = 0) -> Bool {
            var outcome = GuestOutcome.stopped
            while outcome == .stopped, machine.retiredInstructions < 40_000_000_000 {
                if String(decoding: console.data.dropFirst(after), as: UTF8.self).contains(text) { return true }
                outcome = machine.runGuest(instructionBudget: 50_000_000)
            }
            return String(decoding: console.data.dropFirst(after), as: UTF8.self).contains(text)
        }
        XCTAssertTrue(until("login: "), String(decoding: console.data.suffix(3000), as: UTF8.self))
        let booted = Date().timeIntervalSince(start)
        var mark = console.data.count
        machine.send(Data("root\n".utf8))
        XCTAssertTrue(until("# ", after: mark), String(decoding: console.data.suffix(2000), as: UTF8.self))
        mark = console.data.count
        machine.send(Data("cat /root/preuve.txt /etc/hostname; mount | grep ' / '; echo FINI\n".utf8))
        XCTAssertTrue(until("FINI\r\n", after: mark))
        let said = String(decoding: console.data.dropFirst(mark), as: UTF8.self)
        print(said)
        print("instructions jusqu'à login: : \(machine.retiredInstructions) ; \(String(format: "%.1f", booted)) s")
        if let proof = environment["WISQ_PC_INSTALLED_PROOF"] {
            XCTAssertTrue(said.contains(proof), said)
        }
        XCTAssertTrue(said.contains("/dev/vda1 on / type ext4"), said)
        XCTAssertGreaterThan(machine.diskActivity?.served ?? 0, 100, "le disque a servi")

        // **Et ce que l'invité y écrit va dans la couche**, que le cœur Swift
        // relit par-dessus le même qcow2 : la racine remontée en écriture, un
        // fichier, puis en lecture seule (le journal d'ext4 vidé sur place).
        let before = try Data(contentsOf: disk)
        mark = console.data.count
        machine.send(Data(("mount -o remount,rw / && echo 'ecrit par le coeur Rust' > /root/ecrit.txt && "
                           + "mount -o remount,ro / && echo ECRIT\n").utf8))
        XCTAssertTrue(until("ECRIT\r\n", after: mark), String(decoding: console.data.suffix(2000), as: UTF8.self))
        machine.flushDisk()
        XCTAssertGreaterThan(machine.diskBytesWritten, 0, "la couche a reçu les écritures")
        XCTAssertEqual(try Data(contentsOf: disk), before, "le qcow2 n'a pas bougé")
        let store = try FileDiskStore(base: disk, writes: folder.appendingPathComponent("installee.couche"))
        let seen = DiskStoreImage(store)
        let table = try PartitionTable.read(seen)
        let volume = try WisqVM.linuxVolume(try XCTUnwrap(table.partitions.first), in: seen)
        XCTAssertEqual(String(decoding: try volume.contents(of: "/root/ecrit.txt"), as: UTF8.self),
                       "ecrit par le coeur Rust\n", "le cœur Swift relit la couche du cœur Rust")
    }

    /// **Une image brute reste lue par le cœur Rust lui-même** — et un
    /// invité y lit ses octets, tels quels.
    func testARawImageIsStillReadByTheRustCoreItself() throws {
        var bytes = [UInt8](repeating: 0, count: 64 * 512)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index * 7 + index / 512) }
        let url = folder.appendingPathComponent("brut.img")
        try Data(bytes).write(to: url)
        XCTAssertFalse(VirtualDiskImages.recognizes(fileAt: url))
        let read = try guestReads(url, sector: 9, rust: true)
        XCTAssertEqual(read, Data(bytes[9 * 512..<11 * 512] + Array("0".utf8)))
    }

    /// **Une image reconnue mais refusée l'est sous la phrase de son
    /// format**, celle que `FileDiskStore` dit sur le cœur Swift — avant
    /// qu'une couche ne soit créée.
    func testARefusedImageIsRefusedWithTheSentenceOfItsFormat() throws {
        let url = try image(Qcow2Fixtures.a, size: 32768, name: "base.qcow2")
        var bytes = [UInt8](try Data(contentsOf: url))
        bytes[15] = 0x40 // un fichier de base, à l'octet 8 de l'en-tête
        try Data(bytes).write(to: url)
        let machine = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { _ in })
        let writes = folder.appendingPathComponent("base.couche")
        XCTAssertThrowsError(try machine.attachSecondDisk(fileAt: url, writes: writes)) {
            XCTAssertEqual($0 as? FileDiskStore.Failure,
                           .unreadableImage(Qcow2Image.Refusal.backingFile.errorDescription ?? ""))
        }
        XCTAssertThrowsError(try FileDiskStore(base: url, writes: writes)) {
            XCTAssertEqual($0 as? FileDiskStore.Failure,
                           .unreadableImage(Qcow2Image.Refusal.backingFile.errorDescription ?? ""),
                           "la même phrase que le cœur Swift")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: writes.path), "aucune couche créée")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writes.path + ".map"))
        XCTAssertNil(machine.diskActivity, "rien n'est branché")
    }

    /// **Le lecteur vit autant que le disque** : la bibliothèque le lâche
    /// avec la machine, ou tout de suite quand elle refuse le branchement —
    /// une couche d'un autre disque, une machine déjà chargée.
    func testTheReaderLivesAsLongAsTheDiskAndNoLonger() throws {
        let url = try image(Qcow2Fixtures.a, size: 32768, name: "vie.qcow2")
        let writes = folder.appendingPathComponent("vie.couche")
        weak var kept: Qcow2Image?
        do {
            let machine = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { _ in })
            let image = try Qcow2Image(contentsOf: url)
            kept = image
            try machine.attachImage(image, writes: writes, which: 0)
            XCTAssertNotNil(machine.diskActivity, "branché")
            XCTAssertNotNil(kept, "tenu par la machine")
            try machine.load(kernelImage: try Self.diskGuest(readingFrom: 136), commandLine: nil,
                             initialRamdisk: nil)
            XCTAssertEqual(machine.runGuest(instructionBudget: 50_000_000), .powerOff)
            XCTAssertNotNil(kept, "même après la course")
        }
        XCTAssertNil(kept, "lâché avec la machine")

        weak var refused: Qcow2Image?
        do {
            let machine = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { _ in })
            // La couche d'un disque de 1 Mio, sous un lecteur qui en annonce 2.
            let other = try Qcow2Image(contentsOf: try image(Qcow2Fixtures.f, size: 393_216, name: "2g.qcow2"))
            refused = other
            XCTAssertThrowsError(try machine.attachImage(other, writes: writes, which: 1)) {
                XCTAssertEqual($0 as? FileDiskStore.Failure, .overlayBelongsToAnotherDisk)
            }
            XCTAssertNil(machine.diskActivity)
        }
        XCTAssertNil(refused, "lâché au refus")

        weak var late: Qcow2Image?
        do {
            let machine = try XCTUnwrap(RustPCMachine(ramSize: 128 << 20) { _ in })
            try machine.load(kernelImage: try Self.diskGuest(readingFrom: 0), commandLine: nil,
                             initialRamdisk: nil)
            let image = try Qcow2Image(contentsOf: url)
            late = image
            XCTAssertThrowsError(try machine.attachDisk(fileAt: url, writes: writes)) {
                XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
            }
            XCTAssertThrowsError(try machine.attachImage(image, writes: writes, which: 0)) {
                XCTAssertEqual($0 as? RustPCMachine.Refusal, .alreadyStarted)
            }
        }
        XCTAssertNil(late, "lâché au refus d'une machine chargée")
    }
}
