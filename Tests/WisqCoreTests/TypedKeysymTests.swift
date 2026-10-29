import XCTest

@testable import WisqCore

/// **Un caractère de commande tapé ou collé devient sa touche, ou rien.**
/// Une tabulation et un retour chariot partaient comme les keysyms 0x09 et
/// 0x0D, qu'aucun serveur ne reconnaît.
final class TypedKeysymTests: XCTestCase {
    func testTheControlCharactersThatHaveAKeyBecomeIt() {
        XCTAssertEqual(Keysym.typed("\t"), Keysym.tab)
        XCTAssertEqual(Keysym.typed("\r"), Keysym.enter)
        XCTAssertEqual(Keysym.typed("\n"), Keysym.enter)
        XCTAssertEqual(Keysym.typed("\u{08}"), Keysym.backspace)
        XCTAssertEqual(Keysym.typed("\u{1B}"), Keysym.escape)
        XCTAssertEqual(Keysym.typed("\u{7F}"), Keysym.delete)
    }

    func testTheOthersAreNotSent() {
        for value: UInt32 in [0x00, 0x01, 0x07, 0x1F, 0x80, 0x9F] {
            XCTAssertNil(Keysym.typed(Unicode.Scalar(value)!), "U+\(String(value, radix: 16))")
        }
    }

    func testPrintableCharactersKeepTheirKeysym() {
        XCTAssertEqual(Keysym.typed("a"), 0x61)
        XCTAssertEqual(Keysym.typed("é"), 0xE9)
        XCTAssertEqual(Keysym.typed("€"), 0x0100_20AC)
    }
}
