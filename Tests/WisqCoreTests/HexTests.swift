import Foundation
import XCTest

@testable import WisqCore

/// One hexadecimal rendering for the whole project, and the reasons it is that
/// one.
///
/// The format is not a choice made in Swift: the Rust agent writes `&fp=` into
/// the pairing link with `format!("{byte:02x}")`, and anything the phone renders
/// has to be readable by the phone's own parser. Two private renderers used to
/// exist, in two different formats, agreeing by coincidence in the one place
/// they met.
final class HexTests: XCTestCase {
    func testTheRenderingIsLowerCaseAndUnseparated() {
        XCTAssertEqual(Hex.encode(Data([0x00, 0x0F, 0xA0, 0xFF])), "000fa0ff")
    }

    /// A byte below sixteen keeps its leading zero. Dropping it shortens the
    /// string and shifts every byte after it — the kind of mistake that leaves
    /// most fingerprints looking fine.
    func testEveryByteIsTwoCharacters() {
        let rendered = Hex.encode(Data(0...255))
        XCTAssertEqual(rendered.count, 512)
        XCTAssertTrue(rendered.hasPrefix("000102"), rendered.prefix(8).description)
    }

    func testTheRoundTripOverEveryByteValue() throws {
        let bytes = Data(0...255)
        XCTAssertEqual(try XCTUnwrap(Hex.decode(Hex.encode(bytes))), bytes)
    }

    /// Read off a terminal and retyped in capitals, it is the same fingerprint.
    /// Refusing it would be a refusal about typography.
    func testCapitalsAreAccepted() {
        XCTAssertEqual(Hex.decode("DEADBEEF"), Hex.decode("deadbeef"))
        XCTAssertEqual(Hex.decode("dEaDbEeF"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    /// The other edge: what is not hexadecimal is refused rather than guessed
    /// at. An odd length in particular, because dropping the last character
    /// would turn a truncated fingerprint into a shorter valid-looking one.
    func testWhatIsNotHexadecimalIsRefused() {
        for text in ["abc", "gg", "de ad", "de:ad", "0x1234", "déad", "–"] {
            XCTAssertNil(Hex.decode(text), text)
        }
    }

    func testTheEmptyStringIsNoBytesRatherThanARefusal() {
        XCTAssertEqual(Hex.decode(""), Data())
    }
}
