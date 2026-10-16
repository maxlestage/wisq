import XCTest

@testable import WisqVM

/// Plusieurs machines sur la même image : chacune son nom, ses réglages, sa
/// session et ses écritures — et rien de ce qui existait ne change de place.
final class InstalledMachineTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-installees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let iso = "alpine-virt-3.20.3-x86_64.iso"

    // MARK: - Le catalogue

    /// Un premier lancement : rien, et aucun fichier créé par une lecture.
    func testAFirstLaunchHasNoMachinesAndWritesNothing() {
        XCTAssertEqual(InstalledMachines.list(in: folder), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(InstalledMachines.fileName).path))
    }

    /// Deux installations de la même image sont deux machines, et la seconde
    /// reçoit un numéro plutôt qu'un nom identique.
    func testTwoInstallationsOfOneImageAreTwoMachinesWithDistinctNames() throws {
        let first = try InstalledMachines.install(image: iso, in: folder, id: "000000000001")
        let second = try InstalledMachines.install(image: iso, in: folder, id: "000000000002")
        XCTAssertEqual(first.name, "alpine-virt-3.20.3-x86_64")
        XCTAssertEqual(second.name, "alpine-virt-3.20.3-x86_64 (2)")
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(Set(InstalledMachines.list(in: folder).map(\.id)),
                       ["000000000001", "000000000002"])
    }

    /// Le nom donné est gardé, débarrassé de ses blancs ; la casse ne fait pas
    /// deux noms.
    func testAGivenNameIsTrimmedAndCaseDoesNotMakeItNew() throws {
        try InstalledMachines.install(image: iso, name: "  Travail \n", in: folder)
        let again = try InstalledMachines.install(image: iso, name: "travail", in: folder)
        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.name).sorted(),
                       ["Travail", "travail (2)"])
        XCTAssertEqual(again.name, "travail (2)")
    }

    /// Un nom fait de blancs prend celui de l'image, et un fichier sans nom
    /// utile en reçoit un quand même.
    func testABlankNameFallsBackToTheImageName() throws {
        let machine = try InstalledMachines.install(image: "Image", name: "   ", in: folder)
        XCTAssertEqual(machine.name, "Image")
        XCTAssertEqual(InstalledMachines.suggestedName(forImage: ".iso"), ".iso")
        XCTAssertEqual(InstalledMachines.suggestedName(forImage: "  "), "Machine")
    }

    /// Renommer garde l'identité, refuse le vide, et numérote un doublon —
    /// sans se compter soi-même comme doublon.
    func testRenamingKeepsTheIdentityAndAvoidsDuplicates() throws {
        let one = try InstalledMachines.install(image: iso, name: "Un", in: folder)
        try InstalledMachines.install(image: iso, name: "Deux", in: folder)
        XCTAssertEqual(try InstalledMachines.rename(id: one.id, to: "Deux", in: folder).name,
                       "Deux (2)")
        XCTAssertEqual(try InstalledMachines.rename(id: one.id, to: "deux (2)", in: folder).name,
                       "deux (2)", "se renommer sous son propre nom n'est pas un doublon")
        XCTAssertThrowsError(try InstalledMachines.rename(id: one.id, to: " ", in: folder)) {
            XCTAssertEqual($0 as? InstalledMachines.Refusal, .emptyName)
        }
        XCTAssertThrowsError(try InstalledMachines.rename(id: "inconnue", to: "x", in: folder)) {
            XCTAssertEqual($0 as? InstalledMachines.Refusal, .unknown("inconnue"))
        }
        XCTAssertEqual(InstalledMachines.machine(id: one.id, in: folder)?.key, one.key)
    }

    /// La dernière lancée vient en tête ; les jamais lancées suivent, par nom.
    func testTheMostRecentlyStartedComesFirst() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let alpha = try InstalledMachines.install(image: iso, name: "Alpha", in: folder, now: old)
        let beta = try InstalledMachines.install(image: iso, name: "Beta", in: folder, now: old)
        try InstalledMachines.install(image: iso, name: "Gamma", in: folder, now: old)
        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.name), ["Alpha", "Beta", "Gamma"])

        InstalledMachines.markStarted(id: beta.id, at: old.addingTimeInterval(10), in: folder)
        InstalledMachines.markStarted(id: alpha.id, at: old.addingTimeInterval(20), in: folder)
        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.name), ["Alpha", "Beta", "Gamma"])

        InstalledMachines.markStarted(id: beta.id, at: old.addingTimeInterval(30), in: folder)
        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.name), ["Beta", "Alpha", "Gamma"])
        XCTAssertEqual(InstalledMachines.machine(id: beta.id, in: folder)?.lastStartedAt,
                       old.addingTimeInterval(30), "l'heure survit à l'aller-retour par le fichier")
    }

    /// **Un catalogue illisible n'est jamais écrasé.** Il se lit vide — c'est
    /// tout ce que la liste peut montrer — et toute écriture est refusée.
    func testAnUnreadableCatalogueIsNeverOverwritten() throws {
        let url = folder.appendingPathComponent(InstalledMachines.fileName)
        let damaged = Data("{ \"machines\": [ { \"id\": ".utf8)
        try damaged.write(to: url)

        XCTAssertEqual(InstalledMachines.list(in: folder), [])
        XCTAssertThrowsError(try InstalledMachines.install(image: iso, in: folder)) {
            XCTAssertEqual($0 as? InstalledMachines.Refusal, .unreadable)
        }
        InstalledMachines.markStarted(id: "x", in: folder)
        XCTAssertEqual(InstalledMachines.removeAll(usingImage: iso, in: folder), [])
        XCTAssertEqual(try Data(contentsOf: url), damaged, "le fichier abîmé est resté tel quel")
    }

    /// On installe sur ce qui démarre — une image d'installation comprise — et
    /// pas sur un disque ni sur un initramfs.
    func testOnlyWhatBootsCanCarryAMachine() {
        XCTAssertTrue(InstalledMachines.canInstall(.discImage("ISO 9660")))
        XCTAssertTrue(InstalledMachines.canInstall(.unknown))
        XCTAssertFalse(InstalledMachines.canInstall(.filesystemImage("ext4")))
        XCTAssertFalse(InstalledMachines.canInstall(.compressedKernel("gzip")))
    }

    // MARK: - Les clés

    /// **Un fichier démarré tel quel garde exactement ses clés d'avant** :
    /// rien de ce qui est sur les téléphones ne change de place.
    func testAFileBootedDirectlyKeepsItsFormerKeys() {
        let keys = MachineKeys.image("Image")
        XCTAssertEqual(keys.settings, "Image")
        XCTAssertEqual(keys.overlay(forDisk: "racine.img"), "racine.img")
    }

    /// La clé d'une machine traverse l'assainissement des noms intacte : sinon
    /// on écrirait une session sous un nom qu'on ne retrouve plus.
    func testAnInstalledKeySurvivesSanitising() throws {
        let machine = try InstalledMachines.install(image: iso, in: folder)
        XCTAssertEqual(SuspendedMachine.safeName(machine.key), machine.key)
        XCTAssertEqual(machine.keys.settings, machine.key)
        XCTAssertNotEqual(machine.keys.overlay(forDisk: iso), iso)
        XCTAssertEqual(InstalledMachines.newIdentifier().count, 12)
    }

    /// **Deux machines sur la même image ne partagent rien de ce qu'elles
    /// retiennent** : ni la mémoire, ni le disque choisi, ni la session.
    func testTwoMachinesOnOneImageKeepSeparateSettingsAndSessions() throws {
        let work = try InstalledMachines.install(image: iso, name: "Travail", in: folder)
        let play = try InstalledMachines.install(image: iso, name: "Essai", in: folder)

        KernelMemory.setSize(KernelMemory.choices.last!, forKernel: work.key, in: folder)
        LocalDisk.attach("donnees.img", forKernel: work.key, in: folder)
        let image = Data("le même noyau".utf8)
        try SuspendedMachine.save(
            Data([1]), kernel: SuspendedMachine.identity(of: image, named: work.key), in: folder)

        XCTAssertEqual(KernelMemory.size(forKernel: play.key, in: folder, ceiling: .max),
                       KernelMemory.defaultSize)
        XCTAssertEqual(KernelMemory.size(forKernel: iso, in: folder, ceiling: .max),
                       KernelMemory.defaultSize, "l'image démarrée seule n'hérite de rien")
        XCTAssertNil(LocalDisk.recordedName(forKernel: play.key, in: folder))
        XCTAssertFalse(SuspendedMachine.exists(
            kernel: SuspendedMachine.identity(of: image, named: play.key), in: folder))
        XCTAssertTrue(SuspendedMachine.exists(
            kernel: SuspendedMachine.identity(of: image, named: work.key), in: folder))
    }

    // MARK: - Retirer

    /// Retirer une machine emporte tout ce qu'elle retenait, et **rien** de ce
    /// que retient sa voisine sur la même image.
    func testRemovingAMachineTakesEverythingItHeldAndNothingElse() throws {
        let gone = try InstalledMachines.install(image: iso, name: "Partie", in: folder)
        let kept = try InstalledMachines.install(image: iso, name: "Restée", in: folder)
        let image = Data("noyau".utf8)
        for machine in [gone, kept] {
            KernelMemory.setSize(KernelMemory.choices.last!, forKernel: machine.key, in: folder)
            LocalDisk.attach("donnees.img", forKernel: machine.key, in: folder)
            try SuspendedMachine.save(
                Data([2]), kernel: SuspendedMachine.identity(of: image, named: machine.key),
                in: folder)
            try overlay(machine.keys.overlay(forDisk: "donnees.img"))
            try overlay(machine.keys.overlay(forDisk: iso))
        }
        try overlay("donnees.img")

        try InstalledMachines.remove(id: gone.id, in: folder)

        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.id), [kept.id])
        XCTAssertEqual(KernelMemory.size(forKernel: gone.key, in: folder, ceiling: .max),
                       KernelMemory.defaultSize)
        XCTAssertNil(LocalDisk.recordedName(forKernel: gone.key, in: folder))
        XCTAssertEqual(SuspendedMachine.savedMachineFiles(named: gone.key, in: folder), [])
        XCTAssertEqual(overlays().filter { $0.hasPrefix(gone.keys.overlayPrefix) }, [])

        XCTAssertEqual(KernelMemory.size(forKernel: kept.key, in: folder, ceiling: .max),
                       KernelMemory.choices.last!)
        XCTAssertEqual(LocalDisk.recordedName(forKernel: kept.key, in: folder), "donnees.img")
        XCTAssertEqual(SuspendedMachine.savedMachineFiles(named: kept.key, in: folder).count, 1)
        XCTAssertEqual(overlays().filter { $0.hasPrefix(kept.keys.overlayPrefix) }.count, 4,
                       "deux couches et leurs deux cartes")
        XCTAssertTrue(overlays().contains("donnees.img.writes"),
                      "la couche partagée du disque n'appartient à aucune machine")
        XCTAssertThrowsError(try InstalledMachines.remove(id: gone.id, in: folder))
    }

    /// Supprimer l'image emporte les machines qui la démarrent, et seulement
    /// elles.
    func testDeletingAnImageRemovesTheMachinesThatBootIt() throws {
        try InstalledMachines.install(image: iso, name: "A", in: folder)
        try InstalledMachines.install(image: iso, name: "B", in: folder)
        let other = try InstalledMachines.install(image: "Image", name: "C", in: folder)

        XCTAssertEqual(InstalledMachines.removeAll(usingImage: iso, in: folder).map(\.name).sorted(),
                       ["A", "B"])
        XCTAssertEqual(InstalledMachines.list(in: folder).map(\.id), [other.id])
        XCTAssertEqual(InstalledMachines.removeAll(usingImage: iso, in: folder), [])
    }

    /// Le disque propre d'une machine est retenu, rendu au retrait — c'est
    /// l'appelant qui l'efface — et oublié si la personne supprime le fichier.
    func testAnOwnDiskIsRememberedReturnedOnRemovalAndForgottenWithItsFile() throws {
        let one = try InstalledMachines.install(image: iso, name: "Un", in: folder)
        let two = try InstalledMachines.install(image: iso, name: "Deux", in: folder)
        try InstalledMachines.setOwnDisk("Un-disque.img", id: one.id, in: folder)
        try InstalledMachines.setOwnDisk("Deux-disque.img", id: two.id, in: folder)
        XCTAssertEqual(InstalledMachines.machine(id: one.id, in: folder)?.ownDisk, "Un-disque.img")

        InstalledMachines.forgetOwnDisk(named: "Deux-disque.img", in: folder)
        XCTAssertNil(InstalledMachines.machine(id: two.id, in: folder)?.ownDisk)
        XCTAssertNotNil(InstalledMachines.machine(id: two.id, in: folder), "la machine reste")

        XCTAssertEqual(try InstalledMachines.remove(id: one.id, in: folder).ownDisk, "Un-disque.img")
        XCTAssertThrowsError(try InstalledMachines.setOwnDisk("x", id: one.id, in: folder))
    }

    /// **Un catalogue écrit avant le disque propre se relit**, sans lui.
    func testACatalogueWrittenBeforeOwnDisksStillReads() throws {
        let earlier = """
            {"machines":[{"id":"00000000000a","image":"Image","installedAt":"2026-10-16T11:00:00Z","name":"Vieille"}],"version":1}
            """
        try Data(earlier.utf8).write(to: folder.appendingPathComponent(InstalledMachines.fileName))
        let machine = try XCTUnwrap(InstalledMachines.list(in: folder).first)
        XCTAssertEqual(machine.name, "Vieille")
        XCTAssertNil(machine.ownDisk)
    }

    /// **Un préfixe vide ne jette aucune couche** : ce serait celles de tout le
    /// monde.
    func testAnEmptyPrefixDiscardsNoWrites() throws {
        try overlay("donnees.img")
        XCTAssertEqual(LocalDisk.discardWrites(withPrefix: "", in: folder), 0)
        XCTAssertTrue(overlays().contains("donnees.img.writes"))
    }

    // MARK: - Le stockage

    /// **La session d'une machine installée n'est pas un reste.** Son nom ne
    /// désigne aucun fichier ; sans la liste des machines, le relevé la
    /// compterait comme laissée par un noyau supprimé, et le bouton qui
    /// reprend ces octets l'effacerait.
    func testAnInstalledMachinesSessionIsNotTakenForALeftover() throws {
        let kernels = folder.appendingPathComponent("kernels", isDirectory: true)
        try FileManager.default.createDirectory(at: kernels, withIntermediateDirectories: true)
        try Data(count: 64).write(to: kernels.appendingPathComponent(iso))
        let machine = try InstalledMachines.install(image: iso, in: folder)
        try SuspendedMachine.save(
            Data(count: 100),
            kernel: SuspendedMachine.identity(of: Data("x".utf8), named: machine.key), in: folder)
        try overlay(machine.keys.overlay(forDisk: iso), bytes: 1024)
        let writes = try LocalDisk.writesDirectory(in: folder)

        let blind = LocalStorage.report(kernels: kernels, machines: folder, writes: writes)
        XCTAssertEqual(blind.orphanedCount, 1, "sans la liste, le relevé se trompe — d'où elle")

        let report = LocalStorage.report(
            kernels: kernels, machines: folder, writes: writes,
            installed: InstalledMachines.allKeys(in: folder))
        XCTAssertEqual(report.orphanedCount, 0)
        let entry = try XCTUnwrap(report.entry(forKernel: machine.key))
        XCTAssertEqual(entry.kernelBytes, 0, "l'image est comptée une fois, sous son nom")
        XCTAssertEqual(entry.savedMachineBytes, 100)
        XCTAssertEqual(entry.savedMachineCount, 1)
        XCTAssertEqual(entry.diskWritesBytes, 1024 + 8, "la couche et sa carte")
        XCTAssertEqual(report.entry(forKernel: iso)?.kernelBytes, 64)

        XCTAssertEqual(LocalStorage.freeOrphanedMachines(
            kernels: kernels, machines: folder,
            installed: InstalledMachines.allKeys(in: folder)), 0)
        XCTAssertEqual(SuspendedMachine.savedMachineFiles(named: machine.key, in: folder).count, 1,
                       "la session est toujours là")
    }

    // MARK: - Outils

    private func overlay(_ name: String, bytes: Int = 512) throws {
        let url = try LocalDisk.writesURL(for: name, in: folder)
        try Data(count: bytes).write(to: url)
        try Data(count: 8).write(to: URL(fileURLWithPath: url.path + ".map"))
    }

    private func overlays() -> [String] {
        guard let writes = try? LocalDisk.writesDirectory(in: folder) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: writes.path)) ?? []
    }
}
