import XCTest

@testable import WisqVM

/// Ce que Linux local occupe sur le téléphone, compté sur de vrais fichiers.
///
/// Le sujet est devenu sérieux le jour où la mémoire est devenue réglable :
/// une machine sauvegardée ne peut pas dépasser la RAM dont elle a été prise,
/// donc un noyau réglé à un gibioctet peut laisser derrière lui un fichier
/// cent fois plus gros que le noyau lui-même.
final class LocalStorageTests: XCTestCase {
    private var root: URL!
    private var kernels: URL!
    private var machines: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-stockage-\(UUID().uuidString)", isDirectory: true)
        kernels = root.appendingPathComponent("kernels", isDirectory: true)
        machines = root.appendingPathComponent("machines", isDirectory: true)
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    // MARK: - Ce qu'une image d'installation laisse déballé

    /// Le dossier où `IsoBoot` déballe, avec deux fichiers de tailles connues.
    @discardableResult
    private func unpackSomething(kernel: Int, initrd: Int) throws -> URL {
        let folder = try XCTUnwrap(LocalStorage.unpackedIsoFolder(in: root))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: kernel)
            .write(to: folder.appendingPathComponent("vmlinuz"))
        try Data(repeating: 0x5A, count: initrd)
            .write(to: folder.appendingPathComponent("initramfs"))
        return folder
    }

    /// **Le relevé compte ce que l'image a laissé déballé.**
    ///
    /// C'étaient des octets invisibles : un noyau et un initramfs sortis de
    /// l'ISO au dernier démarrage, dans un dossier que rien n'énumérait. Le
    /// total les ignorait, donc personne ne pouvait savoir qu'ils étaient là.
    func testTheReportCountsWhatAnImageLeftUnpacked() throws {
        _ = try writeKernel("installation.iso", bytes: 100)
        let folder = try unpackSomething(kernel: 3000, initrd: 4000)

        let report = LocalStorage.report(
            kernels: kernels, machines: machines, unpackedIso: folder)
        XCTAssertEqual(report.unpackedIsoBytes, 7000)
        XCTAssertEqual(report.total, 7100, "le déballage compte dans le total")
    }

    /// Et sans déballage — le cas de tous les autres appels — il ne s'invente
    /// rien.
    func testWithNothingUnpackedTheReportSaysZero() throws {
        _ = try writeKernel("Image", bytes: 100)
        let report = LocalStorage.report(kernels: kernels, machines: machines)
        XCTAssertEqual(report.unpackedIsoBytes, 0)
        XCTAssertEqual(report.total, 100)
    }

    /// **Le dossier n'appartient à aucun noyau**, et le relevé ne le range pas
    /// sous celui qui porte son nom. Il est partagé : le démarrage suivant le
    /// refait à neuf pour une autre image, donc l'attribuer serait mentir.
    func testTheUnpackedFolderIsNotChargedToAnyKernel() throws {
        _ = try writeKernel("installation.iso", bytes: 100)
        let folder = try unpackSomething(kernel: 3000, initrd: 4000)

        let report = LocalStorage.report(
            kernels: kernels, machines: machines, unpackedIso: folder)
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(report.entries[0].total, 100, "l'entrée ne porte que son fichier")
    }

    /// **Un dossier à l'intérieur est parcouru, pas compté.** Un répertoire a
    /// une taille sur le disque — quatre kibioctets ici, soixante-quatre
    /// octets sur APFS — et l'additionner ferait dire au relevé deux nombres
    /// différents selon la plateforme pour les mêmes fichiers.
    func testADirectoryInsideTheUnpackingIsWalkedButNotCounted() throws {
        let folder = try unpackSomething(kernel: 3000, initrd: 4000)
        let inside = folder.appendingPathComponent("efi", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 500).write(to: inside.appendingPathComponent("BOOTX64"))

        let report = LocalStorage.report(
            kernels: kernels, machines: machines, unpackedIso: folder)
        XCTAssertEqual(
            report.unpackedIsoBytes, 7500,
            "les trois fichiers, et rien pour les deux dossiers qui les portent")
    }

    /// **Jeter le déballage rend exactement ce qu'il pesait**, et le dossier
    /// n'est plus là.
    func testDiscardingTheUnpackedImageTakesBackItsBytes() throws {
        let folder = try unpackSomething(kernel: 3000, initrd: 4000)

        XCTAssertEqual(LocalStorage.discardUnpackedIso(folder), 7000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        // Deux fois de suite ne rend rien de plus, et n'échoue pas : c'est le
        // cas de toute suppression qui suit une autre.
        XCTAssertEqual(LocalStorage.discardUnpackedIso(folder), 0)
        XCTAssertEqual(LocalStorage.discardUnpackedIso(nil), 0)
    }

    /// Et il n'emporte rien d'autre : les noyaux et les machines sauvegardées
    /// vivent à côté, dans le même dossier parent.
    func testDiscardingTheUnpackedImageLeavesTheLibraryAlone() throws {
        let image = try writeKernel("Image", bytes: 100)
        try saveMachine(for: image, named: "Image", bytes: 2000)
        let folder = try unpackSomething(kernel: 3000, initrd: 4000)

        LocalStorage.discardUnpackedIso(folder)

        let after = LocalStorage.report(
            kernels: kernels, machines: machines, unpackedIso: folder)
        XCTAssertEqual(after.unpackedIsoBytes, 0)
        XCTAssertEqual(after.entries.count, 1)
        XCTAssertEqual(after.entries[0].kernelBytes, 100)
        XCTAssertEqual(after.entries[0].savedMachineBytes, 2000)
    }

    /// **`nil` veut dire « l'endroit habituel »**, comme partout ailleurs ici,
    /// et le nom du dossier est celui que `IsoBoot` emploie — la même fonction
    /// le donne aux deux, pour qu'il n'y ait pas deux vérités.
    func testTheUnpackedFolderSitsBesideTheSavedMachines() throws {
        let named = try XCTUnwrap(LocalStorage.unpackedIsoFolder(in: root))
        XCTAssertEqual(named.lastPathComponent, "iso")
        XCTAssertEqual(named.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertNotNil(LocalStorage.unpackedIsoFolder(in: nil),
                        "sans dossier donné, il en trouve un quand même")
    }
}

/// Ce qu'une machine sauvegardée coûte vraiment, mesuré sur un vrai noyau.
///
/// C'est la garde d'une phrase que l'application montre. Le premier brouillon
/// disait le contraire de la vérité — « un noyau réglé à un gibioctet peut
/// laisser un fichier cent fois plus gros que le noyau » — et seule la mesure
/// l'a dit :
///
///     machine   après 5 M instr.   après 65 M (invite de connexion)
///      64 Mio        8,9 Mio                16,4 Mio
///     128 Mio        9,5 Mio                17,0 Mio
///     256 Mio       10,5 Mio                18,4 Mio
///
/// Le coût suit **ce que l'invité a touché**, pas ce qu'on lui a donné : les
/// suites de zéros sont repliées, et Linux ne touche pas la mémoire dont il
/// n'a pas l'usage.
///
/// Ce test existe parce que ce repliement est ce qui sépare « dix-sept
/// mégaoctets par noyau suspendu » de « la taille de la machine par noyau
/// suspendu ». S'il cassait, le stockage du téléphone se remplirait sans que
/// rien ne change de comportement visible.
final class ResizedSnapshotCostTests: XCTestCase {
    private static func imageURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func snapshotBytes(ramSize: UInt32, budget: UInt64, image: Data) throws -> Int {
        let machine = LinuxMachine(ramSize: ramSize) { _ in }
        try machine.load(kernelImage: image)
        _ = machine.run(instructionBudget: budget)
        return machine.snapshot().count
    }

    func testTheCostFollowsWhatTheGuestTouchedNotWhatItWasGiven() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)
        let budget: UInt64 = 65_000_000

        let small = try snapshotBytes(ramSize: 64 << 20, budget: budget, image: image)
        let large = try snapshotBytes(ramSize: 256 << 20, budget: budget, image: image)

        // Quadrupler la machine ne doit pas doubler l'instantané. La marge est
        // large exprès : ce test tient une forme, pas un octet — mesuré, l'écart
        // est de deux mégaoctets sur seize.
        XCTAssertLessThan(
            large, small * 2,
            "quadrupler la mémoire a fait plus que doubler l'instantané : le repliement des zéros ne fait plus son travail")

        // Et les deux doivent rester une fraction de la petite machine. Sans
        // repliement, chacun ferait la taille de sa machine.
        for (size, bytes) in [(64 << 20, small), (256 << 20, large)] {
            XCTAssertLessThan(
                bytes, (64 << 20) / 2,
                "\(size >> 20) Mo : \(LocalStorage.describe(bytes: bytes)) est trop pour un noyau qui vient de démarrer")
        }

        // Une machine qui a plus tourné coûte plus : c'est l'usage qui paie.
        let brief = try snapshotBytes(ramSize: 64 << 20, budget: 5_000_000, image: image)
        XCTAssertLessThan(
            brief, small,
            "un invité qui a moins tourné doit avoir moins écrit")
    }
}
