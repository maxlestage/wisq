import XCTest
@testable import WisqVM

/// Lire un VHD dynamique sur place : contre de vrais fichiers de `qemu-img`,
/// pas contre ce que ce code croit savoir du format.
final class VhdImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vhd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let fileSize = 4_197_888
    /// Le bloc 0 commence au secteur 4 : sa carte en 0x800, ses données en 0xA00.
    private static let firstBitmap = 0x800

    private func bytes(_ base64: String) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: Self.fileSize))
    }

    private func file(_ bytes: [UInt8], name: String = "\(UUID().uuidString).vhd") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Remet la somme de contrôle d'une structure après un champ changé :
    /// sans ça, chaque refus serait celui de la somme.
    private func resum(_ raw: inout [UInt8], at start: Int, length: Int, field: Int) {
        let sum = VhdImage.checksum(Array(raw[start..<(start + length)]), skipping: field)
        raw.replaceSubrange((start + field)..<(start + field + 4),
                            with: [UInt8(sum >> 24), UInt8(sum >> 16 & 0xFF), UInt8(sum >> 8 & 0xFF), UInt8(sum & 0xFF)])
    }

    /// Le disque entier rend celui d'origine — les deux blocs écrits et ce
    /// qu'ils ne couvrent pas.
    func testTheDiskReadsBackTheOriginal() throws {
        let image = try VhdImage(contentsOf: file(bytes(VhdFixtures.exact)))
        XCTAssertEqual(image.virtualSize, 3 << 20)
        XCTAssertEqual(image.blockSize, 2 << 20)
        var out = [UInt8](repeating: 0xEE, count: 3 << 20)
        XCTAssertTrue(image.read(into: &out, at: 0))
        XCTAssertEqual(out, VdiImageTests.original)
    }

    /// **La taille est celle du pied**, pas celle du fichier ni celle du
    /// disque qu'on a converti : `qemu-img` l'a arrondie à une géométrie, et
    /// l'invité voit ce que le pied annonce. Ce qui dépasse l'original est à
    /// zéro.
    func testTheSizeIsTheOneTheFooterAnnounces() throws {
        let image = try VhdImage(contentsOf: file(bytes(VhdFixtures.geometry)))
        XCTAssertEqual(image.virtualSize, 3_168_256)
        var out = [UInt8](repeating: 0xEE, count: Int(image.virtualSize))
        XCTAssertTrue(image.read(into: &out, at: 0))
        XCTAssertEqual(Array(out[0..<(3 << 20)]), VdiImageTests.original)
        XCTAssertEqual(Set(out[(3 << 20)...]), [0])
        XCTAssertFalse(image.read(into: &out, at: 1), "au-delà du disque")
    }

    /// **La carte des secteurs fait foi** : un secteur dont le bit est à
    /// zéro se lit en zéros, même si le fichier porte encore ses octets. Ici
    /// le bit du secteur 0 éteint, celui du secteur 136 (« ABCD », 70 000)
    /// gardé. Une lecture à cheval sur les deux voit la frontière au secteur
    /// près.
    func testASectorTheBitmapCallsUnwrittenReadsAsZeros() throws {
        var raw = try bytes(VhdFixtures.exact)
        raw[Self.firstBitmap] = 0x7F
        let image = try VhdImage(contentsOf: file(raw))
        var buffer = [UInt8](repeating: 0xEE, count: 1024)
        XCTAssertTrue(image.read(into: &buffer, at: 0))
        XCTAssertEqual(Set(buffer[0..<512]), [0], "« wisq! » n'est plus là")
        XCTAssertEqual(Array(buffer[512..<1024]), Array(VdiImageTests.original[512..<1024]))
        var abcd = [UInt8](repeating: 0, count: 4)
        XCTAssertTrue(image.read(into: &abcd, at: 70_000))
        XCTAssertEqual(String(decoding: abcd, as: UTF8.self), "ABCD")
    }

    /// Ce qui serait lu « à peu près » est refusé, et nommé. Les en-têtes sont
    /// ceux d'un vrai fichier, un champ changé à la fois — et sa somme
    /// recalculée, pour que ce soit bien le champ qui refuse.
    func testWhatWouldReadWrongIsRefusedByName() throws {
        let good = try bytes(VhdFixtures.exact)
        func refusal(_ patch: (inout [UInt8]) -> Void) -> VhdImage.Refusal? {
            var raw = good
            patch(&raw)
            do { _ = try VhdImage(contentsOf: try file(raw)); return nil } catch {
                return error as? VhdImage.Refusal
            }
        }
        XCTAssertNil(refusal { _ in }, "le fichier intact s'ouvre")
        XCTAssertEqual(refusal { $0[0] = 0 }, .notVhd)
        XCTAssertEqual(refusal { $0[63] = 4; resum(&$0, at: 0, length: 512, field: 64) }, .differencing)
        XCTAssertEqual(refusal { $0[63] = 9; resum(&$0, at: 0, length: 512, field: 64) },
                       .malformed("type de disque 9"))
        XCTAssertEqual(refusal { $0[63] = 4 }, .badChecksum("du pied"), "la somme passe avant le champ")
        XCTAssertEqual(refusal { $0[512 + 40] ^= 1 }, .badChecksum("de l'en-tête dynamique"))
        XCTAssertEqual(refusal { $0[512 + 20] = 0x7F; resum(&$0, at: 512, length: 1024, field: 36) },
                       .malformed("table de blocs hors du fichier"))
        XCTAssertEqual(refusal { $0[512 + 31] = 1; resum(&$0, at: 512, length: 1024, field: 36) },
                       .malformed("1 blocs pour 3145728 octets"))
    }

    /// Le disque d'une machine : un VHD dynamique est reconnu comme une image
    /// à lire sur place, la couche d'écriture se pose dessus, et **le fichier
    /// ne change pas d'un octet**. Le VHD *fixe*, lui, reste une image brute.
    func testTheOverlayWritesOnTopAndTheVhdNeverChanges() throws {
        let base = try file(bytes(VhdFixtures.exact), name: "azure.vhd")
        XCTAssertTrue(VirtualDiskImages.recognizes(fileAt: base))
        XCTAssertTrue(LocalDisk.isDiskImage(.virtualDisk("VHD dynamique")), "offert comme disque, plus seulement nommé")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("azure.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (3 << 20) / 512)
            XCTAssertTrue(store.write(at: 70_002, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = VdiImageTests.original
        expected[70_002] = 0xCA
        expected[70_003] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 3 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
    }
}
