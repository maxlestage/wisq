import XCTest

@testable import WisqVM

/// The alternate screen left one trace behind: the saved cursor.
///
/// `testTheAlternateScreenComesAndGoesWithoutTrace` next door checks the screen
/// contents come back untouched, and they did. What it does not look at is the
/// cursor `ESC 7` saved — and there was a single slot for it, shared with the
/// alternate screen, so a save made inside a full-screen program survived onto
/// the main screen after it quit.
final class AlternateScreenCursorTests: XCTestCase {
    private func grid(feed text: String) -> TerminalGrid {
        var terminal = TerminalGrid(columns: 80, rows: 24)
        terminal.append(text)
        return terminal
    }

    /// Row 6, column 11 in the guest's 1-indexed addressing is (5, 10) here.
    private let home = "\u{1B}[6;11H"

    // MARK: - The trace that was left

    func testASaveMadeInsideTheAlternateScreenDoesNotSurviveIt() {
        let terminal = grid(
            feed: home
                + "\u{1B}7"  // le shell sauvegarde sur l'écran principal
                + "\u{1B}[?1047h"  // un programme entre, sans sauvegarde de curseur
                + "\u{1B}[2;2H\u{1B}7"  // et sauvegarde le sien
                + "\u{1B}[?1047l"  // il ressort
                + "\u{1B}8"  // le shell restaure le sien
        )
        XCTAssertEqual(
            terminal.cursor.row, 5, "la sauvegarde faite dans l'écran alterné a débordé")
        XCTAssertEqual(terminal.cursor.column, 10)
    }

    /// The other direction: what the main screen saved is not what a program
    /// finds waiting for it on a fresh alternate screen.
    func testAFreshAlternateScreenHasNothingSavedOnIt() {
        let terminal = grid(
            feed: home + "\u{1B}7"  // sauvegarde sur l'écran principal
                + "\u{1B}[?1047h"  // entrée sans sauvegarde
                + "\u{1B}[3;4H"  // le programme se place
                + "\u{1B}8"  // restaure : il n'a rien sauvegardé
        )
        XCTAssertEqual(
            terminal.cursor.row, 2,
            "l'écran alterné a hérité d'une sauvegarde faite sur l'écran principal")
        XCTAssertEqual(terminal.cursor.column, 3)
    }

    /// And a slot left by one visit is not handed to the next.
    func testASaveFromOneVisitDoesNotGreetTheNext() {
        let terminal = grid(
            feed: "\u{1B}[?1047h\u{1B}[9;9H\u{1B}7\u{1B}[?1047l"  // première visite, sauvegarde
                + home
                + "\u{1B}[?1047h"  // deuxième visite
                + "\u{1B}[3;4H\u{1B}8"  // restaure : rien à restaurer
        )
        XCTAssertEqual(terminal.cursor.row, 2, "une sauvegarde de la visite précédente a survécu")
        XCTAssertEqual(terminal.cursor.column, 3)
    }

    // MARK: - What must keep working

    /// The main screen's own save survives a visit that does not claim it.
    func testTheMainScreensSaveSurvivesAVisitThatDoesNotTouchIt() {
        let terminal = grid(
            feed: home + "\u{1B}7" + "\u{1B}[?1047h\u{1B}[2;2H\u{1B}[?1047l" + "\u{1B}8")
        XCTAssertEqual(terminal.cursor.row, 5)
        XCTAssertEqual(terminal.cursor.column, 10)
    }

    /// `?1049` still does its own job: it saves on the way in and restores on
    /// the way out.
    func testTheAlternateScreenStillRestoresTheCursorItSaved() {
        let terminal = grid(feed: home + "\u{1B}[?1049h\u{1B}[1;1H" + "\u{1B}[?1049l")
        XCTAssertEqual(terminal.cursor.row, 5)
        XCTAssertEqual(terminal.cursor.column, 10)
    }

    /// Deliberate, and pinned here so nobody "fixes" it later.
    ///
    /// `?1049h` is defined as *save cursor as in DECSC, then switch*. It writes
    /// the same slot `ESC 7` writes, on the screen it is still standing on, so
    /// it legitimately replaces an earlier save. This looked like the same
    /// defect as the ones above while probing; it is not. The difference is
    /// which screen the slot belongs to, not how many features may write it.
    func testEnteringWith1049ReplacesTheMainScreensSaveOnPurpose() {
        let terminal = grid(
            feed: home + "\u{1B}7" + "\u{1B}[3;4H" + "\u{1B}[?1049h" + "\u{1B}[?1049l" + "\u{1B}8")
        XCTAssertEqual(terminal.cursor.row, 2, "?1049h sauvegarde comme DECSC : c'est sa définition")
        XCTAssertEqual(terminal.cursor.column, 3)
    }

    /// The neighbouring test checks the screen comes back untouched. This is
    /// the same claim for the piece of state it does not look at.
    func testTheScreenStillComesBackUntouched() {
        var terminal = TerminalGrid(columns: 80, rows: 4)
        terminal.append("$ vim fichier\n")
        terminal.append("\u{1B}[?1049h\u{1B}[2J\u{1B}[H~ plein écran\u{1B}7")
        terminal.append("\u{1B}[?1049l")
        XCTAssertEqual(terminal.text, "$ vim fichier\n")
    }
}
