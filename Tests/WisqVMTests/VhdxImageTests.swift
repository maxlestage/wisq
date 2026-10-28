import XCTest
@testable import WisqVM

/// Lire un VHDX — le disque d'Hyper-V — sur place : contre de vrais fichiers de
/// `qemu-img`, pas contre ce que ce code croit savoir du format.
final class VhdxImageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-vhdx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let dynamicSize = 10_485_760
    private static let fixedSize = 13_631_488
    /// Où `qemu-img` range les structures du dynamique : les deux en-têtes,
    /// les deux tables des régions, la table des blocs, les métadonnées et
    /// leurs valeurs.
    private static let headers = [0x10000, 0x20000]
    private static let regionTables = [0x30000, 0x40000]
    private static let bat = 0x200000
    private static let metadata = 0x300000
    private static let fileParameters = 0x310000

    private func bytes(_ base64: String = VhdxFixtures.dynamic, size: Int = dynamicSize) throws -> [UInt8] {
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed), expected: size))
    }

    private func file(_ bytes: [UInt8], name: String = "\(UUID().uuidString).vhdx") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Remet le CRC-32C d'une structure après un champ changé : sans ça,
    /// chaque refus serait celui de la somme.
    private func resum(_ raw: inout [UInt8], at start: Int, length: Int) {
        let sum = VhdxImage.checksum(Array(raw[start..<(start + length)]), skipping: 4)
        raw.replaceSubrange((start + 4)..<(start + 8),
                            with: [UInt8(sum & 0xFF), UInt8(sum >> 8 & 0xFF), UInt8(sum >> 16 & 0xFF), UInt8(sum >> 24)])
    }

    private func setU32(_ raw: inout [UInt8], at offset: Int, _ value: UInt32) {
        raw.replaceSubrange(offset..<(offset + 4),
                            with: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }

    private func readAll(_ image: VhdxImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0xEE, count: Int(image.virtualSize))
        return image.read(into: &out, at: 0) ? out : nil
    }

    /// Le CRC-32C est celui du format, pas un CRC voisin : la valeur de
    /// contrôle de Castagnoli, et la somme que `qemu-img` a écrite.
    func testTheChecksumIsCastagnolis() throws {
        XCTAssertEqual(VhdxImage.checksum(Array("123456789".utf8), skipping: 100), 0xE306_9283)
        let raw = try bytes()
        let header = Array(raw[0x10000..<0x11000])
        let written = header[4..<8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(VhdxImage.checksum(header, skipping: 4), written)
    }

    /// Le dynamique, dont le bloc 1 n'existe pas dans le fichier, et le fixe
    /// rendent le même disque, octet pour octet.
    func testBothFormsReadBackTheSameDisk() throws {
        for (fixture, size) in [(VhdxFixtures.dynamic, Self.dynamicSize), (VhdxFixtures.fixed, Self.fixedSize)] {
            let image = try VhdxImage(contentsOf: file(bytes(fixture, size: size)))
            XCTAssertEqual(image.virtualSize, 3 << 20, "la taille annoncée, pas celle du fichier")
            XCTAssertEqual(image.blockSize, 1 << 20)
            XCTAssertEqual(readAll(image), VdiImageTests.original, "taille de fichier \(size)")
        }
    }

    /// **Une lecture qui traverse un bord de bloc se recoud** : le bloc 1 est
    /// inscrit « zéro », le bloc 2 vit à 9 Mio dans le fichier.
    func testAReadAcrossABlockBoundaryIsStitched() throws {
        let image = try VhdxImage(contentsOf: file(bytes()))
        var buffer = [UInt8](repeating: 0xEE, count: 16)
        XCTAssertTrue(image.read(into: &buffer, at: (2 << 20) - 4))
        XCTAssertEqual(buffer, Array(VdiImageTests.original[((2 << 20) - 4)..<((2 << 20) + 12)]))
        XCTAssertEqual(String(decoding: buffer[9..<13], as: UTF8.self), "2Mio")
        XCTAssertFalse(image.read(into: &buffer, at: (3 << 20) - 8), "au-delà du disque")
    }

    /// **Le plus récent des en-têtes valides fait foi.** Le plus ancien porte
    /// ici un journal en attente : le prendre ferait refuser le disque. Le
    /// plus récent abîmé, c'est l'ancien qui sert — et son journal qui
    /// refuse. Les deux abîmés, la somme est nommée.
    func testTheNewestValidHeaderWins() throws {
        var raw = try bytes()
        raw[Self.headers[0] + 48] = 1
        resum(&raw, at: Self.headers[0], length: 4096)
        XCTAssertNoThrow(try VhdxImage(contentsOf: file(raw)), "le second, plus récent, n'a pas de journal")

        raw[Self.headers[1] + 100] ^= 1
        XCTAssertThrowsError(try VhdxImage(contentsOf: file(raw))) {
            XCTAssertEqual($0 as? VhdxImage.Refusal, .pendingLog)
        }
        raw[Self.headers[0] + 100] ^= 1
        XCTAssertThrowsError(try VhdxImage(contentsOf: file(raw))) {
            XCTAssertEqual($0 as? VhdxImage.Refusal, .badChecksum("des en-têtes"))
        }
    }

    /// La première table des régions abîmée, la seconde sert ; les deux, le
    /// disque est refusé.
    func testASecondRegionTableStandsInForTheFirst() throws {
        var raw = try bytes()
        raw[Self.regionTables[0] + 200] ^= 1
        XCTAssertEqual(try readAll(VhdxImage(contentsOf: file(raw))), VdiImageTests.original)
        raw[Self.regionTables[1] + 200] ^= 1
        XCTAssertThrowsError(try VhdxImage(contentsOf: file(raw))) {
            XCTAssertEqual($0 as? VhdxImage.Refusal, .badChecksum("de la table des régions"))
        }
    }

    /// Ce qui serait lu « à peu près » est refusé, et nommé. Les structures
    /// sont celles d'un vrai fichier, un champ changé à la fois — et sa somme
    /// recalculée quand elle en a une.
    func testWhatWouldReadWrongIsRefusedByName() throws {
        let good = try bytes()
        func refusal(_ patch: (inout [UInt8]) -> Void) -> VhdxImage.Refusal? {
            var raw = good
            patch(&raw)
            do { _ = try VhdxImage(contentsOf: try file(raw)); return nil } catch {
                return error as? VhdxImage.Refusal
            }
        }
        XCTAssertNil(refusal { _ in }, "le fichier intact s'ouvre")
        XCTAssertEqual(refusal { $0[0] = 0 }, .notVhdx)
        XCTAssertEqual(refusal { $0[Self.headers[1] + 48] = 1; resum(&$0, at: Self.headers[1], length: 4096) },
                       .pendingLog)
        XCTAssertEqual(refusal { $0[Self.headers[1] + 66] = 2; resum(&$0, at: Self.headers[1], length: 4096) },
                       .malformed("version 2"))
        XCTAssertEqual(refusal { $0[Self.fileParameters + 4] = 2 }, .differencing)
        XCTAssertEqual(refusal { setU32(&$0, at: Self.fileParameters, 3 << 20) },
                       .malformed("bloc de 3145728 octets"))
        XCTAssertEqual(refusal { setU32(&$0, at: Self.fileParameters + 0x20, 1024) },
                       .malformed("secteur de 1024 octets"))
        // L'identifiant SCSI, marqué obligatoire, changé en un GUID inconnu.
        XCTAssertEqual(refusal { $0[Self.metadata + 32 + 64] ^= 0xFF }, .malformed("métadonnée obligatoire inconnue"))
        XCTAssertEqual(refusal { $0[Self.metadata] = 0 }, .malformed("table des métadonnées absente"))
        // Une table des blocs de huit octets : trop courte pour trois blocs,
        // et la borne passe avant la lecture.
        XCTAssertEqual(refusal {
            for table in Self.regionTables {
                setU32(&$0, at: table + 16 + 24, 8)
                resum(&$0, at: table, length: 64 << 10)
            }
        }, .malformed("table de blocs hors du fichier"))
        XCTAssertEqual(refusal {
            for table in Self.regionTables {
                $0[table + 16 + 28] = 1
                $0[table + 16] ^= 0xFF
                resum(&$0, at: table, length: 64 << 10)
            }
        }, .malformed("région obligatoire inconnue"))
    }

    /// **L'état d'un bloc décide de sa lecture** : démappé, il se lit en
    /// zéros même si ses octets sont toujours dans le fichier ; « en partie
    /// présent », qui n'a de sens qu'avec un parent, fait échouer la lecture ;
    /// une adresse au-delà du fichier aussi.
    func testTheStateOfABlockDecidesHowItReads() throws {
        func image(block0State state: UInt8) throws -> VhdxImage {
            var raw = try bytes()
            raw[Self.bat] = raw[Self.bat] & ~7 | state
            return try VhdxImage(contentsOf: file(raw))
        }
        var buffer = [UInt8](repeating: 0xEE, count: 8)
        XCTAssertTrue(try image(block0State: 3).read(into: &buffer, at: 0))
        XCTAssertEqual(buffer, [UInt8](repeating: 0, count: 8), "« wisq! » n'est plus là")
        XCTAssertFalse(try image(block0State: 7).read(into: &buffer, at: 0))
        XCTAssertFalse(try image(block0State: 5).read(into: &buffer, at: 0), "un état inconnu")

        var raw = try bytes()
        // Le bit fort : une adresse au-delà de ce que `pread` sait
        // seulement demander.
        raw[Self.bat + 16 + 7] = 0xFF
        let far = try VhdxImage(contentsOf: file(raw))
        XCTAssertTrue(far.read(into: &buffer, at: 0), "le bloc 0 reste lisible")
        XCTAssertFalse(far.read(into: &buffer, at: 2 << 20), "le bloc 2 pointe hors du fichier")
    }

    /// **Les entrées des cartes de secteurs sont sautées.** Avec des blocs de
    /// 256 Mio, une carte couvre seize blocs, et la dix-septième entrée de la
    /// table est la sienne : le bloc 16 est à la dix-huitième. Le fichier de
    /// `qemu-img` est trop petit pour le montrer ; ses métadonnées, qui n'ont
    /// pas de somme, sont changées pour un disque de dix-sept blocs, et la
    /// carte pointe sur les données du bloc 0, que le lecteur ne doit pas
    /// rendre.
    func testTheSectorBitmapEntriesAreSkipped() throws {
        var raw = try bytes()
        setU32(&raw, at: Self.fileParameters, 256 << 20)
        let size = UInt64(17) * (256 << 20)
        setU32(&raw, at: Self.fileParameters + 8, UInt32(size & 0xFFFF_FFFF))
        setU32(&raw, at: Self.fileParameters + 12, UInt32(size >> 32))
        func entry(_ index: Int, megabyte: UInt32) -> (Int, [UInt8]) {
            let value = UInt64(megabyte) << 20 | 6
            return (Self.bat + index * 8, (0..<8).map { UInt8(value >> ($0 * 8) & 0xFF) })
        }
        for (at, value) in [entry(16, megabyte: 8), entry(17, megabyte: 9)] {
            raw.replaceSubrange(at..<(at + 8), with: value)
        }
        let image = try VhdxImage(contentsOf: file(raw))
        var buffer = [UInt8](repeating: 0, count: 4)
        XCTAssertTrue(image.read(into: &buffer, at: 16 * (256 << 20) + 5))
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "2Mio")
    }

    /// Le disque d'une machine : un `.vhdx` est reconnu comme une image à
    /// lire sur place, la couche d'écriture se pose dessus, et **le fichier
    /// d'Hyper-V ne change pas d'un octet**.
    func testTheOverlayWritesOnTopAndTheVhdxNeverChanges() throws {
        let base = try file(bytes(), name: "serveur.vhdx")
        XCTAssertTrue(VirtualDiskImages.recognizes(fileAt: base))
        XCTAssertTrue(LocalDisk.isDiskImage(.virtualDisk("VHDX")), "offert comme disque, plus seulement nommé")
        let before = try Data(contentsOf: base)
        let writes = folder.appendingPathComponent("serveur.writes")
        do {
            let store = try FileDiskStore(base: base, writes: writes)
            XCTAssertEqual(store.sectors, (3 << 20) / 512)
            // Dans le bloc inscrit « zéro » : le reste du secteur doit venir
            // du VHDX — des zéros —, pas d'un emplacement au hasard.
            XCTAssertTrue(store.write(at: (1 << 20) + 10, [0xCA, 0xFE]))
            store.flush()
        }
        let store = try FileDiskStore(base: base, writes: writes)
        var expected = VdiImageTests.original
        expected[(1 << 20) + 10] = 0xCA
        expected[(1 << 20) + 11] = 0xFE
        XCTAssertEqual(store.read(at: 0, count: 3 << 20), expected)
        XCTAssertEqual(try Data(contentsOf: base), before)
    }
}
