import XCTest
@testable import WisqVM

/// La table de partitions : celle d'une vraie image de cloud Debian, sa copie
/// de secours quand la principale est abîmée, et les MBR qu'on trouve encore
/// sur les vieilles images.
final class PartitionTableTests: XCTestCase {
    /// Un disque creux : des plages d'octets sur un fond de zéros. Une plage
    /// ajoutée plus tard recouvre les précédentes, ce qui suffit pour abîmer
    /// un octet.
    final class SparseDisk {
        let size: UInt64
        private(set) var runs: [(UInt64, [UInt8])]

        init(size: UInt64, runs: [(UInt64, [UInt8])]) {
            self.size = size
            self.runs = runs
        }

        static var debian: SparseDisk {
            SparseDisk(size: PartitionFixtures.debianSize, runs: PartitionFixtures.debianRuns.map { offset, hex in
                (offset, stride(from: 0, to: hex.count, by: 2).map {
                    let start = hex.index(hex.startIndex, offsetBy: $0)
                    return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
                })
            })
        }

        func write(_ bytes: [UInt8], at offset: UInt64) { runs.append((offset, bytes)) }

        /// Inverse un octet : la somme qui le couvre ne doit plus tenir.
        func flip(at offset: UInt64) {
            let current = read(offset, 1)![0]
            write([current ^ 0xFF], at: offset)
        }

        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard offset + UInt64(count) <= size else { return nil }
            var out = [UInt8](repeating: 0, count: count)
            for (start, bytes) in runs {
                let end = start + UInt64(bytes.count)
                guard end > offset, start < offset + UInt64(count) else { continue }
                for position in max(start, offset)..<min(end, offset + UInt64(count)) {
                    out[Int(position - offset)] = bytes[Int(position - start)]
                }
            }
            return out
        }

