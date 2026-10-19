import XCTest
@testable import WisqVM

/// Les seize registres rangés à plat : ils se lisent et s'écrivent comme le
/// tableau qu'ils ont remplacé.
final class X86RegistersTests: XCTestCase {
    /// Chaque registre est à lui : écrire l'un ne touche aucun autre.
    func testEachRegisterHoldsItsOwnValue() {
        var registers = X86Registers()
        for index in 0..<16 { registers[index] = 0x1111_1111_1111_1111 &* UInt64(index + 1) }
        for index in 0..<16 {
            XCTAssertEqual(registers[index], 0x1111_1111_1111_1111 &* UInt64(index + 1), "r\(index)")
        }
        registers[7] = 0
        XCTAssertEqual(registers.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(registers.count, 16)
    }

    /// Un littéral, ou un tableau plus court, est complété de zéros jusqu'à
    /// seize ; les valeurs au-delà de seize sont laissées.
    func testShortValuesArePaddedAndLongOnesCut() {
        let short: X86Registers = [1, 2, 3]
        XCTAssertEqual(Array(short), [1, 2, 3] + [UInt64](repeating: 0, count: 13))
        XCTAssertEqual(X86Registers(Array(1...20).map(UInt64.init)).last, 16)
        XCTAssertEqual(short, X86Registers([1, 2, 3, 0]))
        XCTAssertNotEqual(short, X86Registers([1, 2, 4]))
    }

    /// Une copie est une copie : le cœur est une valeur, et ses registres
    /// aussi.
    func testACopyDoesNotShareItsRegisters() {
        var original = X86Registers()
        original[4] = 0x7000
        var copy = original
        copy[4] = 0x6FF8
        XCTAssertEqual(original[4], 0x7000)
        XCTAssertEqual(copy[4], 0x6FF8)
    }
    /// **La lecture en place rend ce que rend l'indice**, pour chacun des
    /// seize, et un indice au-delà de quinze est ramené à quatre bits comme
    /// par l'indice.
    func testTheInPlaceReadAgreesWithTheSubscript() {
        var registers = X86Registers((0..<16).map { 0x1111_0000_0000_0000 &* UInt64($0) &+ UInt64($0) })
        for index in 0..<16 {
            XCTAssertEqual(registers.read(index), registers[index], "registre \(index)")
        }
        XCTAssertEqual(registers.read(17), registers[1])
    }

    /// Les préfixes de segment écrits en constante sont ceux de la table du
    /// décodeur, et rien d'autre.
    func testTheSegmentPrefixConstantIsTheDecodersFSAndGS() {
        XCTAssertEqual(X86Core.segmentPrefixes, X86Decoder.prefixBit[0x64] | X86Decoder.prefixBit[0x65])
        XCTAssertEqual(X86Core.segmentPrefixes.nonzeroBitCount, 2)
    }
}

/// Les registres de modèle, dont les bases de FS et GS sont deux champs.
final class X86ModelSpecificTests: XCTestCase {
    /// **Un dictionnaire vu du dehors** : `nil` pour ce qui n'a jamais été
    /// écrit, FS et GS compris ; la valeur écrite ensuite ; `nil` de nouveau
    /// après un effacement. Les champs directs suivent, à zéro quand rien
    /// n'est écrit — ce que rendait `?? 0`.
    func testTheBasesBehaveLikeDictionaryEntries() {
        var registers = X86ModelSpecific()
        XCTAssertNil(registers[X86SystemState.fsBase])
        XCTAssertNil(registers[X86SystemState.gsBase])
        XCTAssertEqual(registers.count, 0)
        registers[X86SystemState.gsBase] = 0xFFFF_8880_0000_0000
        registers[X86SystemState.fsBase] = 0
        registers[X86SystemState.efer] = 0x501
        XCTAssertEqual(registers[X86SystemState.gsBase], 0xFFFF_8880_0000_0000)
        XCTAssertEqual(registers[X86SystemState.fsBase], 0, "écrit à zéro n'est pas absent")
        XCTAssertEqual(registers.gsBase, 0xFFFF_8880_0000_0000)
        XCTAssertEqual(registers.count, 3)
        XCTAssertEqual(Set(registers.map(\.key)),
                       [X86SystemState.gsBase, X86SystemState.fsBase, X86SystemState.efer])
        registers[X86SystemState.gsBase] = nil
        XCTAssertNil(registers[X86SystemState.gsBase])
        XCTAssertEqual(registers.gsBase, 0)
        XCTAssertEqual(registers.count, 2)
    }

    /// `%gs:` lit la base de GS, `%fs:` celle de FS, et sans préfixe il n'y a
    /// pas de base.
    func testASegmentPrefixAddsItsOwnBase() throws {
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0)
        core.system.modelSpecific[X86SystemState.fsBase] = 0x1000
        core.system.modelSpecific[X86SystemState.gsBase] = 0x2000
        // `65 48 8b 04 25 10 00 00 00` : mov %gs:0x10,%rax ; `64 …` : %fs:.
        let gs = try X86Decoder.decode([0x65, 0x48, 0x8B, 0x04, 0x25, 0x10, 0, 0, 0])
        let fs = try X86Decoder.decode([0x64, 0x48, 0x8B, 0x04, 0x25, 0x10, 0, 0, 0])
        let plain = try X86Decoder.decode([0x48, 0x8B, 0x04, 0x25, 0x10, 0, 0, 0])
        XCTAssertEqual(core.segmentBase(gs), 0x2000)
        XCTAssertEqual(core.segmentBase(fs), 0x1000)
        XCTAssertEqual(core.segmentBase(plain), 0)
    }
}
