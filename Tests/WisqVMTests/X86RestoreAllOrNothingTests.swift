import Foundation
import XCTest
@testable import WisqVM

/// **Une reprise refusée ne touche pas à la mémoire.** La mémoire d'un
/// instantané s'écrivait directement dans celle de la machine, avant les
/// sections qui la suivent ; une section abîmée faisait refuser la reprise
/// avec la mémoire déjà remplacée. Voir `X86Machine.restore`.
final class X86RestoreAllOrNothingTests: XCTestCase {
    static let marker: [UInt8] = Array("la machine d'avant".utf8)

    /// Un instantané dont XCR0 a perdu son bit x87 : refusé, par construction.
    static func damagedSnapshot() throws -> Data {
        let source = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try source.memory.load(Array("la machine sauvée".utf8), at: 0x10_0000)
        var bytes = [UInt8](source.snapshot())
        let mark = withUnsafeBytes(of: Snapshot.extendedStateSection.littleEndian, Array.init)
        let at = try XCTUnwrap((0...(bytes.count - 8)).last { Array(bytes[$0..<($0 + 8)]) == mark })
        bytes.replaceSubrange((at + 8)..<(at + 16), with: [UInt8](repeating: 0, count: 8))
        return Data(bytes)
    }

    func testARefusedRestoreLeavesTheMemoryAsItWas() throws {
        let damaged = try Self.damagedSnapshot()
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.memory.load(Self.marker, at: 0x10_0000)
        XCTAssertThrowsError(try machine.restore(damaged))
        let kept = (0..<Self.marker.count).map { machine.memory.bytes[0x10_0000 + $0] }
        XCTAssertEqual(kept, Self.marker, "la mémoire est celle d'avant la reprise refusée")
    }

    /// Et l'instantané intact se reprend toujours, mémoire comprise.
    func testAnIntactSnapshotStillRestoresItsMemory() throws {
        let source = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        let saved = Array("la machine sauvée".utf8)
        try source.memory.load(saved, at: 0x10_0000)
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.memory.load(Self.marker, at: 0x10_0000)
        try machine.restore(source.snapshot())
        XCTAssertEqual((0..<saved.count).map { machine.memory.bytes[0x10_0000 + $0] }, saved)
    }
}
