import XCTest

@testable import WisqVM

/// The nine CSI sequences the grid implements and nothing held.
///
/// Measured rather than guessed: each of the twenty cases in the grid's CSI
/// table was turned into a no-op, one at a time, against the whole `WisqVMTests`
/// target. Eleven made something go red. Nine did not.
///
/// | tenue par un test | rouges | tenue par rien |
/// | --- | --- | --- |
/// | `H`,`f` position | 19 | `A` curseur haut |
/// | `J` effacer écran | 2 | `D` curseur gauche |
/// | `L` insérer lignes | 2 | `E` ligne suivante |
/// | `@` insérer caractères | 2 | `F` ligne précédente |
/// | `m` graphiques | 2 | `G`,`` ` `` colonne absolue |
/// | `B`,`e` curseur bas | 1 | `d` ligne absolue |
/// | `C`,`a` curseur droite | 1 | `X` effacer caractères |
/// | `K` effacer ligne | 1 | `S` défiler haut |
/// | `M` supprimer lignes | 1 | `T` défiler bas |
/// | `P` supprimer caractères | 1 | |
/// | `r` région de défilement | 1 | |
///
/// The shape of that table is the finding. `H`,`f` scores nineteen because
/// almost every test positions the cursor before checking something else — it
/// is held *incidentally*, by tests that are about something quite different.
/// And the pairs are split down the middle: `B` (down) and `C` (right) are
/// held, `A` (up) and `D` (left) are not. Nothing decided that. The direction a
/// test happened to need is the direction that ended up with a witness.
///
/// So these are not tests for suspected bugs — the implementations read
/// correctly, and writing them found no defect. They are the witnesses that
/// were missing, and each one was checked the only way that means anything:
/// by making its sequence a no-op again and confirming this file goes red.
final class TerminalGridUnheldSequencesTests: XCTestCase {
    private func grid(columns: Int = 20, rows: Int = 6, feed text: String = "") -> TerminalGrid {
        var terminal = TerminalGrid(columns: columns, rows: rows)
        terminal.append(text)
        return terminal
    }

    // MARK: - Les mouvements du curseur

    /// `CUU`. An editor redrawing a line above the cursor starts here.
    func testCursorUpMovesUpAndDefaultsToOne() {
        var terminal = grid(feed: "\u{1B}[4;5H")
        XCTAssertEqual(terminal.cursor.row, 3)
        terminal.append("\u{1B}[2A")
        XCTAssertEqual(terminal.cursor.row, 1, "deux lignes plus haut")
        XCTAssertEqual(terminal.cursor.column, 4, "la colonne ne bouge pas")
        terminal.append("\u{1B}[A")
        XCTAssertEqual(terminal.cursor.row, 0, "sans paramètre, une seule ligne")
    }

    /// And it stops at the top rather than walking off it.
    func testCursorUpStopsAtTheTop() {
        var terminal = grid(feed: "\u{1B}[2;3H")
        terminal.append("\u{1B}[99A")
        XCTAssertEqual(terminal.cursor.row, 0)
        XCTAssertEqual(terminal.cursor.column, 2)
    }

    /// `CUB`. The counterpart of the `C` that was already held.
    func testCursorLeftMovesLeftAndStopsAtTheMargin() {
        var terminal = grid(feed: "\u{1B}[1;10H")
        terminal.append("\u{1B}[3D")
        XCTAssertEqual(terminal.cursor.column, 6)
        terminal.append("\u{1B}[D")
        XCTAssertEqual(terminal.cursor.column, 5, "sans paramètre, une colonne")
        terminal.append("\u{1B}[99D")
        XCTAssertEqual(terminal.cursor.column, 0, "et s'arrête à la marge")
    }

    /// `CNL`: down *and* to column zero, which is what separates it from `B`.
    func testNextLineGoesDownAndToTheFirstColumn() {
        var terminal = grid(feed: "\u{1B}[2;8H")
        terminal.append("\u{1B}[2E")
        XCTAssertEqual(terminal.cursor.row, 3)
        XCTAssertEqual(terminal.cursor.column, 0, "E ramène en colonne 0, contrairement à B")
    }

    /// `CPL`: up *and* to column zero.
    func testPreviousLineGoesUpAndToTheFirstColumn() {
        var terminal = grid(feed: "\u{1B}[4;8H")
        terminal.append("\u{1B}[2F")
        XCTAssertEqual(terminal.cursor.row, 1)
        XCTAssertEqual(terminal.cursor.column, 0, "F ramène en colonne 0, contrairement à A")
    }

    /// `CHA`, and its alias `` ` ``. One-based on the wire, zero-based inside.
    func testAbsoluteColumnIsOneBasedOnTheWire() {
        var terminal = grid(feed: "\u{1B}[3;2H")
        terminal.append("\u{1B}[7G")
        XCTAssertEqual(terminal.cursor.column, 6, "le fil compte à partir de 1")
        XCTAssertEqual(terminal.cursor.row, 2, "la ligne ne bouge pas")
        terminal.append("\u{1B}[3`")
        XCTAssertEqual(terminal.cursor.column, 2, "` est le même ordre que G")
        terminal.append("\u{1B}[G")
        XCTAssertEqual(terminal.cursor.column, 0, "sans paramètre, la première colonne")
    }

