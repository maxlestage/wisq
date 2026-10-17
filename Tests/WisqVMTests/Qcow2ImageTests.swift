import XCTest
@testable import WisqVM

/// Lire un qcow2 sur place : contre de vrais fichiers de `qemu-img`, pas contre
/// ce que ce code croit savoir du format.
final class Qcow2ImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-qcow2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Le disque d'origine des fixtures : 1 Mio de zéros et trois motifs, dont
    /// un à cheval sur deux clusters de 4 Kio et un qui finit le disque.
    static let original: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        func put(_ offset: Int, _ count: Int, _ seed: Int) {
            for index in 0..<count { bytes[offset + index] = UInt8((index * 7 + seed) & 0xFF) }
        }
        put(0, 1024, 1)
        put(70_000, 3000, 2)
        put((1 << 20) - 1500, 1500, 3)
        return bytes
    }()

    /// Une fixture, décompressée et posée dans un fichier.
    private func image(_ base64: String, size: Int, name: String) throws -> URL {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        let bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: size))
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func readAll(_ image: Qcow2Image) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Int(image.virtualSize))
        return image.read(into: &out, at: 0) ? out : nil
    }

    /// Les quatre formes que livre `qemu-img` — v3 et v2, clusters de 4 et de
    /// 64 Kio, compressées ou non — rendent le disque d'origine, octet pour
    /// octet.
    func testEveryFormOfTheSameDiskReadsBackTheSameBytes() throws {
        let forms: [(String, Int, String, Int)] = [
            (Qcow2Fixtures.a, 32768, "v3, 4 Kio", 4096),
            (Qcow2Fixtures.b, 21504, "v3, 4 Kio, compressé", 4096),
            (Qcow2Fixtures.c, 524_288, "v2, 64 Kio", 65536),
            (Qcow2Fixtures.d, 329_216, "v3, 64 Kio, compressé", 65536),
        ]
        for (fixture, size, label, cluster) in forms {
            let disk = try Qcow2Image(contentsOf: image(fixture, size: size, name: "\(size).qcow2"))
            XCTAssertEqual(disk.virtualSize, 1 << 20, label)
            XCTAssertEqual(disk.clusterSize, cluster, label)
            XCTAssertEqual(readAll(disk), Self.original, label)
        }
    }

    /// Une lecture qui commence au milieu d'un cluster et finit dans le
    /// suivant — le motif à 70 000 est là exprès — rend les mêmes octets
    /// qu'une lecture du disque entier, compressé ou non.
    func testAReadAcrossAClusterBoundaryIsStitched() throws {
        for (fixture, size) in [(Qcow2Fixtures.a, 32768), (Qcow2Fixtures.b, 21504)] {
            let disk = try Qcow2Image(contentsOf: image(fixture, size: size, name: "\(size).qcow2"))
            var piece = [UInt8](repeating: 0xEE, count: 5000)
            XCTAssertTrue(disk.read(into: &piece, at: 69_000))
            XCTAssertEqual(piece, Array(Self.original[69_000..<74_000]))
        }
    }

    /// Le piège du format : un cluster marqué « zéro » **garde** son décalage
    /// dans le fichier, et les anciens octets y sont toujours. Les lire à
    /// travers ce décalage rendrait le motif effacé.
    func testAZeroClusterReadsAsZerosEvenWithAnOffset() throws {
        let disk = try Qcow2Image(contentsOf: image(Qcow2Fixtures.e, size: 32768, name: "z.qcow2"))
        var expected = Self.original
        for index in 0..<4096 { expected[index] = 0 }
        XCTAssertEqual(readAll(disk), expected)
    }

    /// La taille est celle que l'image annonce, pas celle du fichier : 2 Gio
    /// décrits par 384 Kio, lus au milieu sans rien allouer d'autre.
    func testTheSizeIsTheOneAnnouncedNotTheFiles() throws {
        let url = try image(Qcow2Fixtures.f, size: 393_216, name: "2g.qcow2")
        let disk = try Qcow2Image(contentsOf: url)
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
        let packed = try XCTUnwrap(Data(base64Encoded: Qcow2Fixtures.a))
        let good = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: 32768))
        func refusal(_ patch: (inout [UInt8]) -> Void) -> Qcow2Image.Refusal? {
            var bytes = good
            patch(&bytes)
            let url = folder.appendingPathComponent("\(UUID().uuidString).qcow2")
            try? Data(bytes).write(to: url)
            do { _ = try Qcow2Image(contentsOf: url); return nil } catch {
                return error as? Qcow2Image.Refusal
            }
        }
        XCTAssertNil(refusal { _ in }, "le fichier intact s'ouvre")
        XCTAssertEqual(refusal { $0[7] = 4 }, .unsupportedVersion(4))
        XCTAssertEqual(refusal { $0[35] = 1 }, .encrypted)
        XCTAssertEqual(refusal { $0[15] = 0x80 }, .backingFile)
        XCTAssertEqual(refusal { $0[79] = 0b10 }, .markedCorrupt)
        XCTAssertEqual(refusal { $0[79] = 0b100 }, .externalDataFile)
        XCTAssertEqual(refusal { $0[79] = 0b1_0000 }, .extendedL2)
        XCTAssertEqual(refusal { $0[78] = 1 }, .unknownFeatures(1 << 8))
        XCTAssertNil(refusal { $0[79] = 0b1 }, "« sale » ne touche que les compteurs : lisible")
        XCTAssertEqual(refusal { $0[0] = 0 }, .notQcow2)
        // Une table L1 annoncée plus grande que le fichier : la borne passe
        // avant l'allocation.
        XCTAssertEqual(refusal { $0[36] = 0x7F },
                       .malformed("table L1 hors du fichier"))
    }

    /// Le disque d'une machine : la couche d'écriture se pose sur le qcow2
    /// comme sur une image brute, l'invité lit ses écritures et le reste du
    /// disque d'origine, et **le fichier téléchargé ne change pas d'un octet**.
    func testTheOverlayWritesOnTopAndTheDownloadNeverChanges() throws {
        let base = try image(Qcow2Fixtures.b, size: 21504, name: "nuage.qcow2")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("nuage.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (1 << 20) / 512)
            // Une écriture partielle de secteur : le reste du secteur doit
            // venir du qcow2, décompressé, pas d'un emplacement neuf à zéro.
            XCTAssertTrue(store.write(at: 70_010, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = Self.original
        expected[70_010] = 0xCA
        expected[70_011] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 1 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
    }

    /// Un qcow2 que wisq refuse le dit au moment de brancher le disque, avec
    /// la raison, au lieu de rendre un disque faux.
    func testAnUnreadableImageIsRefusedWhenAttached() throws {
        let packed = try XCTUnwrap(Data(base64Encoded: Qcow2Fixtures.a))
        var bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: 32768))
        bytes[35] = 1
        let base = folder.appendingPathComponent("chiffre.qcow2")
        try Data(bytes).write(to: base)
        XCTAssertThrowsError(try FileDiskStore(base: base, writes: folder.appendingPathComponent("w"))) {
            XCTAssertEqual($0 as? FileDiskStore.Failure,
                           .unreadableImage("l'image qcow2 est chiffrée."))
        }
    }
}
