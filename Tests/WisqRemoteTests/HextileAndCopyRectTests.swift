import WisqCore
import WisqNet
import XCTest

@testable import WisqRemote

/// Two encodings the decoder implements and nothing held it to.
///
/// `RFBDecoderTests` next door has four tests for twelve encodings. Hextile and
/// CopyRect had none — and both turned out to be **correct**: every probe
/// written to catch them agreed with the encoding. So this file adds no fix. It
/// converts a belief into a measurement, which is the only thing that makes the
/// next change to either one safe: a green suite that never ran this code could
/// not have gone red for it.
///
/// Every test here was checked by breaking the decoder and watching it fail.
final class HextileAndCopyRectTests: XCTestCase {
    // MARK: - Wire helpers

    private func header(x: UInt16 = 0, y: UInt16 = 0, width: UInt16, height: UInt16, encoding: UInt8)
        -> Data
    {
        var data = Data()
        for value in [x, y, width, height] {
            data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
        }
        data.append(contentsOf: [0, 0, 0, encoding])
        return data
    }

    private func decode(_ data: Data, into framebuffer: Framebuffer) async throws
        -> RFBDecoder.Outcome
    {
        let decoder = RFBDecoder(
            stream: MemoryByteStream(inbound: data),
            framebuffer: framebuffer,
            streams: try RFBStreams())
        return try await decoder.decodeRectangle()
    }

    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        let snapshot = framebuffer.snapshot()
        let offset = (y * snapshot.width + x) * 4
        return Array(snapshot.pixels[offset..<(offset + 4)])
    }

    // MARK: - Hextile

    /// The two flags that carry a colour, and the subrect that uses its own.
    func testATileFillsWithItsBackgroundThenPaintsItsSubrects() async throws {
        var data = header(width: 2, height: 2, encoding: 5)
        data.append(contentsOf: [0x02 | 0x08 | 0x10])  // fond | sous-rects | colorés
        data.append(contentsOf: [7, 7, 7, 0])
        data.append(contentsOf: [1])
        data.append(contentsOf: [9, 9, 9, 0])
        data.append(contentsOf: [0x11, 0x00])  // (1,1), 1×1
        let framebuffer = Framebuffer(width: 2, height: 2)
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(pixel(framebuffer, 0, 0), [7, 7, 7, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [7, 7, 7, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 1), [9, 9, 9, 255], "le sous-rectangle va en (1,1)")
    }

    /// The nibbles are position then size, and the size is stored one short.
    /// Reading them the other way round paints a plausible but wrong picture,
    /// which is exactly the kind of thing no test would have caught.
    func testTheSubrectNibblesArePositionThenSizeMinusOne() async throws {
        var data = header(width: 4, height: 1, encoding: 5)
        data.append(contentsOf: [0x02 | 0x04 | 0x08])  // fond | premier plan | sous-rects
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [8, 8, 8, 0])
        data.append(contentsOf: [1])
        data.append(contentsOf: [0x10, 0x10])  // en (1,0), 2×1
        let framebuffer = Framebuffer(width: 4, height: 1)
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 255], "avant le sous-rectangle")
        XCTAssertEqual(pixel(framebuffer, 1, 0), [8, 8, 8, 255])
        XCTAssertEqual(pixel(framebuffer, 2, 0), [8, 8, 8, 255], "largeur = nibble + 1")
        XCTAssertEqual(pixel(framebuffer, 3, 0), [0, 0, 0, 255], "et pas au-delà")
    }

    /// The colours persist until a tile respecifies them — a tile that says
    /// nothing is not a black tile.
    func testColoursCarryOverToATileThatSpecifiesNone() async throws {
        var data = header(width: 32, height: 1, encoding: 5)
        data.append(contentsOf: [0x02])
        data.append(contentsOf: [5, 5, 5, 0])
        data.append(contentsOf: [0x00])  // deuxième tuile : rien
        let framebuffer = Framebuffer(width: 32, height: 1)
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(pixel(framebuffer, 0, 0), [5, 5, 5, 255])
        XCTAssertEqual(pixel(framebuffer, 16, 0), [5, 5, 5, 255], "la deuxième tuile hérite du fond")
    }

    /// A raw tile takes its pixels from the wire and asks no questions.
    func testARawTileIsCopiedStraightFromTheWire() async throws {
        var data = header(width: 2, height: 1, encoding: 5)
        data.append(contentsOf: [0x01])
        data.append(contentsOf: [1, 2, 3, 0, 4, 5, 6, 0])
        let framebuffer = Framebuffer(width: 2, height: 1)
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(pixel(framebuffer, 0, 0), [1, 2, 3, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [4, 5, 6, 255])
    }

    /// A subrect that claims more than its tile is clipped rather than written
    /// past the end of the buffer it is being painted into.
    func testASubrectLargerThanItsTileIsClipped() async throws {
        var data = header(width: 2, height: 2, encoding: 5)
        data.append(contentsOf: [0x02 | 0x04 | 0x08])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [9, 9, 9, 0])
        data.append(contentsOf: [1])
        data.append(contentsOf: [0xF0, 0xFF])  // (15,0), 16×16 dans une tuile 2×2
        let framebuffer = Framebuffer(width: 2, height: 2)
        _ = try await decode(data, into: framebuffer)

        // Rien à affirmer sur les pixels : ce que ce test garde est que le
        // décodeur survit et laisse le tampon intact plutôt que d'écrire
        // au-delà. Un débordement ici tuerait le processus.
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 255])
    }

    // MARK: - CopyRect

    func testCopyRectMovesPixelsAlreadyOnScreen() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        framebuffer.write(
            rect: Rect(x: 0, y: 0, width: 2, height: 1), bgra: [1, 1, 1, 255, 2, 2, 2, 255])

        var data = header(x: 2, width: 2, height: 1, encoding: 1)
        data.append(contentsOf: [0, 0, 0, 0])  // source (0,0)
        guard case .painted(let rect) = try await decode(data, into: framebuffer) else {
            return XCTFail("CopyRect aurait dû dessiner")
        }
        XCTAssertEqual(rect, Rect(x: 2, y: 0, width: 2, height: 1))
        XCTAssertEqual(pixel(framebuffer, 2, 0), [1, 1, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 3, 0), [2, 2, 2, 255])
        XCTAssertEqual(pixel(framebuffer, 0, 0), [1, 1, 1, 255], "la source reste en place")
    }

    /// The case a scrolling terminal produces constantly: source and
    /// destination overlap, and every pixel must come from the state *before*
    /// the copy. Reading as it writes smears the first pixel across the run.
    func testAnOverlappingCopyReadsTheStateBeforeIt() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        framebuffer.write(
            rect: Rect(x: 0, y: 0, width: 4, height: 1),
            bgra: [1, 1, 1, 255, 2, 2, 2, 255, 3, 3, 3, 255, 4, 4, 4, 255])

        var data = header(x: 1, width: 3, height: 1, encoding: 1)
        data.append(contentsOf: [0, 0, 0, 0])  // source x = 0, un pixel à gauche
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(
            (0..<4).map { pixel(framebuffer, $0, 0)[0] }, [1, 1, 2, 3],
            "une copie qui lit au fur et à mesure étalerait le premier pixel")
    }

    /// The case that actually needs the scratch buffer, and the reason this
    /// test exists at all.
    ///
    /// The horizontal one above does **not** need it: a copy that moves one
    /// whole row at a time reads that row before writing it, so a single-row
    /// overlap comes out right either way — removing the scratch buffer left
    /// the whole suite green. A vertical overlap is different: row 0 lands on
    /// row 1, which is row 2's source. Top-down without a scratch buffer, the
    /// first row is smeared down the screen, and a scrolling terminal is
    /// exactly what CopyRect is for.
    func testAScrollReadsEveryRowFromTheStateBeforeTheCopy() async throws {
        let framebuffer = Framebuffer(width: 1, height: 4)
        for row in 0..<4 {
            let value = UInt8(row + 1)
            framebuffer.write(
                rect: Rect(x: 0, y: row, width: 1, height: 1),
                bgra: [value, value, value, 255])
        }

        var data = header(x: 0, y: 1, width: 1, height: 3, encoding: 1)
        data.append(contentsOf: [0, 0, 0, 0])  // source (0,0) : tout descend d'une ligne
        _ = try await decode(data, into: framebuffer)

        XCTAssertEqual(
            (0..<4).map { pixel(framebuffer, 0, $0)[0] }, [1, 1, 2, 3],
            "sans tampon de travail, la première ligne s'étale vers le bas")
    }

    /// The decoder reports the rectangle it painted, which is what drives the
    /// view's redraw. Reporting the source instead would refresh the wrong part
    /// of the screen.
    func testCopyRectReportsTheDestinationNotTheSource() async throws {
        let framebuffer = Framebuffer(width: 8, height: 4)
        var data = header(x: 4, y: 2, width: 2, height: 1, encoding: 1)
        data.append(contentsOf: [0, 0, 0, 0])
        guard case .painted(let rect) = try await decode(data, into: framebuffer) else {
            return XCTFail("CopyRect aurait dû dessiner")
        }
        XCTAssertEqual(rect, Rect(x: 4, y: 2, width: 2, height: 1))
    }
}
