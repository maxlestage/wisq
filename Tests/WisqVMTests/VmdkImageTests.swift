import XCTest
@testable import WisqVM

/// Lire un VMDK sur place : contre de vrais fichiers de `qemu-img`, et un
/// fichier écrit selon la spécification que `qemu-img` relit à l'identique.
final class VmdkImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vmdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Les octets d'une fixture, décompressés.
    private func bytes(_ base64: String, size: Int) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Inflate.raw([UInt8](packed), limit: size, exact: true))
    }

    /// Une fixture, posée dans un fichier.
    private func image(_ base64: String, size: Int, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes(base64, size: size)).write(to: url)
        return url
    }

    private func readAll(_ image: VmdkImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Int(image.virtualSize))
        return image.read(into: &out, at: 0) ? out : nil
    }

    /// Les trois formes — monolithicSparse, streamOptimized au répertoire en
    /// tête (`qemu-img`) et à la fin (`ovftool`) — rendent le disque
    /// d'origine, octet pour octet. C'est le même disque que celui des
    /// fixtures qcow2.
    func testEveryFormOfTheSameDiskReadsBackTheSameBytes() throws {
        let forms: [(String, Int, String)] = [
            (VmdkFixtures.a, 262_144, "monolithicSparse"),
            (VmdkFixtures.b, 132_096, "streamOptimized, répertoire en tête"),
            (VmdkFixtures.f, 72192, "streamOptimized, répertoire à la fin"),
        ]
        for (fixture, size, label) in forms {
            let disk = try VmdkImage(contentsOf: image(fixture, size: size, name: "\(size).vmdk"))
            XCTAssertEqual(disk.virtualSize, 1 << 20, label)
            XCTAssertEqual(disk.grainSize, 65536, label)
            XCTAssertEqual(readAll(disk), Qcow2ImageTests.original, label)
        }
    }

    /// Une lecture à cheval sur deux grains, compressés ou non, rend les mêmes
    /// octets qu'une lecture du disque entier.
    func testAReadAcrossAGrainBoundaryIsStitched() throws {
        for (fixture, size) in [(VmdkFixtures.a, 262_144), (VmdkFixtures.b, 132_096)] {
            let disk = try VmdkImage(contentsOf: image(fixture, size: size, name: "\(size).vmdk"))
            var piece = [UInt8](repeating: 0xEE, count: 15000)
            XCTAssertTrue(disk.read(into: &piece, at: 60000))
            XCTAssertEqual(piece, Array(Qcow2ImageTests.original[60000..<75000]))
        }
    }

    /// Un disque dont la taille n'est pas un multiple du grain : `qemu-img`
    /// compresse le dernier grain **court**, 4 Kio au lieu de 64, et sa somme
    /// ne porte que sur eux. Le décompresser comme un grain entier échouerait.
    func testAShortLastGrainIsReadToTheEndOfTheDisk() throws {
        let disk = try VmdkImage(contentsOf: image(VmdkFixtures.g, size: 132_608, name: "odd.vmdk"))
        XCTAssertEqual(disk.virtualSize, (1 << 20) + 4096)
        var expected = Qcow2ImageTests.original + [UInt8](repeating: 0, count: 4096)
        for index in 0..<100 { expected[expected.count - 100 + index] = UInt8(index) }
        XCTAssertEqual(readAll(disk), expected)
    }

    /// Un grain marqué « zéro » se lit comme des zéros, alors que le motif
    /// qu'il efface est encore dans le fichier.
    func testAZeroGrainReadsAsZeros() throws {
        let disk = try VmdkImage(contentsOf: image(VmdkFixtures.c, size: 262_144, name: "z.vmdk"))
        var expected = Qcow2ImageTests.original
        for index in 0..<65536 { expected[index] = 0 }
        XCTAssertEqual(readAll(disk), expected)
    }

    /// La taille est celle que l'image annonce : 2 Gio décrits par 384 Kio,
    /// lus au milieu.
    func testTheSizeIsTheOneAnnouncedNotTheFiles() throws {
        let disk = try VmdkImage(contentsOf: image(VmdkFixtures.d, size: 393_216, name: "2g.vmdk"))
        XCTAssertEqual(disk.virtualSize, 2 << 30)
        var piece = [UInt8](repeating: 0, count: 8192 + 1024)
        XCTAssertTrue(disk.read(into: &piece, at: (1 << 30) - 512))
        XCTAssertEqual(Array(piece[0..<512]), [UInt8](repeating: 0, count: 512))
        XCTAssertEqual(Array(piece[512..<(512 + 8192)]), [UInt8](repeating: 0xAB, count: 8192))
        XCTAssertEqual(Array(piece[(512 + 8192)...]), [UInt8](repeating: 0, count: 512))
        var past = [UInt8](repeating: 0, count: 1)
        XCTAssertFalse(disk.read(into: &past, at: 2 << 30), "au-delà du disque")
    }

    /// Ce qui serait lu « à peu près » est refusé, et nommé. Les en-têtes sont
    /// ceux d'un vrai fichier, un champ changé à la fois.
    func testWhatWouldReadWrongIsRefusedByName() throws {
        let sparse = try bytes(VmdkFixtures.a, size: 262_144)
        let stream = try bytes(VmdkFixtures.b, size: 132_096)
        func refusal(_ good: [UInt8], _ patch: (inout [UInt8]) -> Void) -> VmdkImage.Refusal? {
            var bytes = good
            patch(&bytes)
            let url = folder.appendingPathComponent("\(UUID().uuidString).vmdk")
            try? Data(bytes).write(to: url)
            do { _ = try VmdkImage(contentsOf: url); return nil } catch {
                return error as? VmdkImage.Refusal
            }
        }
        func replace(_ old: String, _ new: String) -> (inout [UInt8]) -> Void {
            { bytes in
                let from = Array(old.utf8), to = Array(new.utf8)
                guard let start = (0...(bytes.count - from.count)).first(where: {
                    Array(bytes[$0..<($0 + from.count)]) == from
                }) else { return XCTFail("« \(old) » absent") }
                bytes.replaceSubrange(start..<(start + from.count), with: to)
            }
        }
        XCTAssertNil(refusal(sparse) { _ in }, "le fichier intact s'ouvre")
        XCTAssertNil(refusal(stream) { _ in }, "le fichier intact s'ouvre")
        XCTAssertEqual(refusal(sparse) { $0[4] = 4 }, .unsupportedVersion(4))
        XCTAssertEqual(refusal(sparse) { $0[11] = 1 }, .unknownFlags(1 << 24))
        XCTAssertEqual(refusal(stream) { $0[77] = 2 }, .unknownCompression(2))
        XCTAssertEqual(refusal(sparse) { $0[77] = 1 }, .unknownCompression(1),
                       "une compression annoncée sans grains compressés")
        XCTAssertEqual(refusal(stream) { $0[10] = 0x01 },
                       .malformed("grains compressés sans marqueurs"))
        XCTAssertEqual(refusal(sparse) { $0[28] = 0 }, .notMonolithic("descripteur à part"))
        XCTAssertEqual(refusal(sparse, replace("parentCID=ffffffff", "parentCID=0badc0de")),
                       .parentDisk)
        XCTAssertEqual(refusal(sparse, replace("\"monolithicSparse\"", "\"vmfsSparse\"      ")),
                       .notMonolithic("vmfsSparse"))
        XCTAssertEqual(refusal(sparse) { $0[0] = 0 }, .notVmdk)
        // Un répertoire annoncé plus loin que le fichier : la borne passe
        // avant l'allocation.
        XCTAssertEqual(refusal(sparse) { $0[59] = 0x7F }, .malformed("répertoire hors du fichier"))
        // Le répertoire « à la fin » d'un fichier qui n'a pas de pied.
        XCTAssertEqual(refusal(sparse) { for index in 56..<64 { $0[index] = 0xFF } },
                       .malformed("répertoire annoncé en fin de fichier, pied absent"))
    }

    /// **Le morceau d'un disque découpé** a l'en-tête d'un disque entier, sa
    /// propre capacité comprise : seul son descripteur, vide, dit qu'il n'est
    /// qu'une partie. Le lire comme un disque donnerait à l'invité un disque
    /// tronqué sans le dire.
    func testThePieceOfASplitDiskIsNotTakenForTheDisk() throws {
        let piece = try image(VmdkFixtures.e, size: 262_144, name: "e-split-s001.vmdk")
        XCTAssertThrowsError(try VmdkImage(contentsOf: piece)) {
            XCTAssertEqual($0 as? VmdkImage.Refusal, .notMonolithic("type absent"))
        }
    }

    /// Un grain abîmé fait échouer la lecture — la somme Adler-32 ou le
    /// marqueur le voient —, jamais des octets devinés. Le grain 0 du
    /// streamOptimized est au secteur 128 ; son marqueur fait douze octets.
    func testADamagedGrainFailsTheReadInsteadOfReturningGuesses() throws {
        let good = try bytes(VmdkFixtures.b, size: 132_096)
        func read(_ patch: (inout [UInt8]) -> Void) throws -> Bool {
            var bytes = good
            patch(&bytes)
            let url = folder.appendingPathComponent("\(UUID().uuidString).vmdk")
            try Data(bytes).write(to: url)
            var out = [UInt8](repeating: 0, count: 4096)
            return try VmdkImage(contentsOf: url).read(into: &out, at: 0)
        }
        let grain = 128 * 512
        XCTAssertTrue(try read { _ in })
        XCTAssertFalse(try read { $0[grain + 12 + 200] ^= 0x01 }, "un octet compressé changé")
        // La somme seule, que le décodeur ne lit pas : c'est elle, et pas
        // un flux devenu illisible, qui refuse le grain.
        let length = Int(good[grain + 8]) | Int(good[grain + 9]) << 8
        XCTAssertFalse(try read { $0[grain + 12 + length - 1] ^= 0x01 }, "la somme Adler-32 changée")
        XCTAssertFalse(try read { $0[grain + 1] = 0x01 }, "le grain annonce une autre adresse")
        XCTAssertFalse(try read { $0[grain + 12] = 0x79 }, "l'en-tête zlib n'en est plus un")
    }

    /// La somme Adler-32 contre des valeurs connues — celles de la RFC 1950
    /// et de zlib — dont une assez longue pour passer par le modulo.
    func testAdler32MatchesZlib() {
        XCTAssertEqual(VmdkImage.adler32([]), 1)
        XCTAssertEqual(VmdkImage.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        XCTAssertEqual(VmdkImage.adler32([UInt8](repeating: 0xFF, count: 100_000)), 0x149A_302C)
    }

    /// Le disque d'une machine : la couche d'écriture se pose sur le VMDK
    /// comme sur une image brute, et **le fichier téléchargé ne change pas
    /// d'un octet**.
    func testTheOverlayWritesOnTopAndTheDownloadNeverChanges() throws {
        let base = try image(VmdkFixtures.f, size: 72192, name: "appliance.vmdk")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("appliance.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (1 << 20) / 512)
            // Une écriture partielle de secteur : le reste du secteur doit
            // venir du grain décompressé.
            XCTAssertTrue(store.write(at: 70_010, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = Qcow2ImageTests.original
        expected[70_010] = 0xCA
        expected[70_011] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 1 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
    }

    /// Un VMDK que wisq refuse le dit au moment de brancher le disque, avec la
    /// raison.
    func testAnUnreadableImageIsRefusedWhenAttached() throws {
        let base = try image(VmdkFixtures.e, size: 262_144, name: "e-split-s001.vmdk")
        XCTAssertThrowsError(try FileDiskStore(base: base, writes: folder.appendingPathComponent("w"))) {
            XCTAssertEqual($0 as? FileDiskStore.Failure,
                           .unreadableImage(VmdkImage.Refusal.notMonolithic("type absent").errorDescription!))
        }
    }
}
