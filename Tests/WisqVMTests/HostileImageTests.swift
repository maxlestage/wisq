import XCTest
@testable import WisqVM

/// **Un en-tête hostile est refusé, il ne fait pas tomber l'application.**
///
/// Chaque cas part d'une fixture saine et ne change qu'un champ, à une
/// valeur proche de 2⁶⁴ : l'arrondi `(taille + bloc − 1) / bloc`, le
/// contrôle `décalage &+ longueur <= taille du fichier` suivi de
/// `off_t(décalage)`, ou une multiplication sur un champ jamais borné
/// débordaient, et Swift arrête le programme sur un débordement. Une image
/// téléchargée ou reçue d'ailleurs ne doit pouvoir faire qu'une chose :
/// être refusée.
final class HostileImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func bytes(_ base64: String, size: Int) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: size))
    }

    private func file(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func put(_ raw: inout [UInt8], at offset: Int, _ value: UInt64, bytes count: Int, bigEndian: Bool) {
        for index in 0..<count {
            let shift = bigEndian ? 8 * (count - 1 - index) : 8 * index
            raw[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(shift))
        }
    }

    private func le(_ raw: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(raw[offset + $1]) << UInt64(8 * $1) }
    }

    // MARK: - Une taille proche de 2⁶⁴

    func testAHugeVirtualSizeIsRefused() throws {
        var qcow = try bytes(Qcow2Fixtures.a, size: 32768)
        put(&qcow, at: 24, .max, bytes: 8, bigEndian: true)
        XCTAssertThrowsError(try Qcow2Image(contentsOf: file(qcow, "a.qcow2")))

        var vdi = try bytes(VdiFixtures.dynamic, size: 2_098_176)
        put(&vdi, at: 0x170, .max, bytes: 8, bigEndian: false)
        XCTAssertThrowsError(try VdiImage(contentsOf: file(vdi, "a.vdi")))

        // La somme du pied du VHD est une simple somme d'octets : la
        // refaire est à la portée de n'importe qui.
        var vhd = try bytes(VhdFixtures.exact, size: 4_197_888)
        put(&vhd, at: 48, .max, bytes: 8, bigEndian: true)
        put(&vhd, at: 64, UInt64(VhdImage.checksum(Array(vhd[0..<512]), skipping: 64)), bytes: 4, bigEndian: true)
        XCTAssertThrowsError(try VhdImage(contentsOf: file(vhd, "a.vhd")))
    }

    // MARK: - Un décalage proche de 2⁶⁴

    func testAnOffsetNearTheEndOfTheIntegersIsRefused() throws {
        var vhd = try bytes(VhdFixtures.exact, size: 4_197_888)
        put(&vhd, at: 16, 0xFFFF_FFFF_FFFF_FF00, bytes: 8, bigEndian: true)
        put(&vhd, at: 64, UInt64(VhdImage.checksum(Array(vhd[0..<512]), skipping: 64)), bytes: 4, bigEndian: true)
        XCTAssertThrowsError(try VhdImage(contentsOf: file(vhd, "b.vhd")))

        // La région des métadonnées du VHDX, déplacée au bout des entiers,
        // dans les deux tables, leurs sommes refaites.
        var vhdx = try bytes(VhdxFixtures.dynamic, size: 10_485_760)
        for table in [0x30000, 0x40000] {
            for entry in 0..<Int(le(vhdx, table + 8, 4)) {
                let at = table + 16 + entry * 32
                if Array(vhdx[at..<(at + 16)]) == VhdxImage.metadataRegion {
                    put(&vhdx, at: at + 16, .max - 100, bytes: 8, bigEndian: false)
                }
            }
            put(&vhdx, at: table + 4, 0, bytes: 4, bigEndian: false)
            let sum = VhdxImage.checksum(Array(vhdx[table..<(table + 65536)]), skipping: 4)
            put(&vhdx, at: table + 4, UInt64(sum), bytes: 4, bigEndian: false)
        }
        XCTAssertThrowsError(try VhdxImage(contentsOf: file(vhdx, "b.vhdx")))
    }

    // MARK: - Ce qu'une lecture calcule

    /// L'espace avant chaque bloc d'un VDI n'était jamais borné : il est
    /// refusé à l'ouverture, avant la première lecture qui aurait débordé.
    func testAVdiWithAnUnboundedBlockPrefixIsRefused() throws {
        var vdi = try bytes(VdiFixtures.dynamic, size: 2_098_176)
        put(&vdi, at: 0x17C, 0xFFFF_FFFF, bytes: 4, bigEndian: false)
        XCTAssertThrowsError(try VdiImage(contentsOf: file(vdi, "c.vdi")))
    }

    /// La table des blocs du VHDX n'a pas de somme : une entrée qui nomme le
    /// dernier mébioctet des entiers fait échouer la lecture, sans plus.
    func testAVhdxBlockPointingPastTheIntegersFailsTheRead() throws {
        var vhdx = try bytes(VhdxFixtures.dynamic, size: 10_485_760)
        var bat = 0
        for entry in 0..<Int(le(vhdx, 0x30000 + 8, 4)) {
            let at = 0x30000 + 16 + entry * 32
            if Array(vhdx[at..<(at + 16)]) == VhdxImage.batRegion { bat = Int(le(vhdx, at + 16, 8)) }
        }
        XCTAssertNotEqual(bat, 0)
        put(&vhdx, at: bat, 0xFFFF_FFFF_FFF0_0006, bytes: 8, bigEndian: false)
        let image = try VhdxImage(contentsOf: file(vhdx, "d.vhdx"))
        var buffer = [UInt8](repeating: 0, count: 512)
        XCTAssertFalse(image.read(into: &buffer, at: UInt64(image.blockSize) - 512))
    }

    // MARK: - Les textes

    /// Un enregistrement pax d'une longueur démesurée s'arrête là, et ceux
    /// d'avant restent.
    func testAPaxRecordOfAnAbsurdLengthStopsTheParse() {
        let payload = Array("10 path=x\n9223372036854775807 a=b\n".utf8)
        XCTAssertEqual(OvaArchive.pax(payload), ["path": "x"])
    }

    /// Un descripteur VMDK qui annonce plus de secteurs que les entiers n'en
    /// comptent est refusé avant d'ouvrir quoi que ce soit.
    func testADescriptorWithAnAbsurdSectorCountIsRefused() throws {
        let text = "# Disk DescriptorFile\nversion=1\nparentCID=ffffffff\n"
            + "createType=\"monolithicSparse\"\nRW 1152921504606846976 SPARSE \"s.vmdk\"\n"
        let url = try file(Array(text.utf8), "e.vmdk")
        XCTAssertThrowsError(try VmdkDescriptorDisk(contentsOf: url)) {
            XCTAssertEqual($0 as? VmdkDescriptorDisk.Refusal, .malformed("taille hors de portée"))
        }
    }
}