        func table() throws -> PartitionTable {
            try PartitionTable.read(size: size) { self.read($0, $1) }
        }
    }

    private let mib: UInt64 = 1 << 20

    /// **La vraie table.** L'image cloud de Debian 13 : une GPT de trois
    /// partitions — la racine, la petite partition où GRUB se loge pour le
    /// BIOS, et l'EFI —, numérotées comme Linux les nommera (`vda1`, `vda14`,
    /// `vda15`). C'est la racine qu'il faut fouiller pour le noyau.
    func testTheDebianCloudImageHasItsRootFirstAmongTheCandidates() throws {
        let table = try SparseDisk.debian.table()
        XCTAssertEqual(table.scheme, .gpt)
        XCTAssertEqual(table.partitions.map(\.number), [1, 14, 15])
        XCTAssertEqual(table.partitions.map(\.kind), [.linuxRoot, .biosBoot, .efiSystem])
        XCTAssertEqual(table.partitions[0].start, 262_144 * 512)
        XCTAssertEqual(table.partitions[0].length, (6_289_407 - 262_144 + 1) * 512)
        XCTAssertEqual(table.partitions[1].start, 1 * mib)
        XCTAssertEqual(table.partitions[1].length, 3 * mib)
        XCTAssertEqual(table.partitions[2].start, 4 * mib)
        XCTAssertEqual(table.partitions[2].length, 124 * mib)
        XCTAssertEqual(table.linuxCandidates.map(\.number), [1])
        // Ce que vise le `root=PARTUUID=…` de son grub.cfg et de son fstab.
        XCTAssertEqual(table.partitions[0].uniqueID, "3f7bd41d-e564-4995-bb29-b2aebe93a04c")
        XCTAssertEqual(table.partitions[2].uniqueID, "d136b129-41ec-405c-9e4c-fd190105a0c8")
    }

    /// La même table, lue dans un qcow2 : le lecteur ne voit que le disque
    /// virtuel, quel que soit le format du fichier.
    func testTheSameTableIsReadThroughAQcow2() throws {
        let packed = try XCTUnwrap(Data(base64Encoded: PartitionFixtures.debianQcow2))
        let bytes = try XCTUnwrap(Qcow2Image.inflateRaw([UInt8](packed),
                                                        expected: PartitionFixtures.debianQcow2Size))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-partitions-\(UUID().uuidString).qcow2")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try Qcow2Image(contentsOf: url)
        XCTAssertEqual(try PartitionTable.read(image), try SparseDisk.debian.table())
    }

    /// **La copie de secours.** Un octet changé dans l'en-tête principal, ou
    /// dans ses entrées, et sa somme ne tient plus : la table est relue au
    /// dernier secteur, et c'est la même.
    func testADamagedPrimaryIsReplacedByTheBackup() throws {
        let expected = try SparseDisk.debian.table()
        for offset: UInt64 in [512 + 32, 1024 + 56 + 2, 1024 + 13 * 128 + 40] {
            let disk = SparseDisk.debian
            disk.flip(at: offset)
            XCTAssertEqual(try disk.table(), expected, "octet \(offset)")
        }
        // L'en-tête principal effacé tout entier, signature comprise : le MBR
        // protecteur dit qu'une GPT doit être là, et on va la chercher.
        let erased = SparseDisk.debian
        erased.write([UInt8](repeating: 0, count: 512), at: 512)
        XCTAssertEqual(try erased.table(), expected)
    }

    /// Une table principale aux sommes justes, mais dont une partition
    /// commence avant la zone utilisable : elle n'est pas crue, et la copie de
    /// secours la remplace. Les deux sommes sont recalculées, comme le ferait
    /// un outil qui a écrit une table fausse.
    func testAPartitionOutsideTheUsableAreaIsNotBelieved() throws {
        let expected = try SparseDisk.debian.table()
        let disk = SparseDisk.debian
        disk.write([34, 0, 0, 0, 0, 0, 0, 0], at: 1024 + 32)
        let entries = try XCTUnwrap(disk.read(1024, 128 * 128))
        var header = try XCTUnwrap(disk.read(512, 92))
        func little(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        header.replaceSubrange(88..<92, with: little(CRC32.checksum(entries)))
        header.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        header.replaceSubrange(16..<20, with: little(CRC32.checksum(header)))
        disk.write(header, at: 512)
        XCTAssertEqual(try disk.table(), expected)
    }

    /// Les deux copies abîmées : refus, en disant les deux raisons, plutôt que
    /// de démarrer sur des partitions inventées.
    func testTwoDamagedCopiesAreRefused() throws {
        let disk = SparseDisk.debian
        disk.flip(at: 512 + 32)
        disk.flip(at: disk.size - 512 + 32)
        XCTAssertThrowsError(try disk.table()) { error in
            guard case .corrupt(let why) = error as? PartitionTable.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("copie de secours"), why)
        }
    }

    // MARK: - MBR

    /// Un enregistrement MBR : type, premier secteur, nombre de secteurs.
    private func record(_ type: UInt8, _ first: UInt32, _ count: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[4] = type
        for index in 0..<4 {
            bytes[8 + index] = UInt8(truncatingIfNeeded: first >> (8 * UInt32(index)))
            bytes[12 + index] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(index)))
        }
        return bytes
    }

    private func sector(_ records: [[UInt8]]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        for (index, record) in records.enumerated() {
            bytes.replaceSubrange((446 + 16 * index)..<(462 + 16 * index), with: record)
        }
        bytes[510] = 0x55
        bytes[511] = 0xAA
        return bytes
    }

    /// Un vieux disque MBR : une primaire Linux, une étendue qui porte deux
    /// logiques — Linux et swap —, numérotées 1, 5 et 6 comme Linux le fait.
    /// Chaque maillon de la chaîne est relatif au début de l'étendue, chaque
    /// partition à son maillon.
    func testAnMBRDiskWithLogicalPartitionsIsNumberedLikeLinux() throws {
        let disk = SparseDisk(size: 64 * mib, runs: [])
        disk.write(sector([record(0x83, 2048, 20480), record(0x05, 22528, 40960)]), at: 0)
        disk.write(sector([record(0x83, 2048, 10240), record(0x05, 12288, 10240)]), at: 22528 * 512)
        disk.write(sector([record(0x82, 2048, 4096), record(0x05, 24576, 10240)]), at: (22528 + 12288) * 512)
        disk.write(sector([record(0x83, 2048, 4096)]), at: (22528 + 24576) * 512)
        let table = try disk.table()
        XCTAssertEqual(table.scheme, .mbr)
        XCTAssertEqual(table.partitions.map(\.number), [1, 5, 6, 7])
        XCTAssertEqual(table.partitions.map(\.kind),
                       [.linuxFilesystem, .linuxFilesystem, .swap, .linuxFilesystem])
        XCTAssertEqual(table.partitions[1].start, (22528 + 2048) * 512)
        XCTAssertEqual(table.partitions[2].start, (22528 + 12288 + 2048) * 512)
        XCTAssertEqual(table.partitions[2].length, 4096 * 512)
        // Le troisième maillon est relatif à l'étendue, pas au maillon d'avant.
        XCTAssertEqual(table.partitions[3].start, (22528 + 24576 + 2048) * 512)
        XCTAssertEqual(table.linuxCandidates.map(\.number), [1, 5, 7])
        // Sans signature de disque, pas de PARTUUID ; avec, celui du noyau.
        XCTAssertEqual(table.partitions.map(\.uniqueID), ["", "", "", ""])
        disk.write([0xCD, 0xAB, 0x34, 0x12], at: 440)
        XCTAssertEqual(try disk.table().partitions.map(\.uniqueID),
                       ["1234abcd-01", "1234abcd-05", "1234abcd-06", "1234abcd-07"])
    }

    /// Une chaîne de logiques qui revient sur elle-même ne fait pas tourner la
    /// lecture sans fin.
    func testALogicalChainThatLoopsIsRefused() throws {
        let disk = SparseDisk(size: 64 * mib, runs: [])
        disk.write(sector([record(0x05, 2048, 40960)]), at: 0)
        disk.write(sector([record(0x83, 2048, 1024), record(0x05, 0, 40960)]), at: 2048 * 512)
        XCTAssertThrowsError(try disk.table()) { error in
            XCTAssertEqual(error as? PartitionTable.Failure,
                           .corrupt("la chaîne des partitions logiques boucle."))
        }
        // Le même maillon, vide : il n'ajoute aucune partition, et doit
        // pourtant arrêter la lecture.
        disk.write(sector([record(0, 0, 0), record(0x05, 0, 40960)]), at: 2048 * 512)
        XCTAssertThrowsError(try disk.table()) { error in
            XCTAssertEqual(error as? PartitionTable.Failure,
                           .corrupt("la chaîne des partitions logiques boucle."))
        }
    }

    /// Ce qui n'est pas une table, et une table qui déborde.
    func testNoTableAndAPartitionPastTheEndAreToldApart() throws {
        XCTAssertThrowsError(try SparseDisk(size: 64 * mib, runs: []).table()) { error in
            XCTAssertEqual(error as? PartitionTable.Failure, .noTable)
        }
        let disk = SparseDisk(size: 64 * mib, runs: [])
        disk.write(sector([record(0x83, 2048, 200_000)]), at: 0)
        XCTAssertThrowsError(try disk.table()) { error in
            XCTAssertEqual(error as? PartitionTable.Failure,
                           .corrupt("la partition 1 déborde du disque."))
        }
    }

    /// La somme de la GPT est celle de zlib : le vecteur de référence de la
    /// norme.
    func testTheChecksumIsTheIEEEOne() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
    }
}
