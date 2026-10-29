import XCTest
@testable import WisqVM

/// **Un caractère coupé entre deux morceaux de la console.** La sortie de
/// l'invité arrive par tranches d'exécution, et une tranche peut finir au
/// milieu des octets d'un caractère : un « é » en deux, un emoji en quatre.
/// Décodé morceau par morceau, chaque bout devenait un « � » — une console
/// française y perdait ses accents au hasard des tranches.
final class TerminalGridUTF8SplitTests: XCTestCase {
    private func feed(_ chunks: [[UInt8]]) -> String {
        var terminal = TerminalGrid(columns: 80, rows: 24)
        for chunk in chunks { terminal.append(Data(chunk)) }
        return terminal.text
    }

    /// Chaque coupure possible de « Démarré 🐧 » rend le même texte.
    func testEveryCutOfACharacterReadsTheSame() {
        let bytes = Array("Démarré 🐧 ok".utf8)
        for cut in 1..<bytes.count {
            XCTAssertEqual(feed([Array(bytes[..<cut]), Array(bytes[cut...])]), "Démarré 🐧 ok", "coupé à \(cut)")
        }
        XCTAssertEqual(feed(bytes.map { [$0] }), "Démarré 🐧 ok", "un octet à la fois")
    }

    /// **Une séquence fausse reste fausse** : un octet de continuation seul,
    /// ou un début jamais suivi, se lit « � » — il n'attend pas pour
    /// toujours en avalant ce qui vient après.
    func testAnInvalidSequenceIsStillAReplacementCharacter() {
        XCTAssertEqual(feed([[0x61, 0x80, 0x62]]), "a\u{FFFD}b")
        XCTAssertEqual(feed([[0x61, 0xC3], [0x62]]), "a\u{FFFD}b", "un début suivi d'autre chose")
        XCTAssertEqual(feed([[0x61, 0xF0, 0x9F], [0x41]]), "a\u{FFFD}A")
    }

    /// Ce qui est retenu tient dans trois octets, et rien que des débuts de
    /// séquence.
    func testOnlyAnUnfinishedSequenceIsHeldBack() {
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix(Array("abc".utf8)), 3)
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix([0x61, 0xC3]), 1)
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix([0x61, 0xC3, 0xA9]), 3)
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix([0x61, 0xF0, 0x9F, 0x90]), 1)
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix([0x61, 0xF0, 0x9F, 0x90, 0xA7]), 5)
        XCTAssertEqual(TerminalGrid.completeUTF8Prefix([0x80, 0x80, 0x80, 0x80]), 4)
    }
}
