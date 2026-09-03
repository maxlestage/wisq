import XCTest

@testable import WisqVM

/// Ce que Linux local occupe sur le téléphone, compté sur de vrais fichiers.
///
/// Le sujet est devenu sérieux le jour où la mémoire est devenue réglable :
/// une machine sauvegardée ne peut pas dépasser la RAM dont elle a été prise,
/// donc un noyau réglé à un gibioctet peut laisser derrière lui un fichier
/// cent fois plus gros que le noyau lui-même.
final class LocalStorageTests: XCTestCase {
    private var kernels: URL!
    private var machines: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-stockage-\(UUID().uuidString)", isDirectory: true)
        kernels = root.appendingPathComponent("kernels", isDirectory: true)
        machines = root.appendingPathComponent("machines", isDirectory: true)
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: kernels.deletingLastPathComponent())
    }

    private func writeKernel(_ name: String, bytes: Int) throws -> Data {
        let image = Data(repeating: 0x13, count: bytes)
        try image.write(to: kernels.appendingPathComponent(name))
        return image
    }

    private func saveMachine(for image: Data, named name: String, bytes: Int) throws {
        try SuspendedMachine.save(
            Data(repeating: 0xAA, count: bytes),
            kernel: SuspendedMachine.identity(of: image, named: name), in: machines)
    }

    /// Rien du tout se lit comme rien du tout, pas comme une panne.
    func testAnEmptyLibraryReportsNothing() {
        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertEqual(report.total, 0)
        XCTAssertEqual(report.orphanedCount, 0)
    }

    /// Un noyau sans machine sauvegardée : sa taille, et rien d'autre.
    func testAKernelOnItsOwnCountsOnlyItself() throws {
        _ = try writeKernel("Image", bytes: 4096)
        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].kernel, "Image")
        XCTAssertEqual(report.entries[0].kernelBytes, 4096)
        XCTAssertEqual(report.entries[0].savedMachineBytes, 0)
        XCTAssertEqual(report.entries[0].savedMachineCount, 0)
        XCTAssertEqual(report.total, 4096)
    }

    /// Les machines sauvegardées comptent avec leur noyau, et se comptent
    /// toutes : le même nom peut avoir été plusieurs fichiers différents.
    func testEveryMachineSavedFromOneKernelCountsWithIt() throws {
        let image = try writeKernel("Image", bytes: 1000)
        try saveMachine(for: image, named: "Image", bytes: 5000)
        try saveMachine(for: Data([9, 9, 9]), named: "Image", bytes: 7000)

        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].savedMachineCount, 2)
        XCTAssertEqual(report.entries[0].savedMachineBytes, 12000)
        XCTAssertEqual(report.entries[0].total, 13000)
        XCTAssertEqual(report.savedMachineBytes, 12000)
    }

    /// Le plus gros en premier : c'est ce que cherche quelqu'un qui veut de la
    /// place. À égalité, l'ordre est celui des noms, pour qu'il soit stable.
    func testTheHeaviestComesFirst() throws {
        _ = try writeKernel("petit", bytes: 100)
        let gros = try writeKernel("gros", bytes: 200)
        try saveMachine(for: gros, named: "gros", bytes: 9000)
        _ = try writeKernel("bbb", bytes: 100)
        _ = try writeKernel("aaa", bytes: 100)

        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.entries.map(\.kernel), ["gros", "aaa", "bbb", "petit"])
    }

    /// Une machine dont le noyau n'est plus là est du poids mort : elle ne peut
    /// pas être restaurée sans lui. Elle est comptée à part, et pas balayée en
    /// silence — supprimer les fichiers de quelqu'un sans le dire n'est pas
    /// mieux pour être juste.
    func testAMachineWithoutItsKernelIsCountedApart() throws {
        let image = try writeKernel("Image", bytes: 100)
        try saveMachine(for: image, named: "Image", bytes: 2000)
        try saveMachine(for: Data([1]), named: "disparu", bytes: 3000)

        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.entries.count, 1, "un seul noyau dans la bibliothèque")
        XCTAssertEqual(report.orphanedCount, 1)
        XCTAssertEqual(report.orphanedBytes, 3000)
        XCTAssertEqual(report.total, 5100, "le poids mort compte quand même dans le total")
    }

    /// Et le geste qui la reprend rend exactement ce qu'il a libéré, sans
    /// toucher aux machines dont le noyau existe encore.
    func testFreeingOrphansTakesBackTheirBytesAndOnlyTheirs() throws {
        let image = try writeKernel("Image", bytes: 100)
        try saveMachine(for: image, named: "Image", bytes: 2000)
        try saveMachine(for: Data([1]), named: "disparu", bytes: 3000)

        XCTAssertEqual(LocalStorage.freeOrphanedMachines(kernels: kernels, machines: machines), 3000)

        let after = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(after.orphanedCount, 0)
        XCTAssertEqual(after.orphanedBytes, 0)
        XCTAssertEqual(after.entries[0].savedMachineBytes, 2000, "l'autre est intacte")
        XCTAssertEqual(after.total, 2100)

        // Deux fois de suite ne libère rien de plus, et n'échoue pas.
        XCTAssertEqual(LocalStorage.freeOrphanedMachines(kernels: kernels, machines: machines), 0)
    }

    /// Un noyau dont le nom est le préfixe d'un autre ne s'attribue pas ses
    /// machines : le même piège que pour l'oubli, ici il fausserait un total.
    func testANameThatIsAPrefixOfAnotherDoesNotStealItsMachines() throws {
        let first = try writeKernel("Image", bytes: 10)
        let second = try writeKernel("Image-2", bytes: 10)
        try saveMachine(for: first, named: "Image", bytes: 1000)
        try saveMachine(for: second, named: "Image-2", bytes: 2000)

        let report = LocalStorage.report(kernels: kernels, machines: machines)
        let byName = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.kernel, $0) })
        XCTAssertEqual(byName["Image"]?.savedMachineBytes, 1000)
        XCTAssertEqual(byName["Image-2"]?.savedMachineBytes, 2000)
        XCTAssertEqual(report.orphanedCount, 0, "chaque machine a trouvé son noyau")
    }

    /// Le réglage de mémoire vit dans le même répertoire et n'est ni compté
    /// comme une machine ni supprimé par le nettoyage.
    func testTheMemorySettingsFileIsNeitherCountedNorRemoved() throws {
        _ = try writeKernel("Image", bytes: 10)
        KernelMemory.setSize(128 << 20, forKernel: "Image", in: machines)

        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.orphanedCount, 0)
        XCTAssertEqual(report.total, 10)

        LocalStorage.freeOrphanedMachines(kernels: kernels, machines: machines)
        XCTAssertEqual(
            KernelMemory.size(forKernel: "Image", in: machines), 128 << 20,
            "le nettoyage ne doit pas emporter les réglages")
    }

    /// Les tailles telles qu'on les lit. En puissances de deux, et l'unité le
    /// dit : tout le reste du dépôt compte la mémoire ainsi, et un chiffre de
    /// stockage en puissances de dix à côté d'un chiffre de mémoire qui ne
    /// l'est pas rendrait les deux incomparables.
    func testSizesAreReadableAndCountedInPowersOfTwo() {
        XCTAssertEqual(LocalStorage.describe(bytes: 0), "0 o")
        XCTAssertEqual(LocalStorage.describe(bytes: 512), "512 o")
        XCTAssertEqual(LocalStorage.describe(bytes: 1024), "1 Kio")
        XCTAssertEqual(LocalStorage.describe(bytes: 3_500_000), "3,3 Mio")
        XCTAssertEqual(LocalStorage.describe(bytes: 64 << 20), "64,0 Mio")
        XCTAssertEqual(LocalStorage.describe(bytes: 1024 << 20), "1,0 Gio")
        // Une taille négative n'existe pas ; elle ne doit pas s'afficher.
        XCTAssertEqual(LocalStorage.describe(bytes: -5), "0 o")
    }
}
