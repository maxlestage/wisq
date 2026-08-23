import XCTest
@testable import WisqVM

/// The grid, held to what real programs do to it. Every named test is a
/// behaviour some actual guest depends on: a boot log, a shell, an editor,
/// `top`. The old line-stream console's tests live on here — chunk splits,
/// carriage-return redraws, bounded scrollback — because the grid must not
/// regress the boot log to gain the editor.
final class TerminalGridTests: XCTestCase {
    private func grid(columns: Int = 80, rows: Int = 24, feed text: String = "") -> TerminalGrid {
        var terminal = TerminalGrid(columns: columns, rows: rows)
        terminal.append(text)
        return terminal
    }

    // MARK: - The boot log must read as it always did

    func testPlainLinesFlowLikeAConsole() {
        let terminal = grid(feed: "Booting Linux...\nrv32ima at 160 MIPS\n~ #")
        XCTAssertEqual(terminal.text, "Booting Linux...\nrv32ima at 160 MIPS\n~ #")
    }

    func testStripsColourSequencesFromTheProjection() {
        let terminal = grid(feed: "\u{1B}[1;32mOK\u{1B}[0m done")
        XCTAssertEqual(terminal.text, "OK done")
    }

    func testCarriageReturnRedrawsTheLine() {
        let terminal = grid(feed: "10%\r20%\r30%")
        XCTAssertEqual(terminal.text, "30%")
    }

    func testCarriageReturnKeepsWhatTheRedrawDoesNotCover() {
        let terminal = grid(feed: "progress 10\rp")
        XCTAssertEqual(terminal.text, "progress 10")
    }

    func testBackspaceMovesWithoutErasing() {
        var terminal = grid(feed: "abc\u{08}")
        XCTAssertEqual(terminal.cursor.column, 2)
        terminal.append("X")
        XCTAssertEqual(terminal.text, "abX")
    }

    func testBackspaceStopsAtColumnZero() {
        let terminal = grid(feed: "\u{08}\u{08}x")
        XCTAssertEqual(terminal.text, "x")
    }

    func testTabAdvancesToTheNextStop() {
        var terminal = grid(feed: "ab\ty")
        XCTAssertEqual(terminal.text, "ab      y")
        terminal.append("\r\t z")
        XCTAssertEqual(terminal.cursor.column, 10)
    }

    func testEscapeSequenceSplitAcrossChunks() {
        var terminal = grid(feed: "ok \u{1B}[3")
        terminal.append("1mrouge\u{1B}[0m")
        XCTAssertEqual(terminal.text, "ok rouge")
    }

    func testOSCSequenceSplitAcrossChunks() {
        var terminal = grid(feed: "\u{1B}]0;titre")
        terminal.append("\u{07}visible")
        XCTAssertEqual(terminal.text, "visible")
    }

    func testChunkingDoesNotChangeTheResult() {
        let script = "Linux version 6.1\n\u{1B}[1mOK\u{1B}[0m\rDone\nlogin: "
        let whole = grid(feed: script)
        var byBytes = TerminalGrid()
        for byte in Array(script.utf8) {
            byBytes.append(Data([byte]))
        }
        XCTAssertEqual(whole.text, byBytes.text)
    }

    func testDecodesGuestBytes() {
        var terminal = TerminalGrid()
        terminal.append(Data("héllo\n".utf8))
        XCTAssertEqual(terminal.text, "héllo\n")
    }

    func testCharsetDesignationDoesNotPrintItsByte() {
        let terminal = grid(feed: "\u{1B}(Bok\u{1B})0fine")
        XCTAssertEqual(terminal.text, "okfine")
    }

    // MARK: - Scrolling and history

    func testScrollingOffTheTopFeedsScrollback() {
        var terminal = grid(rows: 3)
        terminal.append("un\ndeux\ntrois\nquatre")
        XCTAssertEqual(terminal.text, "un\ndeux\ntrois\nquatre")
    }

