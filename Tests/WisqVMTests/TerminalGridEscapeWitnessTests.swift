import Foundation
import XCTest

@testable import WisqVM

/// The three escape sequences nothing held, and why it was those three.
///
/// The previous slice measured the grid's CSI table. This one measured
/// everything else the same way — each case turned into a no-op, one at a time,
/// against the whole `WisqVMTests` target:
///
/// | tenue par un test | rouges | tenue par rien |
/// | --- | --- | --- |
/// | écran alterné `47`/`1047`/`1049` | 14 | `ESC D` index |
/// | `LF`/`VT`/`FF` retour colonne | 12 | `ESC E` ligne suivante |
/// | `CR` retour chariot | 5 | `ESC c` réinitialisation |
/// | `BS` retour arrière | 2 | |
/// | `TAB` tabulation | 2 | |
/// | `ESC M` index inverse | 1 | |
/// | mode `25` curseur visible | 1 | |
///
/// **The split is not arbitrary, and it is the same cause as last time.** The
/// controls at the top score twelve and fourteen because every test that feeds
/// text through the grid types a newline or a carriage return on its way to
/// checking something else — they are held *incidentally*, by tests about
/// something quite different. The escape sequences score zero because nobody
/// types `ESC D` by accident. Last slice, `H`,`f` scored nineteen for exactly
/// that reason; here the same mechanism runs the other way and leaves the
/// sequences no test reaches for.
///
/// So: no defect found. The implementations read correctly and writing these
/// turned up nothing wrong. They are the missing witnesses, each checked the
/// only way that means anything — by making its sequence a no-op again and
/// confirming this file goes red.
final class TerminalGridEscapeWitnessTests: XCTestCase {
    private func grid(columns: Int = 20, rows: Int = 6, feed text: String = "") -> TerminalGrid {
        var terminal = TerminalGrid(columns: columns, rows: rows)
        terminal.append(text)
        return terminal
    }

    // MARK: - ESC D, l'index

    /// `IND`. Down one line, **column untouched** — that is the whole reason it
    /// exists beside `ESC E`, and beside a bare newline this grid deliberately
    /// treats as a newline *and* a carriage return.
    func testIndexMovesDownAndKeepsTheColumn() {
        var terminal = grid(feed: "\u{1B}[2;7H")
        XCTAssertEqual(terminal.cursor.row, 1)
        XCTAssertEqual(terminal.cursor.column, 6)

        terminal.append("\u{1B}D")
        XCTAssertEqual(terminal.cursor.row, 2, "une ligne plus bas")
        XCTAssertEqual(terminal.cursor.column, 6, "et la colonne est conservée")
    }

    /// At the bottom it scrolls rather than stopping, which is what makes it an
    /// index and not a cursor move.
    func testIndexScrollsAtTheBottomInsteadOfStopping() {
        var terminal = grid(rows: 3, feed: "un\r\ndeux\r\ntrois")
        XCTAssertEqual(terminal.cursor.row, 2)

        terminal.append("\u{1B}D")
        XCTAssertEqual(terminal.cursor.row, 2, "on reste sur la dernière ligne")
        let lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "deux", "l'écran a défilé d'une ligne")
        XCTAssertEqual(lines[1], "trois")
        XCTAssertEqual(lines[2], "", "et la ligne libérée est vide")
    }

    // MARK: - ESC E, la ligne suivante

    /// `NEL`. Down one line **and** to column zero — the difference from
    /// `ESC D`, and the reason both are in the table.
    func testNextLineMovesDownAndReturnsToColumnZero() {
        var terminal = grid(feed: "\u{1B}[2;7H")
        terminal.append("\u{1B}E")
        XCTAssertEqual(terminal.cursor.row, 2)
        XCTAssertEqual(terminal.cursor.column, 0, "contrairement à ESC D, la colonne retombe à zéro")
    }

    /// And the pair, checked against each other from the same starting point:
    /// a test that only looked at the row would call these two the same thing.
    func testIndexAndNextLineDifferOnlyInTheColumn() {
        var withIndex = grid(feed: "\u{1B}[2;9H\u{1B}D")
        var withNextLine = grid(feed: "\u{1B}[2;9H\u{1B}E")

        XCTAssertEqual(withIndex.cursor.row, withNextLine.cursor.row, "même ligne")
        XCTAssertEqual(withIndex.cursor.column, 8)
        XCTAssertEqual(withNextLine.cursor.column, 0)

        // Et le texte écrit ensuite atterrit là où le curseur a été laissé.
        withIndex.append("X")
        withNextLine.append("X")
        XCTAssertEqual(withIndex.cell(atRow: 2, column: 8)?.scalar, "X")
        XCTAssertEqual(withNextLine.cell(atRow: 2, column: 0)?.scalar, "X")
    }

    /// `ESC E` scrolls at the bottom too, and lands at column zero of the row it
    /// scrolled into.
    func testNextLineScrollsAtTheBottom() {
        var terminal = grid(rows: 3, feed: "un\r\ndeux\r\ntrois\u{1B}[3;5H")
        terminal.append("\u{1B}E")
        XCTAssertEqual(terminal.cursor.row, 2)
        XCTAssertEqual(terminal.cursor.column, 0)
        XCTAssertEqual(
            terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)[0], "deux")
    }

    // MARK: - ESC c, la réinitialisation

    /// `RIS`. What a program runs when it has lost track of the terminal, so it
    /// has to leave nothing behind: no text, no cursor position, no attributes.
    func testResetClearsTheScreenAndTheCursor() {
        var terminal = grid(feed: "du texte\r\net encore\u{1B}[2;5H")
        XCTAssertTrue(terminal.screenText.contains("du texte"))

        terminal.append("\u{1B}c")
        XCTAssertEqual(terminal.cursor.row, 0, "le curseur revient en haut à gauche")
        XCTAssertEqual(terminal.cursor.column, 0)
        XCTAssertEqual(
            terminal.screenText.trimmingCharacters(in: .whitespacesAndNewlines), "",
            "et l'écran est vide")
    }

    /// A reset that left the graphic attributes behind would tint everything
    /// typed afterwards — the kind of failure that looks like a rendering bug
    /// three screens later.
    func testResetDropsTheGraphicAttributes() {
        var terminal = grid(feed: "\u{1B}[31;1mrouge et gras")
        terminal.append("\u{1B}c")
        terminal.append("A")

        let cell = terminal.cell(atRow: 0, column: 0)
        XCTAssertEqual(cell?.scalar, "A")
        XCTAssertEqual(cell?.attributes.isDefault, true, "les attributs sont ceux d'un écran neuf")
    }

    /// **The half that is not a clear.** `ESC c` keeps the scrollback: the
    /// screen is the terminal's, the history is the user's, and a reset issued
    /// by a program the user did not think about must not throw away what they
    /// scrolled up to read. This is the edge that a "reset means erase
    /// everything" reading would get wrong.
    func testResetKeepsTheScrollback() {
        var terminal = grid(rows: 3, feed: "une\r\ndeux\r\ntrois\r\nquatre\r\ncinq")
        XCTAssertTrue(terminal.text.contains("une"), "la première ligne a bien quitté l'écran")
        XCTAssertFalse(terminal.screenText.contains("une"))

        terminal.append("\u{1B}c")
        XCTAssertTrue(terminal.text.contains("une"), "l'historique survit à la réinitialisation")
        XCTAssertEqual(
            terminal.screenText.trimmingCharacters(in: .whitespacesAndNewlines), "",
            "alors que l'écran, lui, est vide")
    }
}
