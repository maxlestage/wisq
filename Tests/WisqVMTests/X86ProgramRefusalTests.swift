import XCTest
@testable import WisqVM

/// Ce que la console dit d'une forme refusée à un programme : voir
/// `X86Machine.refusalNotes`.
final class X86ProgramRefusalTests: XCTestCase {
    /// **Une note par forme, une seule fois** : un programme qui réessaie en
    /// boucle ne noie pas la console.
    func testOneNotePerFormOnce() {
        var reported: Set<String> = []
        let first = X86Machine.refusalNotes(["l'opcode 0F 6F", "l'opcode 0F 6F", "l'opcode 0F EF"],
                                            reported: &reported)
        XCTAssertEqual(first.components(separatedBy: "[wisq :").count - 1, 2)
        XCTAssertTrue(first.contains("l'opcode 0F 6F") && first.contains("l'opcode 0F EF"))
        XCTAssertTrue(first.contains("Illegal instruction"), "ce que le programme a reçu")
        XCTAssertTrue(first.hasPrefix("\r\n") && first.hasSuffix("]\r\n"), "sur sa propre ligne")
        XCTAssertEqual(X86Machine.refusalNotes(["l'opcode 0F 6F"], reported: &reported), "", "déjà dite")
    }
}
