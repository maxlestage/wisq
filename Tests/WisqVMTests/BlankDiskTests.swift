import XCTest

@testable import WisqVM

/// Un disque vierge : un nom libre, une taille proposée, et rien d'écrit.
final class BlankDiskTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-vierge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// **Un gibioctet apparent, presque rien d'alloué.** C'est la propriété
    /// qui rend la fonction possible sur un téléphone ; ce test la mesure sur
    /// ce système de fichiers, et le test hébergé la mesure sur celui d'Apple.
    func testABlankDiskHasItsSizeAndCostsNothing() throws {
        let url = folder.appendingPathComponent("travail-disque.img")
        try BlankDisk.create(at: url, bytes: 1 << 30)
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(size, 1 << 30)
        XCTAssertLessThanOrEqual(BlankDisk.allocatedBytes(atPath: url.path),
                                 BlankDisk.allocationCeiling)
    }

    /// **Il s'ouvre comme un disque, et l'invité y lit des zéros et y écrit.**
    /// Les écritures vont dans la couche ; la base reste vide.
    func testABlankDiskOpensAsADiskAndTakesWrites() throws {
        let url = folder.appendingPathComponent("d.img")
        try BlankDisk.create(at: url, bytes: 1 << 30)
        let writes = folder.appendingPathComponent("d.img.writes")
        let store = try FileDiskStore(base: url, writes: writes)
        XCTAssertEqual(store.sectors, (1 << 30) / 512)
        XCTAssertEqual(store.read(at: 1 << 29, count: 512), [UInt8](repeating: 0, count: 512))
        XCTAssertTrue(store.write(at: 1 << 29, [UInt8](repeating: 0xAB, count: 512)))
        XCTAssertEqual(store.read(at: 1 << 29, count: 4), [0xAB, 0xAB, 0xAB, 0xAB])
        XCTAssertLessThanOrEqual(BlankDisk.allocatedBytes(atPath: url.path),
                                 BlankDisk.allocationCeiling, "la base n'a pas bougé")
        // Un fichier vierge n'est reconnu comme rien — et `unknown` est ce
        // qu'un disque a le droit d'être.
        XCTAssertTrue(LocalDisk.couldBeDisk(KernelImageKind.identify(fileAt: url)))
    }

    /// Rien n'est écrasé, et une taille hors de la liste est refusée sans
    /// rien créer.
    func testNothingIsOverwrittenAndOnlyOfferedSizesAreMade() throws {
        let url = folder.appendingPathComponent("pris.img")
        try Data("à moi".utf8).write(to: url)
        XCTAssertThrowsError(try BlankDisk.create(at: url, bytes: 1 << 30)) {
            XCTAssertEqual($0 as? BlankDisk.Refusal, .alreadyExists("pris.img"))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("à moi".utf8))

        let odd = folder.appendingPathComponent("bizarre.img")
        XCTAssertThrowsError(try BlankDisk.create(at: odd, bytes: 3 << 30)) {
            XCTAssertEqual($0 as? BlankDisk.Refusal, .unsupportedSize(3 << 30))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: odd.path))
    }

    /// Le nom vient de la machine, sans ce qui surprend dans un nom de
    /// fichier, et prend un numéro quand il est pris — casse comprise.
    func testTheNameComesFromTheMachineAndIsFreeInTheLibrary() {
        XCTAssertEqual(BlankDisk.fileName(forMachine: "Travail", among: []), "Travail-disque.img")
        XCTAssertEqual(BlankDisk.fileName(forMachine: "Alpine 3.20 / test", among: []),
                       "Alpine-3.20---test-disque.img")
        XCTAssertEqual(BlankDisk.fileName(forMachine: "  ", among: []), "machine-disque.img")
        XCTAssertEqual(
            BlankDisk.fileName(forMachine: "Travail",
                               among: ["travail-disque.img", "Travail-disque-2.img"]),
            "Travail-disque-3.img")
    }
}
