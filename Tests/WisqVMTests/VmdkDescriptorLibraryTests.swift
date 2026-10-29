import XCTest
@testable import WisqVM

/// **Le VMDK à descripteur dans la bibliothèque** : importé avec ses
/// étendues, qui n'y ont pas de ligne à elles. L'application ne voit que les
/// fichiers qu'on lui choisit — un descripteur seul ne lui ouvre pas ses
/// voisins —, et c'est donc à elle de dire ce qui manque, de cacher ce qui
/// n'est pas un disque à lui seul, et de compter le disque là où il se voit.
final class VmdkDescriptorLibraryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vmdk-bibliotheque-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func file(_ name: String, _ bytes: [UInt8], in place: URL? = nil) throws -> URL {
        let url = (place ?? folder).appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Un descripteur à la façon d'ESXi : pas complété, quelques centaines
    /// d'octets.
    @discardableResult
    private func descriptor(_ name: String, _ extents: [String], in place: URL? = nil) throws -> URL {
        let text = """
            # Disk DescriptorFile
            version=1
            CID=fffffffe
            parentCID=ffffffff
            createType="vmfs"

            # Extent description
            \(extents.joined(separator: "\n"))

            # The Disk Data Base
            #DDB
            ddb.adapterType = "lsilogic"

            """
        return try file(name, Array(text.utf8), in: place)
    }

    // MARK: - Ce que le descripteur nomme

    /// **Dans l'ordre, sans doublon, et jamais hors du dossier** : `ZERO`
    /// n'a pas de fichier, un nom en chemin n'est pas une étendue qu'on
    /// apporterait.
    func testTheCompanionsAreTheFilesNamedNextToIt() throws {
        let url = try descriptor("disque.vmdk", [
            "RW 2048 SPARSE \"disque-s001.vmdk\"",
            "RW 512 ZERO",
            "RW 2048 SPARSE \"disque-s002.vmdk\"",
            "RW 2048 FLAT \"disque-s001.vmdk\" 0",
            "RW 2048 FLAT \"../ailleurs.raw\" 0",
        ])
        XCTAssertEqual(VmdkDescriptorDisk.companionFiles(ofDescriptorAt: url),
                       ["disque-s001.vmdk", "disque-s002.vmdk"])
        let other = try file("noyau", Array("pas un descripteur".utf8))
        XCTAssertEqual(VmdkDescriptorDisk.companionFiles(ofDescriptorAt: other), [])
    }

    /// **Ce qui manque se dit, nommé** — et rien quand rien ne manque.
    func testAnIncompleteImportSaysWhatToBring() throws {
        let url = try descriptor("disque.vmdk", [
            "RW 2048 FLAT \"disque-s001.vmdk\" 0", "RW 2048 FLAT \"disque-s002.vmdk\" 0",
        ])
        XCTAssertEqual(VmdkDescriptorDisk.missingCompanions(ofDescriptorAt: url),
                       ["disque-s001.vmdk", "disque-s002.vmdk"])
        XCTAssertEqual(VmdkDescriptorDisk.incompleteImportExplanation(ofDescriptorAt: url), """
            « disque.vmdk » est un descripteur VMDK : le disque est dans « disque-s001.vmdk », \
            « disque-s002.vmdk », à côté de lui. Importez ces 2 fichiers aussi — ou choisissez-les \
            tous ensemble.
            """)
        try file("disque-s001.vmdk", [1])
        XCTAssertEqual(VmdkDescriptorDisk.incompleteImportExplanation(ofDescriptorAt: url), """
            « disque.vmdk » est un descripteur VMDK : le disque est dans « disque-s002.vmdk », à côté \
            de lui. Importez ce fichier aussi — ou choisissez-les tous ensemble.
            """)
        try file("disque-s002.vmdk", [2])
        XCTAssertNil(VmdkDescriptorDisk.incompleteImportExplanation(ofDescriptorAt: url))
    }

    // MARK: - La liste

    /// **Les étendues n'ont pas de ligne** ; le descripteur et ce que rien ne
    /// nomme restent. Un fichier du même nom, dans un autre dossier, n'est
    /// pas l'étendue de ce descripteur-ci.
    func testTheListHidesTheExtentsAndOnlyThem() throws {
        let disk = try descriptor("disque.vmdk", ["RW 2048 FLAT \"disque-flat.vmdk\" 0"])
        let flat = try file("disque-flat.vmdk", [0])
        let kernel = try file("bzImage", [0])
        let elsewhere = folder.appendingPathComponent("autre")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let namesake = try file("disque-flat.vmdk", [0], in: elsewhere)
        XCTAssertEqual(VmdkDescriptorDisk.hidingCompanions([kernel, disk, flat, namesake]),
                       [kernel, disk, namesake])
        XCTAssertEqual(VmdkDescriptorDisk.companionNames(among: [kernel, disk, flat]), ["disque-flat.vmdk"])
        XCTAssertEqual(VmdkDescriptorDisk.hidingCompanions([kernel, flat]), [kernel, flat],
                       "sans son descripteur, une étendue reste visible")
    }

    /// **Le disque se compte à la ligne du descripteur** : ses étendues sont
    /// tout le disque, et elles n'ont pas de ligne à elles.
    func testTheStorageReportCountsTheExtentsOnTheDescriptorsLine() throws {
        let kernels = folder.appendingPathComponent("kernels")
        let machines = folder.appendingPathComponent("machines")
        for place in [kernels, machines] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        }
        let disk = try descriptor("disque.vmdk", [
            "RW 8 FLAT \"disque-s001.vmdk\" 0", "RW 8 FLAT \"disque-s002.vmdk\" 0",
        ], in: kernels)
        try file("disque-s001.vmdk", [UInt8](repeating: 1, count: 4096), in: kernels)
        try file("disque-s002.vmdk", [UInt8](repeating: 2, count: 4096), in: kernels)
        try file("bzImage", [UInt8](repeating: 3, count: 100), in: kernels)
        let report = LocalStorage.report(kernels: kernels, machines: machines)
        let descriptorBytes = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? Int)
        XCTAssertEqual(report.entries.map(\.kernel), ["disque.vmdk", "bzImage"])
        XCTAssertEqual(report.entries.first?.kernelBytes, descriptorBytes + 8192)
    }

    // MARK: - L'import

    /// **Un descripteur d'ESXi pèse moins d'un secteur**, et c'est un disque :
    /// le plancher des disques ne le refuse pas.
    func testADescriptorShorterThanASectorIsADisk() throws {
        let url = try descriptor("disque.vmdk", ["RW 2048 FLAT \"disque-flat.vmdk\" 0"])
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 512)
        let kind = KernelImageKind.identify(fileAt: url)
        XCTAssertEqual(kind, .virtualDisk("VMDK (descripteur)"))
        XCTAssertTrue(LocalDisk.isDiskImage(kind))
        XCTAssertNil(LocalDisk.refusal(forFileAt: url))
        XCTAssertNotNil(LocalDisk.refusal(size: 100, name: "x.img", kind: .filesystemImage("ext4")),
                        "le plancher reste pour le reste")
    }
}
