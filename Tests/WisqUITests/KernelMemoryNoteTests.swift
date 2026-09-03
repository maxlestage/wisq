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

/// La ligne de stockage sous le nom d'un noyau.
final class StorageLineTests: XCTestCase {
    /// Un noyau sans machine sauvegardée n'a pas de ligne : sa taille est
    /// celle du fichier que la personne vient d'importer, elle ne la
    /// surprendra pas. Ce qui mérite d'être dit est ce qui est apparu tout
    /// seul à côté.
    func testAKernelWithNoSavedMachineSaysNothing() {
        XCTAssertNil(LocalVMListView.storageLine(nil))
        XCTAssertNil(
            LocalVMListView.storageLine(
                LocalStorage.Entry(
                    kernel: "Image", kernelBytes: 3_500_000,
                    savedMachineBytes: 0, savedMachineCount: 0)))
    }

    func testOneSavedMachineIsSaidInTheSingularWithBothSizes() throws {
        let line = try XCTUnwrap(
            LocalVMListView.storageLine(
                LocalStorage.Entry(
                    kernel: "Image", kernelBytes: 3_500_000,
                    savedMachineBytes: 12 << 20, savedMachineCount: 1)))
        XCTAssertTrue(line.contains("3,3 Mio"), line)
        XCTAssertTrue(line.contains("12,0 Mio"), line)
        XCTAssertTrue(line.contains("machine sauvegardée"), line)
        XCTAssertFalse(line.contains("machines"), line)
    }

    func testSeveralSavedMachinesAreCounted() throws {
        let line = try XCTUnwrap(
            LocalVMListView.storageLine(
                LocalStorage.Entry(
                    kernel: "Image", kernelBytes: 1024,
                    savedMachineBytes: 2048, savedMachineCount: 2)))
        XCTAssertTrue(line.contains("2 machines sauvegardées"), line)
    }
}
