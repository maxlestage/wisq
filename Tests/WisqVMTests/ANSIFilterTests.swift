import XCTest
@testable import WisqVM

final class ANSIFilterTests: XCTestCase {
    func testStripsColourCodes() {
        XCTAssertEqual(ANSIFilter.strip("\u{1B}[1;32mroot\u{1B}[0m@vm"), "root@vm")
    }

    func testStripsCursorAndClearSequences() {
        XCTAssertEqual(ANSIFilter.strip("a\u{1B}[2J\u{1B}[Hb"), "ab")
    }

    func testKeepsStructuralWhitespace() {
        XCTAssertEqual(ANSIFilter.strip("l1\nl2\tfin\r"), "l1\nl2\tfin\r")
    }

    func testCarriageReturnOverwritesTheLine() {
        XCTAssertEqual(ANSIFilter.applyLineEdits("chargement 1%\rchargement 99%"), "chargement 99%")
    }

    func testBackspaceErases() {
        XCTAssertEqual(ANSIFilter.applyLineEdits("lsx\u{8} "), "ls ")
    }
}
