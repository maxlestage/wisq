import XCTest
@testable import WisqVM

final class ConsoleBufferTests: XCTestCase {
    func testStripsColourAndCursorSequences() {
        var console = ConsoleBuffer()
        console.append("\u{1B}[1;32mvert\u{1B}[0m et \u{1B}[2Kclair")
        XCTAssertEqual(console.text, "vert et clair")
    }

    /// The reason to be incremental rather than to re-derive: a chunk boundary
    /// can land in the middle of an escape sequence. A filter applied per chunk
    /// prints the tail of the sequence as text; a parser that keeps its state
    /// does not.
    func testEscapeSequenceSplitAcrossChunks() {
        var console = ConsoleBuffer()
        console.append("avant\u{1B}[1")
        console.append(";32maprès")
        XCTAssertEqual(console.text, "avantaprès")
    }

    func testOSCSequenceSplitAcrossChunks() {
        var console = ConsoleBuffer()
        console.append("a\u{1B}]0;titre")
        console.append(" long\u{07}b")
        XCTAssertEqual(console.text, "ab")
    }

    func testCarriageReturnRedrawsTheLine() {
        var console = ConsoleBuffer()
        console.append("chargement 10%\rchargement 99%")
        XCTAssertEqual(console.text, "chargement 99%")
    }

    func testCarriageReturnKeepsWhatTheRedrawDoesNotCover() {
        var console = ConsoleBuffer()
        console.append("abcdef\rXY")
        XCTAssertEqual(console.text, "XYcdef")
    }

    func testBackspaceErasesTheCharacterBeforeIt() {
        var console = ConsoleBuffer()
        console.append("motx\u{8}s")
        XCTAssertEqual(console.text, "mots")
    }

    func testBackspaceStopsAtColumnZero() {
        var console = ConsoleBuffer()
        console.append("\u{8}\u{8}a")
        XCTAssertEqual(console.text, "a")
    }

    func testNewlinesSeparateLines() {
        var console = ConsoleBuffer()
        console.append("un\ndeux\ntrois")
        XCTAssertEqual(console.text, "un\ndeux\ntrois")
        XCTAssertEqual(console.lineCount, 3)
    }

    func testScrollbackIsBounded() {
        var console = ConsoleBuffer(maxLines: 10)
        for index in 0..<100 { console.append("ligne \(index)\n") }
        XCTAssertEqual(console.lineCount, 11)          // 10 kept plus the open one
        XCTAssertTrue(console.text.hasPrefix("ligne 90"), console.text.prefix(40).description)
        XCTAssertFalse(console.text.contains("ligne 89"))
    }

    func testChunkingDoesNotChangeTheResult() {
        let source = "\u{1B}[32mvert\u{1B}[0m\nprogrès 1%\rprogrès 2%\nfin\u{8}n\n"
        var whole = ConsoleBuffer()
        whole.append(source)

        for size in [1, 2, 3, 5, 7, 11] {
            var chunked = ConsoleBuffer()
            var rest = Substring(source)
            while !rest.isEmpty {
                chunked.append(String(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            XCTAssertEqual(chunked.text, whole.text, "découpage par \(size)")
        }
    }

    func testDecodesGuestBytes() {
        var console = ConsoleBuffer()
        console.append(Data("bonjour\n".utf8))
        console.append(Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]))   // ESC [ 31 m
        console.append(Data("rouge".utf8))
        XCTAssertEqual(console.text, "bonjour\nrouge")
    }

    /// The defect this type exists to remove. Re-deriving the console per chunk
    /// is quadratic in the output: this input costs a few million operations
    /// incrementally and tens of billions the old way, so the bound is loose
    /// enough never to flake and still fails a regression by orders of
    /// magnitude.
    func testLongOutputStaysLinear() {
        var console = ConsoleBuffer(maxLines: 2000)
        let start = Date()
        for index in 0..<200_000 {
            console.append("[    \(index).000000] un message de démarrage assez typique\n")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "console quadratique : \(elapsed) s")
        XCTAssertEqual(console.lineCount, 2001)
    }
}
