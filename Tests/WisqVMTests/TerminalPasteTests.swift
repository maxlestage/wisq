import XCTest
@testable import WisqVM

/// Coller dans la console locale : ce qui part, et ce qui ne doit jamais partir.
final class TerminalPasteTests: XCTestCase {

    /// Les retours à la ligne s'écrivent comme la touche Entrée, et `\r\n` n'en
    /// fait qu'un : un fichier venu de Windows ne colle pas une ligne vide sur deux.
    func testLineEndingsBecomeOneCarriageReturnEach() {
        XCTAssertEqual(TerminalPaste.cleaned("a\nb"), "a\rb")
        XCTAssertEqual(TerminalPaste.cleaned("a\r\nb\r\n"), "a\rb\r")
        XCTAssertEqual(TerminalPaste.cleaned("a\rb"), "a\rb")
        XCTAssertEqual(TerminalPaste.cleaned("a\n\nb"), "a\r\rb", "une vraie ligne vide reste")
        XCTAssertEqual(TerminalPaste.cleaned("a\r\n\r\nb"), "a\r\rb")
    }

    /// La tabulation passe — un Makefile collé en a besoin — et le texte non
    /// ASCII aussi, octet pour octet en UTF-8.
    func testTabsAndUnicodeSurvive() {
        XCTAssertEqual(TerminalPaste.cleaned("\tcc -o été main.c"), "\tcc -o été main.c")
        XCTAssertEqual(TerminalPaste.bytes(for: "é", bracketed: false), Data([0xC3, 0xA9]))
    }

    /// Le défaut qu'il fallait voir avant de l'écrire : un collage qui porte la
    /// fin d'encadrement la refermerait de l'intérieur, et la suite serait
    /// exécutée comme tapée. Aucun `ESC` ne passe, donc aucune séquence.
    func testAPasteCannotCloseItsOwnBrackets() {
        let hostile = "echo sûr\u{1B}[201~rm -rf ~\n"
        let sent = TerminalPaste.bytes(for: hostile, bracketed: true)
        XCTAssertEqual(sent, TerminalPaste.start + Data("echo sûr[201~rm -rf ~\r".utf8) + TerminalPaste.end)
        XCTAssertEqual(sent.filter { $0 == 0x1B }.count, 2, "les deux ESC de l'encadrement, et eux seuls")
    }

    /// Les autres contrôles, C0 comme C1 : `^C` ou `^D` dans un presse-papiers
    /// n'interrompt rien, et `U+009B` — un `ESC [` d'un seul caractère — non plus.
    func testControlCharactersAreDropped() {
        XCTAssertEqual(TerminalPaste.cleaned("a\u{03}b\u{04}c\u{7F}d\u{9B}31me\u{00}"), "abcd31me")
    }

    /// Encadré seulement quand le programme l'a demandé, et rien du tout pour
    /// un texte que le nettoyage vide.
    func testBracketsOnlyWhenAskedAndNeverAroundNothing() {
        XCTAssertEqual(TerminalPaste.bytes(for: "ls", bracketed: false), Data("ls".utf8))
        XCTAssertEqual(TerminalPaste.bytes(for: "ls", bracketed: true),
                       Data("\u{1B}[200~ls\u{1B}[201~".utf8))
        XCTAssertEqual(TerminalPaste.bytes(for: "", bracketed: true), Data())
        XCTAssertEqual(TerminalPaste.bytes(for: "\u{1B}\u{07}", bracketed: true), Data())
    }

    /// Ce qui était en cours de saisie part d'abord, hors de l'encadrement : c'est
    /// du texte tapé, et `git commit -m ` suivi d'un message collé doit se lire
    /// dans cet ordre.
    func testTypedTextGoesFirstOutsideTheBrackets() {
        XCTAssertEqual(
            TerminalPaste.sending("message", afterTyped: "git commit -m ", bracketed: true),
            Data("git commit -m \u{1B}[200~message\u{1B}[201~".utf8))
    }

    /// Bash le demande à chaque invite et le rend avant d'exécuter ; la grille
    /// suit, et un effacement complet le remet à zéro.
    func testTheGridFollowsBracketedPasteMode() {
        var grid = TerminalGrid()
        XCTAssertFalse(grid.bracketedPaste)
        grid.append(Data("\u{1B}[?2004h$ ".utf8))
        XCTAssertTrue(grid.bracketedPaste)
        XCTAssertFalse(grid.applicationCursorKeys, "un mode n'en allume pas un autre")
        grid.append(Data("\u{1B}[?2004l".utf8))
        XCTAssertFalse(grid.bracketedPaste)
        grid.append(Data("\u{1B}[?1;2004h".utf8))
        XCTAssertTrue(grid.bracketedPaste)
        XCTAssertTrue(grid.applicationCursorKeys)
        grid.append(Data("\u{1B}c".utf8))
        XCTAssertFalse(grid.bracketedPaste)
    }
}
