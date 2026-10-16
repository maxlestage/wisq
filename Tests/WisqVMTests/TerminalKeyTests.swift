import XCTest

@testable import WisqVM

/// Les touches de la console locale : chaque octet compte, parce qu'un
/// programme qui reçoit une séquence qu'il ne connaît pas l'ignore sans rien
/// dire.
final class TerminalKeyTests: XCTestCase {
    /// Les séquences d'un xterm, octet par octet.
    func testEachKeySendsTheXtermSequence() {
        let expected: [(TerminalKey, String)] = [
            (.escape, "\u{1B}"), (.tab, "\t"),
            (.up, "\u{1B}[A"), (.down, "\u{1B}[B"), (.right, "\u{1B}[C"), (.left, "\u{1B}[D"),
            (.home, "\u{1B}[H"), (.end, "\u{1B}[F"),
            (.pageUp, "\u{1B}[5~"), (.pageDown, "\u{1B}[6~"), (.delete, "\u{1B}[3~"),
        ]
        for (key, sequence) in expected {
            XCTAssertEqual(key.bytes(), Array(sequence.utf8), key.label)
        }
    }

    /// **En mode application, seules les flèches changent** : `ESC O`, que
    /// `vi` et `less` attendent après avoir demandé ce mode.
    func testOnlyTheArrowsChangeInApplicationMode() {
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursorKeys: true), Array("\u{1B}OA".utf8))
        XCTAssertEqual(TerminalKey.left.bytes(applicationCursorKeys: true), Array("\u{1B}OD".utf8))
        XCTAssertEqual(TerminalKey.home.bytes(applicationCursorKeys: true), TerminalKey.home.bytes())
        XCTAssertEqual(TerminalKey.tab.bytes(applicationCursorKeys: true), [0x09])
    }

    /// Ctrl et une lettre, quelle que soit sa casse ; rien pour ce qui n'est
    /// pas une lettre ASCII.
    func testControlClearsTheTopBitsOfALetter() {
        XCTAssertEqual(TerminalKey.control("c").bytes(), [0x03])
        XCTAssertEqual(TerminalKey.control("D").bytes(), [0x04])
        XCTAssertEqual(TerminalKey.control("z").bytes(), [0x1A])
        XCTAssertEqual(TerminalKey.control("é").bytes(), [])
        XCTAssertEqual(TerminalKey.control("1").bytes(), [])
        XCTAssertEqual(TerminalKey.control("c").label, "^C")
    }

    /// **Le texte en cours part avant la touche**, sans retour à la ligne :
    /// c'est ce qui fait compléter `/us` à la tabulation.
    func testTypedTextIsSentBeforeTheKey() {
        XCTAssertEqual(TerminalKey.tab.sending(afterTyped: "ls /us"), Data("ls /us\t".utf8))
        XCTAssertEqual(TerminalKey.up.sending(afterTyped: ""), Data("\u{1B}[A".utf8))
    }

    /// La barre porte chaque touche une fois, et toutes envoient quelque chose.
    func testTheBarHoldsEachKeyOnceAndEverythingSendsBytes() {
        XCTAssertEqual(Set(TerminalKey.bar).count, TerminalKey.bar.count)
        for key in TerminalKey.bar {
            XCTAssertFalse(key.bytes().isEmpty, key.label)
            XCTAssertFalse(key.spokenName.isEmpty)
        }
    }

    // MARK: - Le mode, tel que la grille le retient

    /// `vi` demande le mode application en entrant et le rend en sortant ; la
    /// grille suit, et un effacement complet (`ESC c`) le remet à zéro.
    func testTheGridFollowsApplicationCursorMode() {
        var grid = TerminalGrid()
        XCTAssertFalse(grid.applicationCursorKeys)
        grid.append(Data("\u{1B}[?1h".utf8))
        XCTAssertTrue(grid.applicationCursorKeys)
        grid.append(Data("\u{1B}[?1l".utf8))
        XCTAssertFalse(grid.applicationCursorKeys)
        grid.append(Data("\u{1B}[?1;1049h".utf8))
        XCTAssertTrue(grid.applicationCursorKeys, "avec d'autres modes dans la même séquence")
        grid.append(Data("\u{1B}c".utf8))
        XCTAssertFalse(grid.applicationCursorKeys)
    }
}
