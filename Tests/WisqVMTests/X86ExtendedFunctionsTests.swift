import XCTest
@testable import WisqVM

/// Les fonctions du x87 que la `libm` emploie. L'oracle du vrai processeur
/// les tient sur ses vingt valeurs ; ce fichier tient ce qu'aucune liste de
/// valeurs ne couvre.
final class X86ExtendedFunctionsTests: XCTestCase {
    /// **La racine entière est juste partout**, pas seulement sur l'oracle :
    /// `r² ≤ n < (r + 1)²` pour des nombres tirés entre 2¹²⁶ et 2¹²⁸, et
    /// les deux bords. Le reste rendu est bien `n − r²`.
    func testTheIntegerSquareRootIsExactEverywhere() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        var numbers: [(high: UInt64, low: UInt64)] = [
            (0x4000_0000_0000_0000, 0), (UInt64.max, UInt64.max), (0x4000_0000_0000_0000, 1),
            (0xFFFF_FFFF_FFFF_FFFE, 1),  // (2⁶⁴ − 1)², un carré exact
        ]
        for _ in 0..<5000 { numbers.append((next() | 0x4000_0000_0000_0000, next())) }
        for number in numbers {
            let (root, remainder) = X86Extended.integerSquareRoot(number)
            let square = root.multipliedFullWidth(by: root)
            let (low, carry) = square.low.addingReportingOverflow(remainder.low)
            XCTAssertEqual(low, number.low, "r² + reste = n")
            XCTAssertEqual(square.high &+ remainder.high &+ (carry ? 1 : 0), number.high, "r² + reste = n")
            // Le reste ne dépasse pas 2r : sinon r + 1 conviendrait aussi.
            let twice = root.multipliedFullWidth(by: 2)
            XCTAssertTrue(remainder.high < twice.high
                              || (remainder.high == twice.high && remainder.low <= twice.low),
                          "le reste reste sous 2r + 1")
        }
    }
}
