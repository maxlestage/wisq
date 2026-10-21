import XCTest
@testable import WisqVM

/// Lire un VDI — le disque de VirtualBox — sur place : contre de vrais fichiers
/// de `qemu-img`, pas contre ce que ce code croit savoir du format.
final class VdiImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vdi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Le disque d'origine des fixtures : 3 Mio de zéros et quatre motifs, un
    /// dans chacun des blocs 0 et 2 (le bloc 1 reste vide), et un qui finit
    /// le disque.
    static let original: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 3 << 20)
        bytes.replaceSubrange(0..<5, with: Array("wisq!".utf8))
        bytes.replaceSubrange(70_000..<70_004, with: Array("ABCD".utf8))
        bytes.replaceSubrange((2 << 20) + 5..<(2 << 20) + 9, with: Array("2Mio".utf8))
        bytes.replaceSubrange(((3 << 20) - 1500)..<(3 << 20), with: [UInt8](repeating: 0x5A, count: 1500))
        return bytes
    }()

    private static let dynamicSize = 2_098_176
    private static let fixedSize = 3_146_752

    private func bytes(_ base64: String, size: Int) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: size))
    }

    private func file(_ bytes: [UInt8], name: String = "\(UUID().uuidString).vdi") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func readAll(_ image: VdiImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Int(image.virtualSize))
        return image.read(into: &out, at: 0) ? out : nil
    }

    /// Le dynamique, qui n'a écrit que deux blocs sur trois, et le fixe, qui
    /// les a tous, rendent le même disque, octet pour octet.
    func testBothFormsReadBackTheSameDisk() throws {
        for (fixture, size) in [(VdiFixtures.dynamic, Self.dynamicSize), (VdiFixtures.fixed, Self.fixedSize)] {
            let image = try VdiImage(contentsOf: file(bytes(fixture, size: size)))
            XCTAssertEqual(image.virtualSize, 3 << 20, "la taille annoncée, pas celle du fichier")
            XCTAssertEqual(image.blockSize, 1 << 20)
            XCTAssertEqual(readAll(image), Self.original, "taille de fichier \(size)")
        }
    }

    /// **Une lecture qui traverse un bord de bloc se recoud.** Dans le
    /// dynamique, le bloc 1 n'existe pas dans le fichier et le bloc 2 y est le
    /// deuxième : les octets de part et d'autre du bord viennent de deux
    /// endroits sans rapport.
    func testAReadAcrossABlockBoundaryIsStitched() throws {
        let image = try VdiImage(contentsOf: file(bytes(VdiFixtures.dynamic, size: Self.dynamicSize)))
        var buffer = [UInt8](repeating: 0xEE, count: 16)
        XCTAssertTrue(image.read(into: &buffer, at: (2 << 20) - 4))
        XCTAssertEqual(buffer, Array(Self.original[((2 << 20) - 4)..<((2 << 20) + 12)]))
        XCTAssertEqual(String(decoding: buffer[9..<13], as: UTF8.self), "2Mio")
        XCTAssertFalse(image.read(into: &buffer, at: (3 << 20) - 8), "au-delà du disque")
    }

    /// Une entrée `0xFFFFFFFE`, un bloc mis à zéro, se lit en zéros — même si
    /// des octets du fichier sont toujours là.
    func testAZeroedBlockReadsAsZeros() throws {
        var raw = try bytes(VdiFixtures.dynamic, size: Self.dynamicSize)
        raw.replaceSubrange(0x200..<0x204, with: [0xFE, 0xFF, 0xFF, 0xFF])
        let image = try VdiImage(contentsOf: file(raw))
        var buffer = [UInt8](repeating: 0xEE, count: 8)
        XCTAssertTrue(image.read(into: &buffer, at: 0))
        XCTAssertEqual(buffer, [UInt8](repeating: 0, count: 8), "« wisq! » n'est plus là")
        XCTAssertTrue(image.read(into: &buffer, at: (2 << 20) + 5))
        XCTAssertEqual(String(decoding: buffer[0..<4], as: UTF8.self), "2Mio", "les autres blocs, eux, restent")
    }

    /// Ce qui serait lu « à peu près » est refusé, et nommé. Les en-têtes sont
    /// ceux d'un vrai fichier, un champ changé à la fois.
    func testWhatWouldReadWrongIsRefusedByName() throws {
        let good = try bytes(VdiFixtures.dynamic, size: Self.dynamicSize)
        func refusal(_ patch: (inout [UInt8]) -> Void) -> VdiImage.Refusal? {
            var raw = good
            patch(&raw)
            do { _ = try VdiImage(contentsOf: try file(raw)); return nil } catch {
                return error as? VdiImage.Refusal
            }
        }
        XCTAssertNil(refusal { _ in }, "le fichier intact s'ouvre")
        XCTAssertEqual(refusal { $0[0x40] = 0 }, .notVdi)
        XCTAssertEqual(refusal { $0[0x44] = 2 }, .unsupportedVersion(0x0001_0002))
        XCTAssertEqual(refusal { $0[0x4C] = 4 }, .differencing)
        XCTAssertEqual(refusal { $0[0x4C] = 3 }, .malformed("type de disque 3"))
        XCTAssertEqual(refusal { $0[0x180] = 2 }, .malformed("2 blocs pour 3145728 octets"))
        // Une table annoncée au-delà du fichier : la borne passe avant
        // l'allocation.
        XCTAssertEqual(refusal { $0[0x157] = 0x7F }, .malformed("table de blocs hors du fichier"))
    }

    /// Une entrée qui désigne un bloc au-delà du fichier fait échouer la
    /// lecture de ce bloc, au lieu de rendre des octets d'ailleurs.
    func testABlockPastTheEndOfTheFileFailsItsRead() throws {
        var raw = try bytes(VdiFixtures.dynamic, size: Self.dynamicSize)
        raw.replaceSubrange(0x208..<0x20C, with: [0x09, 0x00, 0x00, 0x00])
        let image = try VdiImage(contentsOf: file(raw))
        var buffer = [UInt8](repeating: 0, count: 8)
        XCTAssertTrue(image.read(into: &buffer, at: 0), "le bloc 0 reste lisible")
        XCTAssertFalse(image.read(into: &buffer, at: 2 << 20), "le bloc 2 pointe hors du fichier")
    }

    /// Le disque d'une machine : un `.vdi` est reconnu comme une image à
    /// lire sur place, la couche d'écriture se pose dessus comme sur une image
    /// brute, et **le fichier de VirtualBox ne change pas d'un octet**.
    func testTheOverlayWritesOnTopAndTheVdiNeverChanges() throws {
        let base = try file(bytes(VdiFixtures.dynamic, size: Self.dynamicSize), name: "linux.vdi")
        XCTAssertTrue(VirtualDiskImages.recognizes(fileAt: base))
        XCTAssertTrue(LocalDisk.isDiskImage(.virtualDisk("VDI")), "offert comme disque, plus seulement nommé")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("linux.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (3 << 20) / 512)
            // Dans le bloc que le fichier n'a pas : le reste du secteur doit
            // venir du VDI — des zéros —, pas d'un emplacement au hasard.
            XCTAssertTrue(store.write(at: (1 << 20) + 10, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = Self.original
        expected[(1 << 20) + 10] = 0xCA
        expected[(1 << 20) + 11] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 3 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
    }
}
