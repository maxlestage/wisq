import Foundation
import XCTest
@testable import WisqVM

/// **Le niveau de la machine voyage dans l'instantané** : écrit derrière la
/// mémoire, comparé à la reprise. Une machine plus récente est refusée en le
/// disant ; un instantané d'avant la section se reprend comme avant. Voir
/// `X86Machine.snapshotLevel`.
final class X86SnapshotLevelTests: XCTestCase {
    private static let marker = Array("la machine sauvée".utf8)

    private static func savedMachine() throws -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.memory.load(marker, at: 0x10_0000)
        machine.core.rip = 0xDEAD_BEEF
        machine.core.registers[3] = 0x1234_5678
        return machine
    }

    /// Où la section commence — et elle seule : une seconde occurrence dans
    /// la mémoire ferait couper au mauvais endroit.
    private static func levelAt(in bytes: [UInt8]) throws -> Int {
        let needle = withUnsafeBytes(of: Snapshot.levelSection.littleEndian, Array.init)
        let found = (0...(bytes.count - 8)).filter { Array(bytes[$0..<($0 + 8)]) == needle }
        XCTAssertEqual(found.count, 1, "la marque du niveau doit apparaître une fois et une seule")
        return try XCTUnwrap(found.first)
    }

    func testASnapshotCarriesTheLevelOfItsMachine() throws {
        let saved = try Self.savedMachine().snapshot()
        XCTAssertEqual(X86Machine.savedLevel(in: saved), X86Machine.snapshotLevel)
        XCTAssertGreaterThanOrEqual(X86Machine.snapshotLevel, 1, "RDRAND annoncé : au moins un")
        // Juste derrière la mémoire : la pile x87 suit, et rien entre les deux.
        let bytes = [UInt8](saved)
        let at = try Self.levelAt(in: bytes)
        let x87 = withUnsafeBytes(of: Snapshot.x87Section.littleEndian, Array.init)
        XCTAssertEqual(Array(bytes[(at + 16)..<(at + 24)]), x87)
    }

    /// **Pris par une machine plus récente : refusé, et dit.** La machine qui
    /// reprend reste celle qu'elle était, mémoire comprise — et le niveau se
    /// lit quand même, pour que la phrase puisse le nommer.
    func testASnapshotFromANewerMachineIsRefusedByName() throws {
        var bytes = [UInt8](try Self.savedMachine().snapshot())
        let at = try Self.levelAt(in: bytes)
        let newer = X86Machine.snapshotLevel + 1
        bytes.replaceSubrange((at + 8)..<(at + 16), with: withUnsafeBytes(of: newer.littleEndian, Array.init))
        let data = Data(bytes)
        XCTAssertEqual(X86Machine.savedLevel(in: data), newer)

        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertThrowsError(try machine.restore(data)) { error in
            XCTAssertEqual(error as? Snapshot.Failure,
                           .newerMachine(saved: newer, supported: X86Machine.snapshotLevel))
        }
        XCTAssertEqual(machine.memory.bytes[0x10_0000], 0, "rien de la session n'est écrit")
        XCTAssertNotEqual(machine.core.rip, 0xDEAD_BEEF)
    }

    /// **Un instantané d'avant la section se reprend**, comme ceux qui
    /// attendent déjà sur les téléphones : il est de niveau zéro, et la
    /// machine revient entière.
    func testASnapshotFromBeforeTheLevelStillResumes() throws {
        let source = try Self.savedMachine()
        var bytes = [UInt8](source.snapshot())
        let at = try Self.levelAt(in: bytes)
        bytes.removeSubrange(at..<(at + 16))
        let former = Data(bytes)
        XCTAssertEqual(X86Machine.savedLevel(in: former), 0)

        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.restore(former)
        XCTAssertEqual(machine.core.rip, 0xDEAD_BEEF)
        XCTAssertEqual(machine.core.registers[3], 0x1234_5678)
        XCTAssertEqual((0..<Self.marker.count).map { machine.memory.bytes[0x10_0000 + $0] }, Self.marker)
        XCTAssertEqual(machine.snapshot(), source.snapshot(), "et elle se sauve au niveau d'aujourd'hui")
    }

    /// Des octets qui ne sont pas un instantané n'ont pas de niveau.
    func testBytesThatAreNotASnapshotHaveNoLevel() {
        XCTAssertNil(X86Machine.savedLevel(in: Data("bonjour".utf8)))
        XCTAssertNil(X86Machine.savedLevel(in: Data(Snapshot.magic + [1, 2, 3])))
    }
}