    /// `VPA`, the other axis of the same idea.
    func testAbsoluteRowIsOneBasedOnTheWire() {
        var terminal = grid(feed: "\u{1B}[2;5H")
        terminal.append("\u{1B}[4d")
        XCTAssertEqual(terminal.cursor.row, 3)
        XCTAssertEqual(terminal.cursor.column, 4, "la colonne ne bouge pas")
        terminal.append("\u{1B}[d")
        XCTAssertEqual(terminal.cursor.row, 0, "sans paramètre, la première ligne")
    }

    // MARK: - Effacer sans décaler

    /// `ECH` blanks in place. That is what separates it from `P`, which pulls
    /// the tail of the line back — and `P` was held while this was not.
    func testEraseCharactersBlanksInPlaceWithoutPullingTheTailBack() {
        var terminal = grid(feed: "abcdef")
        terminal.append("\u{1B}[1;2H")   // sur le « b »
        terminal.append("\u{1B}[3X")     // efface b, c, d
        XCTAssertEqual(terminal.text, "a   ef", "les trois caractères deviennent des blancs")
        XCTAssertEqual(terminal.cursor.column, 1, "et le curseur ne bouge pas")
    }

    /// The control that separates the two: `P` closes the gap, `X` does not.
    /// Without it, an `X` wrongly implemented as `P` would pass the test above
    /// only by accident of the trailing spaces.
    func testEraseCharactersIsNotDeleteCharacters() {
        var erased = grid(feed: "abcdef")
        erased.append("\u{1B}[1;2H\u{1B}[3X")
        var deleted = grid(feed: "abcdef")
        deleted.append("\u{1B}[1;2H\u{1B}[3P")
        XCTAssertNotEqual(erased.text, deleted.text, "X efface sur place, P referme le trou")
        XCTAssertEqual(deleted.text, "aef", "P tire la fin de ligne vers la gauche")
    }

    // MARK: - Faire défiler sans bouger le curseur

    /// `SU`. The screen moves under the cursor, which stays where it is.
    ///
    /// Written against a grid with **no scrollback**, and that is not
    /// incidental. With scrollback on — the default — `S` does not lose the
    /// lines it scrolls past, it files them, and `text` is scrollback followed
    /// by screen. So the projection barely changes and an assertion on it would
    /// be measuring nothing. Probed before this was written: with the default
    /// grid, `text` after `\u{1B}[2S` is still `"un\ndeux\ntrois\nquatre"`.
    ///
    /// The archiving is the behaviour a boot log depends on, so the fix is to
    /// pick a grid where the sequence has an observable effect, not to change
    /// what the grid does.
    func testScrollUpMovesTheScreenAndLeavesTheCursor() {
        var terminal = TerminalGrid(columns: 20, rows: 4, scrollbackLines: 0)
        terminal.append("un\ndeux\ntrois\nquatre")
        terminal.append("\u{1B}[2;3H")
        terminal.append("\u{1B}[2S")
        XCTAssertEqual(terminal.text, "trois\nquatre", "les deux premières lignes sont parties")
        XCTAssertEqual(terminal.cursor.row, 1, "le curseur n'a pas suivi")
        XCTAssertEqual(terminal.cursor.column, 2)
    }

    /// And the other half of that: with scrollback on, `S` **keeps** what it
    /// scrolls past. This is what makes the test above need a special grid, so
    /// it is worth holding rather than leaving as a remark.
    func testScrollUpFilesWhatItScrollsPastWhenThereIsScrollback() {
        var terminal = grid(rows: 4, feed: "un\ndeux\ntrois\nquatre")
        terminal.append("\u{1B}[2S")
        XCTAssertTrue(terminal.text.hasPrefix("un\ndeux"), "les lignes sont archivées, pas perdues")
    }

    /// `SD`, the other direction: blank lines come in at the top.
    func testScrollDownPushesBlankLinesInAtTheTop() {
        var terminal = grid(rows: 4, feed: "un\ndeux\ntrois\nquatre")
        terminal.append("\u{1B}[1;1H")
        terminal.append("\u{1B}[2T")
        XCTAssertEqual(terminal.text, "\n\nun\ndeux", "deux lignes vides entrent par le haut")
    }

    /// Both default to one, like every other count in the table.
    func testScrollingDefaultsToOneLine() {
        // Le curseur est ramené en haut d'abord : la projection conserve la
        // ligne où il se trouve, donc le laisser en bas ajoute un « \n » final
        // qui ne dit rien du défilement. Mesuré : « b\nc\n » sinon.
        var up = TerminalGrid(columns: 20, rows: 3, scrollbackLines: 0)
        up.append("a\nb\nc")
        up.append("\u{1B}[1;1H\u{1B}[S")
        XCTAssertEqual(up.text, "b\nc")

        var down = grid(rows: 3, feed: "a\nb\nc")
        down.append("\u{1B}[T")
        XCTAssertEqual(down.text, "\na\nb")
    }
}
