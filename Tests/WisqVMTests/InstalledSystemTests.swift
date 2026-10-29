import XCTest
@testable import WisqVM
import WisqVMTestKit

/// Le système qu'un installateur a écrit sur un disque vierge, trouvé à
/// travers la couche d'écriture : voir `InstalledSystem`.
final class InstalledSystemTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for url in made {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".map")
        }
        made = []
    }

    private func path(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-installe-\(getpid())-\(UUID().uuidString)-\(name)")
        made.append(url)
        return url
    }

    private func pattern(_ count: Int, _ seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9) &+ seed) }
    }

    /// Le système des fixtures, sur sa partition, tel qu'un installateur
    /// l'aurait écrit.
    private func installedBytes() throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: Ext4Fixtures.ext4))
        let volume = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: Ext4Fixtures.size))
        return CloudDisk.raw(around: volume)
    }

    /// Un disque vierge du même nombre de secteurs que ce qu'on y écrira.
    private func blankDisk(bytes: Int) throws -> URL {
        let url = path("disque")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    /// **Le système installé est trouvé**, à travers la couche, avec ce que
    /// son `grub.cfg` démarre.
    func testWhatTheInstallerWroteIsFoundThroughTheOverlay() throws {
        let system = try installedBytes()
        let disk = try blankDisk(bytes: system.count)
        let writes = path("couche")
        do {
            let store = try FileDiskStore(base: disk, writes: writes)
            XCTAssertTrue(store.write(at: 0, system))
            store.flush()
        }
        let found = try XCTUnwrap(InstalledSystem.find(disk: disk, writes: writes))
        XCTAssertEqual(found.kernel, pattern(300_000, 1))
        XCTAssertEqual(found.initrd, pattern(70_000, 2))
        XCTAssertEqual(found.origin, "grub.cfg de vda1")
        // **Un système installé garde sa connexion** : la console série et
        // les délais des machines lentes, mais pas de shell `root` sans mot
        // de passe, ni de première mise en route.
        let line = found.commandLine
        XCTAssertTrue(line.contains("console=ttyS0"), line)
        XCTAssertTrue(line.contains("systemd.default_timeout_start_sec="), line)
        for refused in ["set_credential", "autologin", "noauth", "firstboot"] {
            XCTAssertFalse(line.contains(refused), "« \(refused) » dans \(line)")
        }
        let base = try Data(contentsOf: disk)
        XCTAssertTrue(base.allSatisfy { $0 == 0 }, "le fichier du disque n'est jamais écrit")
    }

    /// Un disque jamais démarré n'a pas de couche : rien n'est trouvé, et
    /// la question n'en crée pas une.
    func testADiskWithoutAnOverlayHasNothingAndGainsNothing() throws {
        let disk = try blankDisk(bytes: 4 << 20)
        let writes = path("couche")
        XCTAssertNil(InstalledSystem.find(disk: disk, writes: writes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writes.path + ".map"))
    }

    /// Une couche qui n'a rien reçu de démarrable — un installateur
    /// interrompu avant d'écrire la table — ne trouve rien.
    func testAnOverlayWithoutASystemFindsNothing() throws {
        let disk = try blankDisk(bytes: 4 << 20)
        let writes = path("couche")
        do {
            let store = try FileDiskStore(base: disk, writes: writes)
            XCTAssertTrue(store.write(at: 1 << 20, [UInt8](repeating: 0xAA, count: 4096)))
            store.flush()
        }
        XCTAssertNil(InstalledSystem.find(disk: disk, writes: writes))
    }
}
