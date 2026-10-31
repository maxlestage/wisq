import XCTest
@testable import WisqVM

/// RDPMC (`0F 33`) : voir `X86Core.systemInstruction`, le cas `0x33`.
///
/// La machine du téléphone s'est arrêtée sur « l'opcode 0F 33 » au
/// redémarrage d'un invité : `perf`, qui tient un compteur pour le chien de
/// garde NMI, le relit par RDPMC.
final class X86PerformanceCounterTests: XCTestCase {
    /// Un `rdpmc` seul, ECX = `index`, les registres de sortie salis.
    static func reader(index: UInt64) throws -> X86Core {
        let memory = X86Memory(size: 0x1000, base: 0)
        try memory.load([0x0F, 0x33], at: 0)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[0] = 0xDEAD_BEEF_DEAD_BEEF
        registers[1] = index
        registers[2] = 0xDEAD_BEEF_DEAD_BEEF
        return X86Core(registers: registers, rip: 0, memory: memory)
    }

    /// **Ce que WRMSR a écrit, sur quarante-huit bits** : EAX les trente-deux
    /// du bas, EDX les seize suivants, les moitiés hautes à zéro.
    func testACounterReadsWhatWasWritten() throws {
        for index in 0..<4 as Range<UInt64> {
            var core = try Self.reader(index: index)
            core.system.modelSpecific[0xC001_0004 + UInt32(index)] = 0xFFFF_5678_9ABC_DEF0 &+ index
            _ = try core.run(budget: 1)
            XCTAssertEqual(core.rip, 2, "deux octets, retirés")
            XCTAssertEqual(core.registers[0], 0x9ABC_DEF0 &+ index)
            XCTAssertEqual(core.registers[2], 0x5678, "seize bits : le compteur en fait quarante-huit")
        }
    }

    /// Un compteur jamais écrit vaut zéro, comme un index hors des quatre —
    /// et l'instruction ne s'arrête pas pour autant.
    func testUnknownCountersReadZero() throws {
        for index: UInt64 in [0, 4, 0x4000_0000] {
            var core = try Self.reader(index: index)
            core.system.modelSpecific[0xC001_0008] = 0x1234
            _ = try core.run(budget: 1)
            XCTAssertEqual(core.rip, 2)
            XCTAssertEqual(core.registers[0], 0)
            XCTAssertEqual(core.registers[2], 0)
        }
    }
}
