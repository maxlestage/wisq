import XCTest
@testable import WisqVM

/// Les questions qu'un programme pose au terminal, et ce que la grille y
/// répond — ce qu'elle ne disait jamais.
final class TerminalGridRepliesTests: XCTestCase {
    private func replies(columns: Int = 80, rows: Int = 24, to text: String) -> String {
        var terminal = TerminalGrid(columns: columns, rows: rows)
        terminal.append(text)
        return String(decoding: terminal.takeReplies(), as: UTF8.self)
    }

    /// **La mesure de systemd**, telle qu'openSUSE l'envoie à chaque shell :
    /// le curseur au coin le plus lointain, puis « où es-tu ? ». La réponse
    /// est la taille de la grille, et le curseur revient où il était.
    func testSystemdMeasuresTheConsoleByTheCursor() {
        var terminal = TerminalGrid(columns: 80, rows: 24)
        terminal.append("prompt")
        terminal.append("\u{1B}7\u{1B}[32766;32766H\u{1B}[6n\u{1B}8")
        XCTAssertEqual(String(decoding: terminal.takeReplies(), as: UTF8.self), "\u{1B}[24;80R")
        XCTAssertEqual(terminal.cursor.row, 0)
        XCTAssertEqual(terminal.cursor.column, 6)
        XCTAssertEqual(terminal.takeReplies(), [], "une réponse n'est rendue qu'une fois")
        XCTAssertEqual(replies(columns: 132, rows: 50, to: "\u{1B}[999;999H\u{1B}[6n"), "\u{1B}[50;132R")
    }

    /// La place du curseur se compte depuis 1, ligne puis colonne.
    func testTheCursorIsReportedFromOne() {
        XCTAssertEqual(replies(to: "\u{1B}[6n"), "\u{1B}[1;1R")
        XCTAssertEqual(replies(to: "ab\ncd\u{1B}[6n"), "\u{1B}[2;3R")
    }

    /// **L'état et la nature**, et rien à ce qu'elle ne connaît pas : le
    /// second attribut (`CSI > c`), une autre question de `n`, une question
    /// privée.
    func testStatusAndIdentityAreAnsweredOtherQuestionsAreNot() {
        XCTAssertEqual(replies(to: "\u{1B}[5n"), "\u{1B}[0n")
        XCTAssertEqual(replies(to: "\u{1B}[c\u{1B}[0c"), "\u{1B}[?6c\u{1B}[?6c")
        XCTAssertEqual(replies(to: "\u{1B}[>c\u{1B}[>0c\u{1B}[15n\u{1B}[?6n\u{1B}[1c"), "")
    }

    /// Une question coupée entre deux morceaux reste une question, et les
    /// réponses suivent l'ordre des questions.
    func testASplitQuestionIsStillAnsweredInOrder() {
        var terminal = TerminalGrid()
        terminal.append("\u{1B}[5")
        XCTAssertEqual(terminal.takeReplies(), [])
        terminal.append("n\u{1B}[6n")
        XCTAssertEqual(String(decoding: terminal.takeReplies(), as: UTF8.self), "\u{1B}[0n\u{1B}[1;1R")
    }

    /// **Bornées** : mille questions que personne ne relève ne font pas
    /// grossir la grille, et la remise à zéro les oublie.
    func testUnreadRepliesAreBounded() {
        var terminal = TerminalGrid()
        terminal.append(String(repeating: "\u{1B}[5n", count: 10_000))
        XCTAssertLessThanOrEqual(terminal.replies.count, 4096)
        XCTAssertGreaterThan(terminal.replies.count, 0)
        terminal.removeAll()
        XCTAssertEqual(terminal.replies, [])
    }
}
