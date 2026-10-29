import Foundation
import XCTest

@testable import WisqVM
import WisqVMTestKit

@testable import WisqVMRust

/// **Une machine installée démarre son disque une fois l'installation
/// faite**, et son image tant qu'il n'y a rien dessus : voir
/// `IsoBoot.decide(_:unpackingInto:ceiling:rootHash:installedOn:)`.
final class InstalledBootTests: XCTestCase {
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
            .appendingPathComponent("wisq-machine-\(getpid())-\(UUID().uuidString)-\(name)")
        made.append(url)
        return url
    }

    private func pattern(_ count: Int, _ seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 9) &+ seed) }
    }

    private func installedSystem() throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: Ext4Fixtures.ext4))
        let volume = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: Ext4Fixtures.size))
        return CloudDisk.raw(around: volume)
    }

    /// Le disque vierge d'une machine, et sa couche, où l'installateur a
    /// écrit le système des fixtures si `installed`.
    private func machineDisk(installed: Bool) throws -> (disk: URL, writes: URL) {
        let system = try installedSystem()
        let disk = path("disque")
        XCTAssertTrue(FileManager.default.createFile(atPath: disk.path, contents: nil))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: UInt64(system.count))
        try handle.close()
        let writes = path("couche")
        let store = try FileDiskStore(base: disk, writes: writes)
        if installed { XCTAssertTrue(store.write(at: 0, system)) }
        store.flush()
        return (disk, writes)
    }

    private func storage() throws -> URL {
        let url = path("stockage")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Le système installé démarre, depuis le disque de la machine : son
    /// noyau, sa ligne de commande, et c'est lui le disque.
    func testAnInstalledSystemBootsInsteadOfTheImage() throws {
        let image = try IsoGravure(commandLine: "root=/dev/vda2 ro").write()
        defer { try? FileManager.default.removeItem(at: image) }
        let machine = try machineDisk(installed: true)

        let boot = try IsoBoot.decide(image, unpackingInto: storage(), ceiling: 1 << 20,
                                      installedOn: machine).get()
        XCTAssertEqual(boot.disk, machine.disk, "le disque de la machine devient le premier")
        XCTAssertEqual(try Data(contentsOf: boot.kernel), Data(pattern(300_000, 1)))
        XCTAssertEqual(try boot.initrd.map { try Data(contentsOf: $0) }, Data(pattern(70_000, 2)))
        XCTAssertTrue(boot.commandLine?.hasPrefix("root=/dev/vda1 ro") ?? false, boot.commandLine ?? "")
        XCTAssertEqual(boot.minimumRAM, CloudBoot.minimumRAMSize)
    }

    /// Rien d'installé : l'image démarre, comme avant.
    func testAnEmptyDiskLeavesTheImageInCharge() throws {
        let image = try IsoGravure(commandLine: "root=/dev/vda2 ro").write()
        defer { try? FileManager.default.removeItem(at: image) }
        let machine = try machineDisk(installed: false)

        let boot = try IsoBoot.decide(image, unpackingInto: storage(), ceiling: 1 << 20,
                                      installedOn: machine).get()
        XCTAssertEqual(boot.disk, image, "l'image d'installation reste le disque")
        XCTAssertEqual(try Data(contentsOf: boot.kernel), IsoGravure.kernel)
    }

    /// Une image de cloud est son propre disque : celui de la machine n'y
    /// change rien, même s'il porte un système.
    func testACloudImageIgnoresTheMachineDisk() throws {
        let cloud = path("nuage")
        try Data(installedSystem()).write(to: cloud)
        let machine = try machineDisk(installed: true)

        let boot = try IsoBoot.decide(cloud, unpackingInto: storage(), ceiling: 1 << 20,
                                      installedOn: machine).get()
        XCTAssertEqual(boot.disk, cloud)
    }
}