    func testScrollbackIsBounded() {
        var terminal = TerminalGrid(columns: 20, rows: 2, scrollbackLines: 5)
        for index in 1...50 {
            terminal.append("ligne \(index)\n")
        }
        let lines = terminal.text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5 + 2)
        XCTAssertTrue(lines.first!.hasPrefix("ligne 4"), String(lines.first!))
    }

    func testLongOutputStaysLinear() {
        var terminal = TerminalGrid(scrollbackLines: 200)
        let start = Date()
        for index in 0..<20_000 {
            terminal.append("line \(index) of a chatty guest\n")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }

    // MARK: - Deferred wrap, the classic

    func testWritingTheLastColumnDoesNotWrapYet() {
        var terminal = grid(columns: 10, rows: 4)
        terminal.append(String(repeating: "x", count: 10))
        XCTAssertEqual(terminal.cursor.row, 0, "le retour à la ligne doit être différé")
        terminal.append("\r\n")
        XCTAssertEqual(terminal.cursor.row, 1, "CR LF après une ligne pleine ne saute qu'une ligne")
        XCTAssertEqual(terminal.text, String(repeating: "x", count: 10) + "\n")
    }

    func testTheDeferredWrapHappensWhenTextFollows() {
        var terminal = grid(columns: 10, rows: 4)
        terminal.append(String(repeating: "x", count: 10) + "y")
        XCTAssertEqual(terminal.cursor.row, 1)
        XCTAssertEqual(terminal.text, String(repeating: "x", count: 10) + "\ny")
    }

    // MARK: - Cursor addressing and erasing

    func testCursorAddressingWritesWhereTold() {
        var terminal = grid(rows: 5)
        terminal.append("\u{1B}[3;5HX")
        XCTAssertNil(terminal.cell(atRow: 0, column: 0).flatMap { $0.scalar == " " ? nil : $0 })
        XCTAssertEqual(terminal.cell(atRow: 2, column: 4)?.scalar, "X")
    }

    func testRelativeCursorMovesClampAtTheEdges() {
        var terminal = grid(columns: 10, rows: 4)
        terminal.append("\u{1B}[99A\u{1B}[99D")
        XCTAssertEqual(terminal.cursor.row, 0)
        XCTAssertEqual(terminal.cursor.column, 0)
        terminal.append("\u{1B}[99B\u{1B}[99C")
        XCTAssertEqual(terminal.cursor.row, 3)
        XCTAssertEqual(terminal.cursor.column, 9)
    }

    func testEraseToEndOfLine() {
        let terminal = grid(feed: "supprimez ceci\r\u{1B}[K…")
        XCTAssertEqual(terminal.text, "…")
    }

    func testEraseDisplayBelowLeavesTheTop() {
        var terminal = grid(rows: 4)
        terminal.append("haut\nmilieu\nbas")
        terminal.append("\u{1B}[2;1H\u{1B}[J")
        // The trailing newline is the empty line the cursor sits on — where
        // the next prompt goes. The same rule keeps "$ vim fichier\n" above.
        XCTAssertEqual(terminal.text, "haut\n")
    }

    func testClearScreenThenHomeIsEmpty() {
        var terminal = grid(rows: 4)
        terminal.append("avant\navant aussi")
        terminal.append("\u{1B}[2J\u{1B}[H")
        XCTAssertEqual(terminal.screenText.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testInsertAndDeleteCharactersShiftTheLine() {
        var terminal = grid(feed: "abcdef\r")
        terminal.append("\u{1B}[2@")            // insert two blanks at 'a'
        XCTAssertEqual(terminal.text, "  abcdef")
        terminal.append("\u{1B}[2P")            // delete them again
        XCTAssertEqual(terminal.text, "abcdef")
    }

    func testInsertAndDeleteLines() {
        var terminal = grid(rows: 4)
        terminal.append("un\ndeux\ntrois")
        terminal.append("\u{1B}[2;1H\u{1B}[L")  // a blank line where "deux" was
        XCTAssertEqual(terminal.text, "un\n\ndeux\ntrois")
        terminal.append("\u{1B}[M")             // and gone again
        XCTAssertEqual(terminal.text, "un\ndeux\ntrois")
    }

    // MARK: - The scroll region, which is what makes top possible

    func testScrollRegionScrollsOnlyItsWindow() {
        var terminal = grid(rows: 5)
        terminal.append("entête\nA\nB\nC\npied")
        // Region rows 2–4; from its bottom, two line feeds push A then B out.
        terminal.append("\u{1B}[2;4r\u{1B}[4;1H\n\n")
        XCTAssertEqual(terminal.text, "entête\nC\n\n\npied")
    }

    func testReverseIndexAtTheRegionTopScrollsDown() {
        var terminal = grid(rows: 4)
        terminal.append("un\ndeux\n\u{1B}[1;1H\u{1B}M")
        XCTAssertEqual(terminal.text, "\nun\ndeux")
    }

    // MARK: - The alternate screen, which is what makes editors civilised

    func testTheAlternateScreenComesAndGoesWithoutTrace() {
        var terminal = grid(rows: 4)
        terminal.append("$ vim fichier\n")
        terminal.append("\u{1B}[?1049h")        // vim enters
        terminal.append("\u{1B}[2J\u{1B}[H~ plein écran")
        XCTAssertTrue(terminal.isAlternateScreen)
        XCTAssertTrue(terminal.text.contains("plein écran"))
        terminal.append("\u{1B}[?1049l")        // vim leaves
        XCTAssertFalse(terminal.isAlternateScreen)
        XCTAssertEqual(terminal.text, "$ vim fichier\n")
    }

    func testTheAlternateScreenNeverFeedsScrollback() {
        var terminal = grid(rows: 3)
        terminal.append("shell\n\u{1B}[?1049h")
        for index in 0..<20 {
            terminal.append("frame \(index)\n")
        }
        terminal.append("\u{1B}[?1049l")
        XCTAssertEqual(terminal.text, "shell\n")
    }

    // MARK: - Attributes: recorded, never printed

    func testAttributesLandOnTheCellsTheyPainted() {
        var terminal = grid()
        terminal.append("\u{1B}[1;7mBAR\u{1B}[0m ok")
        let cell = terminal.cell(atRow: 0, column: 0)
        XCTAssertEqual(cell?.attributes.bold, true)
        XCTAssertEqual(cell?.attributes.inverse, true)
        let plain = terminal.cell(atRow: 0, column: 4)
        XCTAssertEqual(plain?.attributes.isDefault, true)
    }

    func testExtendedColourParametersAreConsumedNotPrinted() {
        let terminal = grid(feed: "\u{1B}[38;5;196mrouge\u{1B}[48;2;10;20;30mfond\u{1B}[0m.")
        XCTAssertEqual(terminal.text, "rougefond.")
    }

    func testCursorVisibilityFollowsTheGuest() {
        var terminal = grid(feed: "\u{1B}[?25l")
        XCTAssertFalse(terminal.isCursorVisible)
        terminal.append("\u{1B}[?25h")
        XCTAssertTrue(terminal.isCursorVisible)
    }

    // MARK: - Whole-program smoke: a top-style repaint must not smear

    func testAFullScreenRepaintLoopDoesNotGrowTheText() {
        var terminal = grid(rows: 6)
        for iteration in 0..<50 {
            terminal.append("\u{1B}[H\u{1B}[2J")
            terminal.append("Tasks: \(iteration)\u{1B}[2;1HPID   CPU\u{1B}[3;1H  1   9\(iteration % 10)")
        }
        XCTAssertEqual(terminal.text, "Tasks: 49\nPID   CPU\n  1   99")
    }
}
