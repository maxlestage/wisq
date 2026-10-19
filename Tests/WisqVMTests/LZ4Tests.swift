import XCTest
@testable import WisqVM

/// LZ4, et le fichier compressé d'une machine sauvée.
final class LZ4Tests: XCTestCase {
    private func roundTrip(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let packed = bytes.withUnsafeBytes { LZ4.compress($0) }
        let back = try packed.withUnsafeBytes { try LZ4.decompress($0, size: bytes.count) }
        XCTAssertEqual(back, bytes, "\(bytes.count) octets", file: file, line: line)
        return packed.count
    }

    /// Ce qu'on compresse se relit, à toutes les tailles qui touchent une
    /// règle du format : rien, moins de douze octets (que des littéraux),
    /// quinze littéraux et plus (la longueur prolongée), une copie de plus
    /// de dix-neuf octets (idem), et une suite qui se répète sur elle-même.
    func testWhatIsCompressedComesBackAtEverySize() throws {
        for size in [0, 1, 4, 11, 12, 13, 15, 16, 19, 20, 64, 300, 4096] {
            _ = try roundTrip((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 3) })
        }
        let zeros = [UInt8](repeating: 0, count: 100_000)
        XCTAssertLessThan(try roundTrip(zeros), 500, "une longue suite de zéros tient en peu")
        let text = Array(String(repeating: "le shell de root, puis la reprise. ", count: 500).utf8)
        XCTAssertLessThan(try roundTrip(text), text.count / 10)
        var noise = [UInt8](repeating: 0, count: 50_000)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in noise.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            noise[index] = UInt8(truncatingIfNeeded: state)
        }
        XCTAssertLessThan(try roundTrip(noise), noise.count + noise.count / 200 + 16)
        // Une répétition plus loin que soixante-cinq mille octets : le
        // décalage n'a que deux octets, et ne doit pas s'en servir.
        let far = Array(noise[0..<1000]) + Array(noise[1000..<50_000]) + Array(noise[1000..<30_000])
            + Array(noise[0..<1000])
        _ = try roundTrip(far)
    }

    /// **Un bloc écrit par la référence se relit ici** : celui que rend
    /// `lz4.block.compress(…, store_size=False)` (python-lz4 4.4, LZ4 1.10)
    /// sur le texte ci-dessous. Et l'inverse a été vérifié une fois à la
    /// main : ce que `compress` écrit, la référence le relit.
    func testABlockWrittenByTheReferenceIsReadHere() throws {
        let original = Array(String(repeating: "wisq lit les images de cloud telles qu'elles sont telechargees. ",
                                    count: 40).utf8)
            + (0..<3).flatMap { _ in (0...255).map { UInt8($0) } } + [UInt8](repeating: 0, count: 700)
            + Array("fin".utf8)
        let block = try XCTUnwrap(Data(base64Encoded: Self.referenceBlock))
        let back = try [UInt8](block).withUnsafeBytes { try LZ4.decompress($0, size: original.count) }
        XCTAssertEqual(back, original)
    }

    static let referenceBlock = [
        "8hh3aXNxIGxpdCBsZXMgaW1hZ2VzIGRlIGNsb3VkIHRlbGxlcyBxdScJAP8Ec29udCB0ZWxlY2hhcmdlZXMuIEAA////////////",
        "tv/xAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZH",
        "SElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGS",
        "k5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd",
        "3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/wAB/+8PAQD//6hQAABmaW4=",
    ].joined()

    /// Un bloc abîmé est refusé, jamais lu de travers : coupé, avec un
    /// décalage nul, avec un décalage qui remonte avant le début, ou qui
    /// rendrait plus ou moins que la taille attendue.
    func testADamagedBlockIsRefused() throws {
        let text = Array(String(repeating: "abcdefgh", count: 100).utf8)
        let packed = text.withUnsafeBytes { LZ4.compress($0) }
        func refused(_ block: [UInt8], size: Int, _ why: String) {
            XCTAssertThrowsError(try block.withUnsafeBytes { try LZ4.decompress($0, size: size) }, why)
        }
        refused(Array(packed.dropLast(3)), size: text.count, "coupé")
        refused(packed, size: text.count + 1, "trop court")
        refused(packed, size: text.count - 1, "trop long")
        // Quatre littéraux, une copie de quatre, puis un jeton vide : huit
        // octets en tout si le décalage était bon, si bien que seul le
        // décalage peut faire refuser.
        refused([0x40, 0x61, 0x62, 0x63, 0x64, 0x00, 0x00, 0x00], size: 8, "décalage nul")
        refused([0x40, 0x61, 0x62, 0x63, 0x64, 0x05, 0x00, 0x00], size: 8, "avant le début")
        XCTAssertEqual(try [UInt8]([0x40, 0x61, 0x62, 0x63, 0x64, 0x04, 0x00, 0x00]).withUnsafeBytes {
            try LZ4.decompress($0, size: 8)
        }, Array("abcdabcd".utf8), "le même bloc, avec le bon décalage")
        refused([], size: 1, "vide")
    }

    /// **Les règles de fin du format**, que la référence suppose pour relire
    /// vite : les cinq derniers octets sont des littéraux, et la dernière
    /// copie commence douze octets au moins avant la fin. Lu en parcourant
    /// les séquences du bloc.
    func testTheBlockEndsTheWayTheFormatRequires() {
        for bytes in [[UInt8](repeating: 0, count: 5000), Array(String(repeating: "abc", count: 400).utf8),
                      Array(String(repeating: "x", count: 13).utf8)] {
            let block = bytes.withUnsafeBytes { LZ4.compress($0) }
            var read = 0, written = 0
            var lastMatchStart = 0, lastMatchEnd = 0
            func length(_ start: Int) -> Int {
                var total = start
                if start == 15 {
                    while true { let byte = Int(block[read]); read += 1; total += byte; if byte != 255 { break } }
                }
                return total
            }
            while read < block.count {
                let token = Int(block[read]); read += 1
                let literals = length(token >> 4)
                read += literals; written += literals
                if read == block.count { break }
                read += 2
                let match = length(token & 0x0F) + LZ4.minimumMatch
                lastMatchStart = written
                written += match
                lastMatchEnd = written
            }
            XCTAssertEqual(written, bytes.count)
            XCTAssertLessThanOrEqual(lastMatchEnd, bytes.count - LZ4.lastLiterals, "\(bytes.count) octets")
            XCTAssertLessThanOrEqual(lastMatchStart, bytes.count - LZ4.matchStartLimit, "\(bytes.count) octets")
        }
    }

    // MARK: - Le fichier

    /// Un bloc que la compression ferait grossir est rangé tel quel : du
    /// bruit ne coûte que son en-tête.
    func testWhatDoesNotCompressIsStoredAsIs() {
        var noise = [UInt8](repeating: 0, count: 3 << 20)
        var state: UInt64 = 7
        for index in noise.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1442695040888963407
            noise[index] = UInt8(truncatingIfNeeded: state >> 56)
        }
        let packed = SnapshotFile.pack(Data(noise))
        XCTAssertEqual(packed.count, SnapshotFile.magic.count + 8 + 3 * 4 + noise.count)
    }

    /// Le fichier compressé se relit en l'instantané d'origine, sur plusieurs
    /// blocs d'un mébioctet, un bloc incompressible rangé tel quel compris.
    func testTheFileComesBackWhole() throws {
        var snapshot = [UInt8](repeating: 0, count: 2_500_000)
        for index in stride(from: 0, to: 800_000, by: 1) { snapshot[index] = UInt8(truncatingIfNeeded: index / 10) }
        var state: UInt64 = 1
        for index in 1_100_000..<2_200_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            snapshot[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let packed = SnapshotFile.pack(Data(snapshot))
        XCTAssertLessThan(packed.count, snapshot.count * 2 / 3)
        XCTAssertEqual(try SnapshotFile.unpack(packed), Data(snapshot))
        XCTAssertEqual(try SnapshotFile.unpack(SnapshotFile.pack(Data())), Data())
    }

    /// **Un instantané d'avant se lit tel quel**, et un fichier compressé
    /// abîmé est refusé.
    func testAnOldSnapshotPassesAndADamagedFileIsRefused() throws {
        let old = Data(Snapshot.magic + [1, 2, 3, 4])
        XCTAssertEqual(try SnapshotFile.unpack(old), old)
        let packed = SnapshotFile.pack(Data(repeating: 7, count: 10_000))
        XCTAssertThrowsError(try SnapshotFile.unpack(packed.dropLast(1)))
        XCTAssertThrowsError(try SnapshotFile.unpack(packed + [0]))
        var huge = Data(SnapshotFile.magic)
        withUnsafeBytes(of: UInt64.max.littleEndian) { huge.append(contentsOf: $0) }
        XCTAssertThrowsError(try SnapshotFile.unpack(huge), "une taille annoncée démesurée")
    }

    /// Par `SuspendedMachine` : ce qui est sauvé revient, le fichier est plus
    /// petit que l'instantané, et un fichier d'avant posé à la main revient
    /// aussi.
    func testASuspendedMachineIsWrittenCompressedAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-lz4-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = Data(Snapshot.magic + [UInt8](repeating: 0, count: 1 << 20) + Array("état".utf8))
        try SuspendedMachine.save(snapshot, kernel: "debian", in: folder)
        XCTAssertEqual(SuspendedMachine.load(kernel: "debian", in: folder), snapshot)
        let file = folder.appendingPathComponent(SuspendedMachine.fileName(kernel: "debian"))
        XCTAssertLessThan(try Data(contentsOf: file).count, snapshot.count / 100)

        try snapshot.write(to: file)
        XCTAssertEqual(SuspendedMachine.load(kernel: "debian", in: folder), snapshot, "un fichier d'avant")
    }

    /// **La vraie session de Debian**, si on la donne (`WISQ_SNAPSHOT_FILE`) :
    /// ce qu'elle pèse compressée, et en combien de temps.
    func testTheRealDebianSessionShrinks() throws {
        guard let path = ProcessInfo.processInfo.environment["WISQ_SNAPSHOT_FILE"] else {
            throw XCTSkip("définir WISQ_SNAPSHOT_FILE pour ce test")
        }
        let snapshot = try Data(contentsOf: URL(fileURLWithPath: path))
        var started = Date()
        let packed = SnapshotFile.pack(snapshot)
        let packing = Date().timeIntervalSince(started)
        started = Date()
        let back = try SnapshotFile.unpack(packed)
        let unpacking = Date().timeIntervalSince(started)
        print("instantané : \(snapshot.count >> 20) Mio → \(packed.count >> 20) Mio, "
              + "compressé en \(String(format: "%.2f", packing)) s, relu en \(String(format: "%.2f", unpacking)) s")
        XCTAssertEqual(back, snapshot)
    }
}
