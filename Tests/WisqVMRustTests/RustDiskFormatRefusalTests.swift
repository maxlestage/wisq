import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// **Le cœur RISC-V lit sa base octet pour octet** : un disque dans le format
/// d'un autre hyperviseur lui donnerait les tables du format en guise de
/// système de fichiers. Il le refuse donc, et nomme le format — y compris le
/// VDI, que le cœur des PC lit sur place depuis `VdiImage`.
final class RustDiskFormatRefusalTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-rust-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAVdiIsRefusedAndNamed() throws {
        // La marque en 0x40 suffit à le reconnaître : le refus passe avant
        // toute lecture de l'en-tête.
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes.replaceSubrange(0x40..<0x44, with: [0x7F, 0x10, 0xDA, 0xBE])
        let base = folder.appendingPathComponent("linux.vdi")
        try Data(bytes).write(to: base)
        let machine = RustLinuxMachine(ramSize: 64 << 20) { _ in }
        XCTAssertThrowsError(try machine.attach(diskFileAt: base, writes: folder.appendingPathComponent("w"))) {
            guard case .unreadableImage(let reason)? = $0 as? FileDiskStore.Failure else {
                return XCTFail("refus attendu, reçu \($0)")
            }
            XCTAssertTrue(reason.hasPrefix("ce disque est un VDI,"), reason)
        }
    }
}
