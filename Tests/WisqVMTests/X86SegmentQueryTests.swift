import XCTest
@testable import WisqVM

/// LAR (`0F 02`) et LSL (`0F 03`) : voir `X86Core.segmentQuery`.
final class X86SegmentQueryTests: XCTestCase {
    static let gdt: UInt64 = 0x2000

    /// Un descripteur de segment, dans la forme de la machine.
    static func descriptor(limit: UInt64, access: UInt64, granular: Bool = false) -> UInt64 {
        (limit & 0xFFFF) | (access << 40) | ((limit >> 16) & 0xF) << 48 | (granular ? 1 << 55 : 0)
    }

    /// `instruction` avec ECX = `selector`, la GDT posée, EAX sali.
    static func core(_ code: [UInt8], selector: UInt64, entries: [Int: UInt64]) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        for (index, value) in entries { try memory.write(gdt &+ UInt64(index) * 8, 8, value) }
        var registers = [UInt64](repeating: 0, count: 16)
        registers[0] = 0xDEAD_BEEF_DEAD_BEEF
        registers[1] = selector
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        core.descriptorBases[0] = gdt
        core.descriptorLimits[0] = 16 * 8 - 1
        return core
    }

    /// **Ce que fait le vDSO de Linux pour `getcpu()`** : `lsl` sur l'entrée
    /// 15, un segment de données de DPL 3 dont la limite porte le numéro du
    /// processeur dans ses douze bits bas et le nœud au-dessus.
    func testLSLReadsTheCPUNumberTheWayTheVDSODoes() throws {
        let cpunode = Self.descriptor(limit: 3 | (1 << 12), access: 0xF3)  // données, DPL 3, présent
        var core = try Self.core([0x0F, 0x03, 0xC1], selector: 15 * 8 + 3, entries: [15: cpunode])
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.rip, 0x1003)
        XCTAssertEqual(core.registers[0], 3 | (1 << 12), "la limite, sur trente-deux bits, le haut à zéro")
        XCTAssertNotEqual(core.flags & X86Core.Flag.zero, 0, "ZF : lue")
    }

    /// Le bit G compte la limite en pages ; LAR rend les droits d'accès.
    func testGranularityAndAccessRights() throws {
        let flat = Self.descriptor(limit: 0xF_FFFF, access: 0x9B, granular: true)  // code, DPL 0
        var lsl = try Self.core([0x0F, 0x03, 0xC1], selector: 2 * 8, entries: [2: flat])
        _ = try lsl.run(budget: 1)
        XCTAssertEqual(lsl.registers[0], 0xFFFF_FFFF)
        var lar = try Self.core([0x0F, 0x02, 0xC1], selector: 2 * 8, entries: [2: flat])
        _ = try lar.run(budget: 1)
        XCTAssertEqual(lar.registers[0], (flat >> 32) & 0x00F0_FF00)
        XCTAssertNotEqual(lar.flags & X86Core.Flag.zero, 0)
    }

    /// **Ce qui ne se lit pas** : le sélecteur nul, la LDT, au-delà de la
    /// GDT, un descripteur système qui n'est ni LDT ni TSS, et un DPL plus
    /// petit que le RPL. ZF à zéro, et la destination intacte.
    func testWhatCannotBeReadClearsZF() throws {
        let kernelData = Self.descriptor(limit: 0xFFFF, access: 0x93)    // DPL 0
        let interruptGate = Self.descriptor(limit: 0, access: 0x8E)      // système, type E
        let cases: [(UInt64, String)] = [
            (0, "le sélecteur nul"), (2 * 8 | 4, "la LDT"), (20 * 8, "au-delà de la limite"),
            (3 * 8, "une porte d'interruption"), (2 * 8 | 3, "un DPL plus petit que le RPL"),
        ]
        for (selector, label) in cases {
            // L'entrée zéro remplie exprès : le sélecteur nul ne se lit
            // jamais, quoi qu'elle contienne.
            let userData = Self.descriptor(limit: 0xFFFF, access: 0xF3)
            var core = try Self.core([0x0F, 0x03, 0xC1], selector: selector,
                                     entries: [0: userData, 2: kernelData, 3: interruptGate])
            core.flags |= X86Core.Flag.zero
            _ = try core.run(budget: 1)
            XCTAssertEqual(core.flags & X86Core.Flag.zero, 0, label)
            XCTAssertEqual(core.registers[0], 0xDEAD_BEEF_DEAD_BEEF, "\(label) : destination intacte")
        }
    }
}
