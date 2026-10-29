import XCTest
@testable import WisqVM

/// **Le VMDK à descripteur à part** : un fichier de texte qui nomme ceux où
/// sont les octets. Les formes d'ESXi (`vmfs`), de `qemu-img`
/// (`monolithicFlat`) et de Workstation (`twoGbMaxExtentSparse`) — les
/// descripteurs ci-dessous sont ceux qu'écrit `qemu-img` 8.2.2, à leurs
/// identifiants près —, puis ce qui doit être refusé.
///
/// Le disque est toujours le même, celui des fixtures qcow2 :
/// `Qcow2ImageTests.original`, un mébioctet. Le morceau « sparse » est la
/// fixture `e` de `VmdkFixtures`, l'étendue `-s001` de ce même disque.
final class VmdkDescriptorDiskTests: XCTestCase {
    private var folder: URL!
    private let original = Qcow2ImageTests.original

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vmdk-descripteur-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Un descripteur, avec les champs que `qemu-img` y met, et `extents`
    /// pour lignes d'étendue. `padding` complète le fichier comme le font
    /// les outils : d'espaces (`qemu-img`) ou de zéros.
    private func descriptor(_ extents: [String], createType: String = "monolithicFlat",
                            parent: String = "ffffffff", padding: UInt8 = 0x20,
                            name: String = "disque.vmdk") throws -> URL {
        var text = """
            # Disk DescriptorFile
            version=1
            CID=ea3c3f47
            parentCID=\(parent)
            createType="\(createType)"

            # Extent description

            """
        text += extents.joined(separator: "\n") + "\n"
        text += """

            # The Disk Data Base
            #DDB

            ddb.virtualHWVersion = "4"
            ddb.geometry.cylinders = "2"
            ddb.adapterType = "ide"

            """
        var bytes = Array(text.utf8)
        bytes += [UInt8](repeating: padding, count: 512 - bytes.count % 512)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: folder.appendingPathComponent(name))
    }

    private func sparsePiece(_ name: String = "disque-s001.vmdk") throws {
        let packed = try XCTUnwrap(Data(base64Encoded: VmdkFixtures.e))
        try file(name, try XCTUnwrap(Inflate.raw([UInt8](packed), limit: 262_144, exact: true)))
    }

    private func readAll(_ disk: any VirtualDiskImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Int(disk.virtualSize))
        return disk.read(into: &out, at: 0) ? out : nil
    }

    private func refusal(_ url: URL) -> VmdkDescriptorDisk.Refusal? {
        do {
            _ = try VmdkDescriptorDisk(contentsOf: url)
            return nil
        } catch {
            return error as? VmdkDescriptorDisk.Refusal
        }
    }

    // MARK: - Les formes

    /// **`monolithicFlat`**, et le `vmfs` d'ESXi qui est le même : le
    /// descripteur, et le disque brut à côté.
    func testAFlatDiskIsTheFileNextToIt() throws {
        try file("disque-flat.vmdk", original)
        for (kind, type) in [("FLAT", "monolithicFlat"), ("VMFS", "vmfs")] {
            let url = try descriptor(["RW 2048 \(kind) \"disque-flat.vmdk\" 0"], createType: type)
            let disk = try VmdkDescriptorDisk(contentsOf: url)
            XCTAssertEqual(disk.virtualSize, 1 << 20, type)
            XCTAssertEqual(readAll(disk), original, type)
        }
    }

    /// **`twoGbMaxExtentSparse`** : un morceau « sparse » sans descripteur à
    /// lui. Seul, `VmdkImage` le refuse (`VmdkImageTests`) ; nommé par son
    /// descripteur, c'est le disque.
    func testASplitSparseDiskReadsThroughItsPiece() throws {
        try sparsePiece()
        let url = try descriptor(["RW 2048 SPARSE \"disque-s001.vmdk\""], createType: "twoGbMaxExtentSparse")
        XCTAssertEqual(readAll(try VmdkDescriptorDisk(contentsOf: url)), original)
    }

    /// **Plusieurs étendues, mises bout à bout**, de trois types : la
    /// première moitié brute à partir d'un décalage dans son fichier, un
    /// quart de zéros sans fichier, le dernier quart brut. Lu d'un coup, et
    /// par des lectures à cheval sur chaque jointure.
    ///
    /// `qemu-img` 8.2.2 lit le même disque **sans** la ligne `ZERO` et avec
    /// `RW` à la place de `RDONLY` : il saute en silence les lignes qu'il ne
    /// connaît pas, et rend alors un disque plus court, recollé — vérifié à
    /// la main. La spécification de VMware définit les deux ; c'est elle que
    /// wisq suit.
    func testExtentsAreLaidEndToEnd() throws {
        // Huit secteurs d'autre chose avant la première moitié : c'est le
        // décalage qui doit les sauter.
        try file("a.raw", [UInt8](repeating: 0x5A, count: 4096) + original[0..<(512 << 10)])
        try file("b.raw", Array(original[(768 << 10)...]))
        let url = try descriptor([
            "RW 1024 FLAT \"a.raw\" 8",
            "RW 512 ZERO",
            "RDONLY 512 FLAT \"b.raw\" 0",
        ], createType: "twoGbMaxExtentFlat")
        let disk = try VmdkDescriptorDisk(contentsOf: url)
        var expected = original
        for index in (512 << 10)..<(768 << 10) { expected[index] = 0 }
        XCTAssertEqual(readAll(disk), expected)
        for seam in [512 << 10, 768 << 10] {
            var piece = [UInt8](repeating: 0xEE, count: 3000)
            XCTAssertTrue(disk.read(into: &piece, at: UInt64(seam - 1000)))
            XCTAssertEqual(piece, Array(expected[(seam - 1000)..<(seam + 2000)]), "jointure \(seam)")
        }
        var tail = [UInt8](repeating: 0, count: 2)
        XCTAssertFalse(disk.read(into: &tail, at: disk.virtualSize - 1), "au-delà de la fin")
    }

    /// **Un descripteur complété de zéros** se lit comme celui que `qemu-img`
    /// complète d'espaces.
    func testADescriptorPaddedWithZerosReadsTheSame() throws {
        try file("disque-flat.vmdk", original)
        let url = try descriptor(["RW 2048 FLAT \"disque-flat.vmdk\" 0"], padding: 0)
        XCTAssertEqual(readAll(try VmdkDescriptorDisk(contentsOf: url)), original)
    }

    /// **Un nom avec des espaces** reste un seul nom : c'est le guillemet qui
    /// le ferme.
    func testAFileNameMayHoldSpaces() throws {
        try file("Mon disque-flat.vmdk", original)
        let url = try descriptor(["RW 2048 FLAT \"Mon disque-flat.vmdk\" 0"])
        XCTAssertEqual(readAll(try VmdkDescriptorDisk(contentsOf: url)), original)
    }

    // MARK: - Les refus

    /// Ce qui se lirait faux est refusé, et nommé.
    func testWhatWouldReadWrongIsRefusedByName() throws {
        try file("disque-flat.vmdk", original)
        try sparsePiece()
        let cases: [([String], String, VmdkDescriptorDisk.Refusal)] = [
            (["RW 2048 VMFSSPARSE \"disque-delta.vmdk\""], "ffffffff", .unsupportedExtent("VMFSSPARSE")),
            (["RW 2048 SESPARSE \"disque-sesparse.vmdk\""], "ffffffff", .unsupportedExtent("SESPARSE")),
            (["RW 2048 VMFSRDM \"disque-rdm.vmdk\""], "ffffffff", .unsupportedExtent("VMFSRDM")),
            (["NOACCESS 2048 FLAT \"disque-flat.vmdk\" 0"], "ffffffff", .unsupportedExtent("NOACCESS")),
            (["RW 2048 FLAT \"disque-flat.vmdk\" 0"], "1a2b3c4d", .parentDisk),
            (["RW 2048 FLAT \"absent-flat.vmdk\" 0"], "ffffffff", .missingFile("absent-flat.vmdk")),
            (["RW 2049 FLAT \"disque-flat.vmdk\" 0"], "ffffffff",
             .malformed("disque-flat.vmdk est plus court que l'étendue qu'il porte")),
            (["RW 2048 FLAT \"disque-flat.vmdk\" 1"], "ffffffff",
             .malformed("disque-flat.vmdk est plus court que l'étendue qu'il porte")),
            (["RW 4096 SPARSE \"disque-s001.vmdk\""], "ffffffff",
             .malformed("disque-s001.vmdk porte 2048 secteurs, le descripteur en annonce 4096")),
            (["RW 2048 FLAT disque-flat.vmdk 0"], "ffffffff",
             .malformed("nom d'étendue sans guillemets : « RW 2048 FLAT disque-flat.vmdk 0 »")),
            (["RW deux FLAT \"disque-flat.vmdk\" 0"], "ffffffff",
             .malformed("étendue illisible : « RW deux FLAT \"disque-flat.vmdk\" 0 »")),
            (["RW 2048 FLAT"], "ffffffff", .malformed("étendue FLAT sans fichier")),
            ([], "ffffffff", .malformed("aucune étendue")),
        ]
        for (extents, parent, expected) in cases {
            let url = try descriptor(extents, parent: parent)
            XCTAssertEqual(refusal(url), expected, extents.first ?? "rien")
        }
    }

    /// **Les fichiers nommés sont cherchés à côté, et nulle part ailleurs.**
    /// Un descripteur téléchargé qui nommerait un chemin ferait lire à
    /// l'invité un fichier de l'hôte. Le fichier visé existe ici, pour que
    /// le refus ne soit pas un simple « absent ».
    func testANameOutsideTheFolderIsRefused() throws {
        let inner = folder.appendingPathComponent("dedans")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try file("disque-flat.vmdk", original)
        for name in ["../disque-flat.vmdk", "\(folder.path)/disque-flat.vmdk", "..", "dedans\\..\\x"] {
            let url = try descriptor(["RW 2048 FLAT \"\(name)\" 0"], name: "dedans/disque.vmdk")
            XCTAssertEqual(refusal(url), .fileOutsideFolder(name), name)
        }
    }

    /// Un fichier qui n'est pas un descripteur n'en est pas un, même s'il en
    /// a l'extension.
    func testSomethingElseIsNotADescriptor() throws {
        try file("autre.vmdk", Array("KDMV, mais pas vraiment".utf8))
        XCTAssertEqual(refusal(folder.appendingPathComponent("autre.vmdk")), .notADescriptor)
        XCTAssertFalse(VmdkDescriptorDisk.looksLikeOne(fileAt: folder.appendingPathComponent("autre.vmdk")))
    }

    // MARK: - Le branchement

    /// **Le disque se branche** par le chemin de tous les formats : reconnu,
    /// lu à travers ses étendues, et les écritures de l'invité vont dans la
    /// couche — ni dans le descripteur, ni dans le fichier brut.
    func testTheDiskAttachesAndItsFilesNeverChange() throws {
        try file("disque-flat.vmdk", original)
        let base = try descriptor(["RW 2048 FLAT \"disque-flat.vmdk\" 0"])
        let flat = folder.appendingPathComponent("disque-flat.vmdk")
        let before = (try Data(contentsOf: base), try Data(contentsOf: flat))
        XCTAssertTrue(VirtualDiskImages.recognizes(fileAt: base))
        XCTAssertEqual(try VirtualDiskImages.disk(fileAt: base).map(readAll), original)
        let writes = folder.appendingPathComponent("disque.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, 2048)
            XCTAssertTrue(store.write(at: 4097, [0xCA, 0xFE]))
            store.flush()
        }
        var expected = original
        expected[4097] = 0xCA
        expected[4098] = 0xFE
        XCTAssertEqual(try FileDiskStore(base: base, writes: writes).read(at: 0, count: 1 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before.0)
        XCTAssertEqual(try Data(contentsOf: flat), before.1)
    }

    /// **Le descripteur seul**, ses fichiers restés ailleurs : refusé en
    /// branchant, et le refus dit ce qui manque.
    func testADescriptorWithoutItsFilesSaysWhatIsMissing() throws {
        let base = try descriptor(["RW 2048 FLAT \"disque-flat.vmdk\" 0"])
        XCTAssertThrowsError(try FileDiskStore(base: base, writes: folder.appendingPathComponent("w"))) {
            XCTAssertEqual($0 as? FileDiskStore.Failure, .unreadableImage(
                VmdkDescriptorDisk.Refusal.missingFile("disque-flat.vmdk").errorDescription!))
        }
    }
}
