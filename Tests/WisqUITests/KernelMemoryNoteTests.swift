import XCTest

@testable import WisqUI
@testable import WisqVM

/// Ce que l'application dit quand la mémoire d'un noyau change.
///
/// La règle qui compte est celle du silence : une machine qui n'existait pas
/// n'a pas été oubliée, et annoncer une perte qui n'a pas eu lieu apprend à
/// ignorer le message suivant.
final class KernelMemoryNoteTests: XCTestCase {
    func testNothingLostIsNothingSaid() {
        XCTAssertNil(LocalVMListView.note(forgotten: 0))
    }

    func testOneMachineIsSaidInTheSingular() throws {
        let note = try XCTUnwrap(LocalVMListView.note(forgotten: 1))
        XCTAssertTrue(note.contains("la machine sauvegardée"), note)
        XCTAssertFalse(note.contains("machines"), note)
        XCTAssertTrue(note.contains("repart du noyau"), note)
    }

    func testSeveralMachinesAreCountedAndSaidInThePlural() throws {
        let note = try XCTUnwrap(LocalVMListView.note(forgotten: 3))
        XCTAssertTrue(note.contains("3 machines sauvegardées"), note)
        XCTAssertTrue(note.contains("ont été oubliées"), note)
    }
}
