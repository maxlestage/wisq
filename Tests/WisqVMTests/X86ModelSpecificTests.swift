import XCTest

@testable import WisqVM

/// Les MSR rangés en partie à part : ils doivent se comporter exactement
/// comme le dictionnaire qu'ils remplacent.
final class X86ModelSpecificTests: XCTestCase {
    /// Les mêmes écritures, dans les deux : mêmes lectures, même nombre, et
    /// les mêmes paires une fois triées — c'est ce que l'instantané écrit.
    func testItBehavesLikeTheDictionaryItReplaces() {
        var registers = X86ModelSpecific()
        var reference: [UInt32: UInt64] = [:]
        let numbers: [UInt32] = [X86SystemState.efer, X86SystemState.fsBase, X86SystemState.gsBase,
                                 X86SystemState.kernelGSBase, X86SystemState.star, 0x1B, 0x277]
        var seed: UInt64 = 7
        for step in 0..<200 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let number = numbers[Int(seed >> 33) % numbers.count]
            // Une écriture sur cinq efface, comme `nil` dans un dictionnaire.
            let value: UInt64? = step % 5 == 4 ? nil : seed >> 7
            registers[number] = value
            reference[number] = value
            for probe in numbers { XCTAssertEqual(registers[probe], reference[probe]) }
            XCTAssertEqual(registers.count, reference.count)
            XCTAssertEqual(registers.sorted { $0.key < $1.key }.map { [UInt64($0.key), $0.value] },
                           reference.sorted { $0.key < $1.key }.map { [UInt64($0.key), $0.value] })
        }
    }

    /// Les champs que lit le calcul d'adresse sont ceux que l'indice écrit.
    func testTheSegmentBasesAreTheFieldsTheSubscriptWrites() {
        var registers: X86ModelSpecific = [X86SystemState.fsBase: 0xF00D, X86SystemState.gsBase: 0xFEED]
        XCTAssertEqual(registers.fsBase, 0xF00D)
        XCTAssertEqual(registers.gsBase, 0xFEED)
        registers[X86SystemState.gsBase] = nil
        XCTAssertNil(registers.gsBase)
        XCTAssertEqual(registers.count, 1)
    }

    /// **`%gs:` lit la base de GS, `%fs:` celle de FS** — à travers le cœur.
    func testASegmentPrefixAddsItsOwnBase() throws {
        var core = X86Core(memory: X86Memory(size: 1 << 16))
        core.system.modelSpecific[X86SystemState.fsBase] = 0x1000
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        // `mov %fs:0x10, %eax` puis `mov %gs:0x10, %eax` : ModRM 04 25, SIB
        // sans base ni index, déplacement 0x10.
        let viaFS = try X86Decoder.decode([0x64, 0x8B, 0x04, 0x25, 0x10, 0, 0, 0])
        let viaGS = try X86Decoder.decode([0x65, 0x8B, 0x04, 0x25, 0x10, 0, 0, 0])
        XCTAssertEqual(core.segmentBase(viaFS), 0x1000)
        XCTAssertEqual(core.segmentBase(viaGS), 0x2000)
        XCTAssertEqual(try core.effectiveAddress(viaGS, X86Core.fields(viaGS)), 0x2010)
    }
}
