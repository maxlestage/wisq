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
}
