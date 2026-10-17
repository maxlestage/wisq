import XCTest

@testable import WisqVM

/// Une machine emportée hors du téléphone, puis ramenée sur un autre : elle doit
/// revenir avec ses réglages, ses écritures et sa session — ou pas du tout.
final class MachineArchiveTests: XCTestCase {
    private var here: URL!
    private var there: URL!
    private var archive: URL!
    private let iso = "alpine-virt-3.20.3-x86_64.iso"

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-archive-\(UUID().uuidString)", isDirectory: true)
        here = root.appendingPathComponent("ici", isDirectory: true)
        there = root.appendingPathComponent("ailleurs", isDirectory: true)
        for folder in [here!, there!, kernels(here), kernels(there)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        archive = root.appendingPathComponent("machine.\(MachineArchive.fileExtension)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: here.deletingLastPathComponent())
    }

    private func kernels(_ folder: URL) -> URL { folder.appendingPathComponent("kernels") }

    /// Une machine avec de tout : mémoire, disque, deux couches et une session.
    private func furnishedMachine() throws -> InstalledMachine {
        let machine = try InstalledMachines.install(image: iso, name: "Travail", in: here)
        KernelMemory.setSize(KernelMemory.choices.last!, forKernel: machine.key, in: here)
        LocalDisk.attach("donnees.img", forKernel: machine.key, in: here)
        try write(Data(repeating: 0xAB, count: 3 * MachineArchive.chunk + 17),
                  to: LocalDisk.writesURL(for: machine.keys.overlay(forDisk: "donnees.img"), in: here))
        try write(Data([1, 2, 3, 4, 5, 6, 7, 8]),
                  to: URL(fileURLWithPath: LocalDisk.writesURL(
                    for: machine.keys.overlay(forDisk: "donnees.img"), in: here).path + ".map"))
        try write(Data([9, 9]), to: LocalDisk.writesURL(for: machine.keys.overlay(forDisk: iso), in: here))
        try SuspendedMachine.save(
            Data("la session".utf8),
            kernel: SuspendedMachine.identity(of: Data("noyau".utf8), named: machine.key), in: here)
        return machine
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func importThere(library: [String] = ["alpine-virt-3.20.3-x86_64.iso"]) throws -> InstalledMachine {
        try MachineArchive.import(from: archive, library: library, in: there) { name, bytes in
            let taken = (try? FileManager.default.contentsOfDirectory(
                atPath: self.kernels(self.there).path)) ?? []
            let disk = BlankDisk.fileName(forMachine: name, among: taken)
            try BlankDisk.create(at: self.kernels(self.there).appendingPathComponent(disk), bytes: bytes)
            return disk
        }
    }

    /// **L'aller-retour** : sur l'autre téléphone, la machine a le même nom, la
    /// même mémoire, le même disque, les mêmes octets dans ses couches et la même
    /// session — sous une clé neuve.
    func testAMachineComesBackWithEverythingItHeld() throws {
        let machine = try furnishedMachine()
        XCTAssertTrue(FileManager.default.fileExists(atPath: kernels(here).path))
        try MachineArchive.export(machine, kernels: kernels(here), in: here, to: archive)
        XCTAssertTrue(MachineArchive.isArchive(archive))

        let back = try importThere()
        XCTAssertEqual(back.name, "Travail")
        XCTAssertEqual(back.image, iso)
        XCTAssertEqual(KernelMemory.size(forKernel: back.key, in: there, ceiling: .max),
                       KernelMemory.choices.last!)
        XCTAssertEqual(LocalDisk.recordedName(forKernel: back.key, in: there), "donnees.img")
        let layer = try LocalDisk.writesURL(for: back.keys.overlay(forDisk: "donnees.img"), in: there)
        XCTAssertEqual(try Data(contentsOf: layer),
                       Data(repeating: 0xAB, count: 3 * MachineArchive.chunk + 17),
                       "une couche plus grosse qu'un morceau revient entière")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: layer.path + ".map")),
                       Data([1, 2, 3, 4, 5, 6, 7, 8]))
        XCTAssertEqual(try Data(contentsOf: LocalDisk.writesURL(
            for: back.keys.overlay(forDisk: iso), in: there)), Data([9, 9]))
        XCTAssertEqual(
            SuspendedMachine.load(
                kernel: SuspendedMachine.identity(of: Data("noyau".utf8), named: back.key), in: there),
            Data("la session".utf8), "la session reprendra là-bas")
    }

    /// **Sans l'image, rien n'est créé**, et le refus la nomme.
    func testAMissingImageIsNamedAndNothingIsCreated() throws {
        try MachineArchive.export(try furnishedMachine(), kernels: kernels(here), in: here, to: archive)
        XCTAssertThrowsError(try importThere(library: [])) {
            XCTAssertEqual($0 as? MachineArchive.Refusal, .missingImage(iso))
        }
        XCTAssertEqual(InstalledMachines.list(in: there), [])
    }

    /// **Une archive tronquée n'importe rien** : la taille annoncée est vérifiée
    /// avant la moindre écriture.
    func testATruncatedArchiveImportsNothing() throws {
        try MachineArchive.export(try furnishedMachine(), kernels: kernels(here), in: here, to: archive)
        let whole = try Data(contentsOf: archive)
        try whole.dropLast(5).write(to: archive)
        XCTAssertThrowsError(try importThere()) {
            XCTAssertEqual($0 as? MachineArchive.Refusal, .damaged)
        }
        XCTAssertEqual(InstalledMachines.list(in: there), [])
        let writes = try LocalDisk.writesDirectory(in: there)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: writes.path), [])
    }

    /// Ce qui n'est pas une archive est refusé comme tel.
    func testAnythingElseIsNotAnArchive() throws {
        try Data("pas une machine".utf8).write(to: archive)
        XCTAssertFalse(MachineArchive.isArchive(archive))
        XCTAssertThrowsError(try importThere()) {
            XCTAssertEqual($0 as? MachineArchive.Refusal, .notAnArchive)
        }
    }

    /// **Un nom qui sortirait de son dossier est refusé**, avant toute écriture.
    func testANameThatWouldLeaveItsFolderIsRefused() throws {
        let manifest = MachineArchive.Manifest(
            name: "x", image: iso, memory: nil, disk: nil, ownDiskBytes: nil,
            files: [.init(kind: .writes, name: "../../hors", length: 1)])
        let encoded = try JSONEncoder().encode(manifest)
        var bytes = Data(MachineArchive.magic)
        withUnsafeBytes(of: UInt64(encoded.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(encoded)
        bytes.append(0)
        try bytes.write(to: archive)
        XCTAssertThrowsError(try importThere()) {
            XCTAssertEqual($0 as? MachineArchive.Refusal, .unsafeName("../../hors"))
        }
        XCTAssertEqual(InstalledMachines.list(in: there), [])
    }

    /// **Le disque vierge propre n'est pas copié, il est recréé** : même
    /// taille, et la couche qui le remplissait suit son nouveau nom.
    func testAnOwnDiskIsRecreatedAndItsLayerFollows() throws {
        let machine = try InstalledMachines.install(image: iso, name: "Neuve", in: here)
        try BlankDisk.create(at: kernels(here).appendingPathComponent("Neuve-disque.img"), bytes: 1 << 30)
        try InstalledMachines.setOwnDisk("Neuve-disque.img", id: machine.id, in: here)
        LocalDisk.attach("Neuve-disque.img", forKernel: machine.key, in: here)
        try write(Data([4, 2]), to: LocalDisk.writesURL(
            for: machine.keys.overlay(forDisk: "Neuve-disque.img"), in: here))
        try MachineArchive.export(
            try XCTUnwrap(InstalledMachines.machine(id: machine.id, in: here)),
            kernels: kernels(here), in: here, to: archive)
        XCTAssertLessThan(try MachineArchive.size(of: archive), 4096, "la base vierge n'est pas dedans")
        // Là-bas, un fichier porte déjà ce nom : le disque recréé en prend un
        // autre, et la couche doit le suivre.
        try Data().write(to: kernels(there).appendingPathComponent("Neuve-disque.img"))

        let back = try importThere()
        let own = try XCTUnwrap(back.ownDisk)
        XCTAssertEqual(own, "Neuve-disque-2.img")
        XCTAssertEqual(try MachineArchive.size(of: kernels(there).appendingPathComponent(own)), 1 << 30)
        XCTAssertEqual(LocalDisk.recordedName(forKernel: back.key, in: there), own)
        XCTAssertEqual(try Data(contentsOf: LocalDisk.writesURL(
            for: back.keys.overlay(forDisk: own), in: there)), Data([4, 2]))
    }
}
