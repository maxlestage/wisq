import Foundation
import XCTest

@testable import WisqVM

/// La ligne qu'affiche une machine reprise sans que l'écran l'ait vue partir.
final class ResumeNoteTests: XCTestCase {
    private let paris = TimeZone(identifier: "Europe/Paris")!

    /// 20 octobre 2026, 17 h 05 à Paris (15 h 05 UTC).
    private let savedAt = Date(timeIntervalSince1970: 1_792_508_700)

    func testItGivesTheTimeAndTheAgeOnTheSameDay() {
        let note = ResumeNote.text(savedAt: savedAt, now: savedAt.addingTimeInterval(12 * 60), timeZone: paris)
        XCTAssertEqual(note, "Reprise de la sauvegarde automatique de 17 h 05 (il y a 12 min). "
                       + "Appuyez sur Entrée pour retrouver l'invite.")
    }

    func testAnOlderSaveGivesTheDate() {
        let note = ResumeNote.text(savedAt: savedAt, now: savedAt.addingTimeInterval(3 * 86_400), timeZone: paris)
        XCTAssertTrue(note.contains("du 20/10 à 17 h 05 (il y a 3 jours)"), note)
    }

    func testTheAgeIsInWords() {
        XCTAssertEqual(ResumeNote.age(from: savedAt, to: savedAt.addingTimeInterval(20)), "à l'instant")
        XCTAssertEqual(ResumeNote.age(from: savedAt, to: savedAt.addingTimeInterval(59 * 60)), "il y a 59 min")
        XCTAssertEqual(ResumeNote.age(from: savedAt, to: savedAt.addingTimeInterval(5 * 3600)), "il y a 5 h")
        XCTAssertEqual(ResumeNote.age(from: savedAt, to: savedAt.addingTimeInterval(86_400)), "il y a 1 jour")
        // Une horloge qui a reculé ne rend pas un âge négatif.
        XCTAssertEqual(ResumeNote.age(from: savedAt, to: savedAt.addingTimeInterval(-600)), "à l'instant")
    }

    /// Sans heure connue, la phrase s'en passe plutôt que d'en inventer une.
    func testWithoutADateItSaysSoWithoutOne() {
        XCTAssertEqual(ResumeNote.text(savedAt: nil, now: savedAt),
                       "Reprise de la dernière sauvegarde automatique. Appuyez sur Entrée pour retrouver l'invite.")
    }

    /// L'heure affichée est celle du fichier que la sauvegarde a écrit.
    func testTheSavedTimeIsTheFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisq-reprise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(SuspendedMachine.savedAt(kernel: "noyau", in: folder))
        try SuspendedMachine.save(Data([1, 2, 3]), kernel: "noyau", in: folder)
        let written = try XCTUnwrap(SuspendedMachine.savedAt(kernel: "noyau", in: folder))
        XCTAssertLessThan(abs(written.timeIntervalSinceNow), 60)
    }
}
