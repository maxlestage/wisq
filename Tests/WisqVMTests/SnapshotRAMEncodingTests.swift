import XCTest

@testable import WisqVM

/// L'encodage de la RAM dans un instantané : seules les longues suites de
/// zéros sont repliées, et l'ancien format se relit toujours.
final class SnapshotRAMEncodingTests: XCTestCase {
    private func encode(_ ram: [UInt8]) -> [UInt8] {
        var writer = Snapshot.Writer()
        ram.withUnsafeBytes { writer.ram($0) }
        return writer.bytes
    }

    private func decode(_ bytes: [UInt8], count: Int) throws -> [UInt8] {
        var reader = try Snapshot.Reader(bytes)
        var ram = [UInt8](repeating: 0xAA, count: count)
        try ram.withUnsafeMutableBytes { try reader.ram($0) }
        XCTAssertTrue(reader.isAtEnd)
        return ram
    }

    private func words(_ values: [UInt64]) -> [UInt8] {
        values.flatMap { value in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
    }

    /// **Les octets exacts**, pour une forme qui exerce chaque règle : une
    /// suite courte gardée dans le littéral, une longue repliée, une courte
    /// au bout. Le test Rust `the_encoding_is_the_one_the_swift_writer_produces`
    /// attend **les mêmes** : les deux écrivains ne peuvent pas diverger, même
    /// là où aucun noyau n'est là pour le démarrage différentiel.
    func testTheEncodingIsTheOneTheRustWriterProduces() {
        let ram: [UInt8] = [1, 0, 0, 1] + [UInt8](repeating: 0, count: 40) + [2, 0, 0, 0]
        let expected = Snapshot.magic
            + words([48, 3, 0, 4]) + [1, 0, 0, 1]
            + words([40, 1]) + [2]
            + words([3, 0])
        XCTAssertEqual(encode(ram), expected)
    }

    /// Une table de petits entiers — ce dont la mémoire d'un noyau est pleine
    /// — coûte ce qu'elle pèse. Replier chaque zéro la faisait presque
    /// tripler.
    func testSmallIntegersCostWhatTheyWeigh() {
        let ram = words((0..<8192).map { UInt64($0 % 1000 + 1) })
        let encoded = encode(ram)
        XCTAssertLessThanOrEqual(encoded.count, ram.count + 64)
        XCTAssertEqual(try decode(encoded, count: ram.count), ram)
    }

    /// Une mémoire surtout vide se replie toujours : c'est ce qui fait tenir
    /// une machine fraîchement démarrée en quelques mébioctets.
    func testAMostlyEmptyMemoryStillFolds() throws {
        var ram = [UInt8](repeating: 0, count: 1 << 20)
        for index in 0..<4096 { ram[index] = 0xAB }
        ram[600_000] = 7
        let encoded = encode(ram)
        XCTAssertLessThan(encoded.count, 4096 + 128)
        XCTAssertEqual(try decode(encoded, count: ram.count), ram)
    }

    /// Toutes les formes reviennent intactes, alignées ou non, avec des
    /// suites de zéros de toutes les longueurs autour du seuil.
    func testEveryShapeRoundTrips() throws {
        var shapes: [[UInt8]] = [[], [0], [9], [UInt8](repeating: 0, count: 4096)]
        for run in [1, 7, 8, 9, 31, 32, 33, 64, 1000] {
            shapes.append([5] + [UInt8](repeating: 0, count: run) + [6])
            shapes.append([UInt8](repeating: 0, count: run) + [6])
            shapes.append([5] + [UInt8](repeating: 0, count: run))
        }
        var seed: UInt64 = 42
        shapes.append((0..<10_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed >> 60 == 0 ? UInt8(truncatingIfNeeded: seed >> 33) : 0
        })
        for shape in shapes {
            XCTAssertEqual(try decode(encode(shape), count: shape.count), shape, "\(shape.count) octets")
        }
    }

    /// **L'ancien format se relit** : chaque zéro replié, même isolé. C'est ce
    /// que portent les machines déjà sauvées sur les téléphones.
    func testTheFormerEncodingStillReads() throws {
        // [1, 0, 1, 0, 0] tel que l'ancien écrivain l'écrivait : trois paires.
        let former = Snapshot.magic + words([5, 3]) + words([0, 1]) + [1]
            + words([1, 1]) + [1] + words([2, 0])
        XCTAssertEqual(try decode(former, count: 5), [1, 0, 1, 0, 0])
    }

    /// Une paire qui déborde est refusée, pas écrite à côté de la mémoire.
    func testAPairThatOverrunsIsRefused() {
        let bad = Snapshot.magic + words([4, 1]) + words([3, 2]) + [1, 1]
        XCTAssertThrowsError(try decode(bad, count: 4))
    }

    /// **Une machine reprise ne pèse que ce qu'elle porte.** Une mémoire de
    /// 512 Mio où seuls quatre mébioctets sont écrits, sauvée puis relue dans
    /// une mémoire neuve : l'hôte ne doit fournir que ces pages-là. La remise
    /// à zéro de toute la RAM avant la recopie les rendait toutes
    /// résidentes, et la création de la mémoire les écrivait déjà une fois.
    func testARestoredMachineOnlyWeighsWhatItCarries() throws {
        #if os(Linux)
        let size = 512 << 20
        let written = 4 << 20
        let source = X86Memory(size: size)
        for page in stride(from: 0, to: written, by: 4096) { source.bytes[page] = 0x5A }
        var writer = Snapshot.Writer()
        writer.ram(UnsafeRawBufferPointer(start: source.bytes, count: size))
        let encoded = writer.bytes

        let before = try Self.residentBytes()
        let target = X86Memory(size: size)
        var reader = try Snapshot.Reader(encoded)
        try reader.ram(UnsafeMutableRawBufferPointer(start: target.bytes, count: size))
        let grown = try Self.residentBytes() - before
        XCTAssertEqual(target.bytes[written - 4096], 0x5A)
        XCTAssertEqual(target.bytes[size - 1], 0)
        XCTAssertLessThan(grown, 64 << 20, "\(grown >> 20) Mio rendus résidents pour en restaurer quatre")
        #else
        throw XCTSkip("la mémoire résidente se lit dans /proc")
        #endif
    }

    #if os(Linux)
    /// Ce que le processus occupe en mémoire physique, d'après le noyau.
    private static func residentBytes() throws -> Int {
        let statm = try String(contentsOfFile: "/proc/self/statm", encoding: .utf8)
        let fields = statm.split(separator: " ")
        let pages = try XCTUnwrap(Int(fields[1]))
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    }
    #endif
}
