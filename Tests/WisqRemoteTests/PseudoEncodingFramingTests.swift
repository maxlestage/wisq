import WisqCore
import WisqNet
import XCTest

@testable import WisqRemote

/// The three encodings that carry no pixels, and the bytes they must consume
/// exactly.
///
/// `extendedDesktopSize`, `desktopName` and `lastRect` appear in the test suite
/// only as entries in the `SetEncodings` list — what wisq *advertises*. Nothing
/// held their decoding, and they are precisely the ones where getting it wrong
/// is unrecoverable: `RFBDecoder`'s own doc says a rectangle read wrong leaves
/// the stream "stranded with no way to resynchronise", and two of these three
/// consume a variable number of bytes.
///
/// So the probe here is not "does it return the right thing". It is: **decode a
/// second rectangle immediately after**, which only arrives intact if the first
/// consumed exactly what it should. A test that stopped at the return value
/// would go green for a decoder that swallowed the rest of the session.
final class PseudoEncodingFramingTests: XCTestCase {
    // MARK: - Wire helpers

    private func header(
        x: UInt16 = 0, y: UInt16 = 0, width: UInt16 = 0, height: UInt16 = 0, encoding: Int32
    ) -> Data {
        var data = Data()
        for value in [x, y, width, height] {
            data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
        }
        let raw = UInt32(bitPattern: encoding)
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: raw >> 24), UInt8(truncatingIfNeeded: raw >> 16),
            UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw),
        ])
        return data
    }

    /// A 1×1 raw rectangle in a colour nothing else uses. Placed after the
    /// rectangle under test: if it decodes and paints, the framing was right.
    private func witness() -> Data {
        var data = header(x: 3, y: 0, width: 1, height: 1, encoding: RFB.Encoding.raw.rawValue)
        data.append(contentsOf: [11, 22, 33, 0])
        return data
    }

    private func decoder(_ data: Data, _ framebuffer: Framebuffer) throws -> RFBDecoder {
        RFBDecoder(
            stream: MemoryByteStream(inbound: data), framebuffer: framebuffer,
            streams: try RFBStreams())
    }

    /// Decodes the rectangle under test, then the witness behind it, and
    /// returns both outcomes.
    private func decodeThenWitness(_ data: Data) async throws
        -> (RFBDecoder.Outcome, RFBDecoder.Outcome, Framebuffer)
    {
        let framebuffer = Framebuffer(width: 4, height: 1)
        let decoder = try decoder(data + witness(), framebuffer)
        let first = try await decoder.decodeRectangle()
        let second = try await decoder.decodeRectangle()
        return (first, second, framebuffer)
    }

    private func witnessLanded(_ outcome: RFBDecoder.Outcome, _ framebuffer: Framebuffer) -> Bool {
        guard case .painted(let rect) = outcome, rect == Rect(x: 3, y: 0, width: 1, height: 1) else {
            return false
        }
        let pixels = framebuffer.snapshot().pixels
        return Array(pixels[12..<16]) == [11, 22, 33, 255]
    }

    // MARK: - The control

    /// Before believing any "the stream survived" below: show the probe can say
    /// the opposite. One byte eaten in front of the witness and it must fail.
    func testTheWitnessCanFail() async throws {
        let framebuffer = Framebuffer(width: 4, height: 1)
        let decoder = try decoder(Data([0]) + witness(), framebuffer)
        let outcome = try? await decoder.decodeRectangle()
        XCTAssertFalse(
            outcome.map { witnessLanded($0, framebuffer) } ?? false,
            "le témoin passe même sur un flux décalé : il ne prouve rien")
    }

    // MARK: - ExtendedDesktopSize

    /// Four bytes of preamble and sixteen per screen. Miss the count and every
    /// byte after this rectangle means something else.
    func testExtendedDesktopSizeConsumesFourBytesPlusSixteenPerScreen() async throws {
        for screens in [0, 1, 3] {
            var data = header(width: 1280, height: 720, encoding: RFB.Encoding.extendedDesktopSize.rawValue)
            data.append(UInt8(screens))
            data.append(contentsOf: [0, 0, 0])
            data.append(contentsOf: [UInt8](repeating: 0xAB, count: screens * 16))

            let (first, second, framebuffer) = try await decodeThenWitness(data)
            guard case .resized(let width, let height) = first else {
                return XCTFail("\(screens) écran(s) : attendu .resized, obtenu \(first)")
            }
            XCTAssertEqual([width, height], [1280, 720])
            XCTAssertTrue(witnessLanded(second, framebuffer), "\(screens) écran(s) : flux désynchronisé")
        }
    }

    /// `x` carries the reason and `y` the result code. A non-zero result is the
    /// server refusing our resize while keeping its own geometry — applying the
    /// rectangle's dimensions there would move the whole view to a size the
    /// server never adopted.
    func testARefusedResizeIsNotApplied() async throws {
        var data = header(
            x: 1, y: 3, width: 1280, height: 720,
            encoding: RFB.Encoding.extendedDesktopSize.rawValue)
        data.append(contentsOf: [0, 0, 0, 0])

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .serverSupportsResize = first else {
            return XCTFail("un refus a été pris pour un redimensionnement : \(first)")
        }
        XCTAssertTrue(witnessLanded(second, framebuffer))
    }

    /// And the other edge: reason 1 with result 0 is our own request, granted.
    func testAnAcceptedResizeIsApplied() async throws {
        var data = header(
            x: 1, y: 0, width: 800, height: 600,
            encoding: RFB.Encoding.extendedDesktopSize.rawValue)
        data.append(contentsOf: [0, 0, 0, 0])

        let (first, _, _) = try await decodeThenWitness(data)
        guard case .resized(let width, let height) = first else {
            return XCTFail("attendu .resized, obtenu \(first)")
        }
        XCTAssertEqual([width, height], [800, 600])
    }

    // MARK: - DesktopName

    func testDesktopNameReadsExactlyItsLength() async throws {
        let name = "bureau de Maxime"
        var data = header(encoding: RFB.Encoding.desktopName.rawValue)
        data.append(contentsOf: [0, 0, 0, UInt8(name.utf8.count)])
        data.append(contentsOf: Array(name.utf8))

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .renamed(let read) = first else {
            return XCTFail("attendu .renamed, obtenu \(first)")
        }
        XCTAssertEqual(read, name)
        XCTAssertTrue(witnessLanded(second, framebuffer), "flux désynchronisé après le nom")
    }

    /// Latin-1, as the spec says, and not UTF-8: the same byte means a
    /// different character in each, so reading it the other way renames the
    /// desktop to something nobody chose.
    func testTheNameIsReadAsLatin1() async throws {
        var data = header(encoding: RFB.Encoding.desktopName.rawValue)
        data.append(contentsOf: [0, 0, 0, 3])
        data.append(contentsOf: [0xE9, 0x74, 0xE9])  // "été" en latin-1

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .renamed(let read) = first else {
            return XCTFail("attendu .renamed, obtenu \(first)")
        }
        XCTAssertEqual(read, "été")
        XCTAssertTrue(witnessLanded(second, framebuffer))
    }

    /// A name of nothing is a name of nothing, not a reason to read further.
    func testAnEmptyNameConsumesNothingBeyondItsLength() async throws {
        var data = header(encoding: RFB.Encoding.desktopName.rawValue)
        data.append(contentsOf: [0, 0, 0, 0])

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .renamed(let read) = first else {
            return XCTFail("attendu .renamed, obtenu \(first)")
        }
        XCTAssertEqual(read, "")
        XCTAssertTrue(witnessLanded(second, framebuffer))
    }

    // MARK: - LastRect

    /// It ends the update, and it consumes nothing but its own header — the
    /// bytes behind it belong to the next message, not to it.
    func testLastRectEndsTheUpdateWithoutEatingWhatFollows() async throws {
        let data = header(encoding: RFB.Encoding.lastRect.rawValue)

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .endOfRectangles = first else {
            return XCTFail("attendu .endOfRectangles, obtenu \(first)")
        }
        XCTAssertTrue(witnessLanded(second, framebuffer), "lastRect a mangé le message suivant")
    }

    /// `lastRect` carries dimensions in its header that mean nothing. Painting
    /// them, or reporting a size, would be acting on a number the server never
    /// meant as one.
    func testLastRectIgnoresTheDimensionsInItsHeader() async throws {
        let data = header(x: 9, y: 9, width: 640, height: 480, encoding: RFB.Encoding.lastRect.rawValue)

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .endOfRectangles = first else {
            return XCTFail("attendu .endOfRectangles, obtenu \(first)")
        }
        XCTAssertTrue(witnessLanded(second, framebuffer))
    }

    // MARK: - DesktopSize, the plain one

    /// The non-extended form carries its geometry in the header and no payload
    /// at all — the difference from its extended cousin, and the reason mixing
    /// the two up would desynchronise everything after it.
    func testPlainDesktopSizeHasNoPayload() async throws {
        let data = header(width: 1024, height: 768, encoding: RFB.Encoding.desktopSize.rawValue)

        let (first, second, framebuffer) = try await decodeThenWitness(data)
        guard case .resized(let width, let height) = first else {
            return XCTFail("attendu .resized, obtenu \(first)")
        }
        XCTAssertEqual([width, height], [1024, 768])
        XCTAssertTrue(witnessLanded(second, framebuffer))
    }
}
