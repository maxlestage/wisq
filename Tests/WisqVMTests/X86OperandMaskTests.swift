import XCTest
@testable import WisqVM

/// **Le masque et le bit de signe de chaque taille d'opérande**, écrits en
/// toutes lettres. `X86Core.mask` et `signBit` se calculent sans piège
/// (`&<<`, `&*`, `&-`) : une erreur d'un bit y passerait sinon pour une
/// faute d'arithmétique ou de drapeau, loin de sa cause.
final class X86OperandMaskTests: XCTestCase {
    func testEachOperandSizeHasItsMaskAndSignBit() {
        let expected: [(size: Int, mask: UInt64, sign: UInt64)] = [
            (1, 0xFF, 0x80),
            (2, 0xFFFF, 0x8000),
            (4, 0xFFFF_FFFF, 0x8000_0000),
            (8, .max, 0x8000_0000_0000_0000),
        ]
        for (size, mask, sign) in expected {
            XCTAssertEqual(X86Core.mask(size), mask, "masque de \(size) octet(s)")
            XCTAssertEqual(X86Core.signBit(size), sign, "signe de \(size) octet(s)")
        }
        XCTAssertEqual(X86Core.mask(0), 0, "aucun octet, aucun bit — comme avant")
    }
}
