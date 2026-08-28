import Foundation
import XCTest

@testable import WisqCore
@testable import WisqRemote

/// The bound guards that stand between a hostile stream and an out-of-bounds
/// write — and, until this file, nothing stood behind them.
///
/// The decompression audit read six paths as sane because each writes into a
/// buffer sized before the loop and checks its index before every element. That
/// reading was right. What it did not establish is whether anything **holds**
/// those checks: measured by removing each of the six in turn and running the
/// whole suite, **all six survived**. The fixtures every suite uses are valid
/// streams, and a valid stream never reaches a bound.
///
/// The four diagnostics, applied: not a wrong line, not a real equivalence, not
/// an unreachable branch — the lengths come off the wire and a server chooses
/// them. Missing witness, six times.
///
/// What they prevent is worth naming precisely. These buffers are pre-sized, so
/// the failure is not an exhausted heap: it is a write past the end, which in
/// Swift is a trap. On a phone a trap and an out-of-memory are the same event —
/// the app is gone — and this is the difference between that and a refused
/// message.
final class DecoderBoundGuardTests: XCTestCase {
    // MARK: - ZRLE

    /// A plain-RLE tile whose run covers a hundred pixels of a four-pixel tile.
    ///
    /// `readRunLength` reads as many bytes as the stream spends, so the length
    /// is the server's to choose and nothing else bounds it.
    func testAZRLERunPastTheTileIsRefused() {
        var stream: [UInt8] = [0x80]  // séries, palette vide
        stream.append(contentsOf: [1, 2, 3])  // une couleur
        stream.append(99)  // longueur 1 + 99 = 100, pour une tuile de 4
        XCTAssertThrowsError(
            try ZRLEDecoder.decode(
                rect: Rect(x: 0, y: 0, width: 2, height: 2),
                data: Data(stream),
                into: Framebuffer(width: 2, height: 2))
        ) { error in
            guard case WisqError.malformedMessage(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("hors tuile"), message)
        }
    }

    /// The same, through the palette form, which is a different guard on a
    /// different line — and would have been missed by a sweep that sabotaged
    /// the two together.
    func testAZRLEPaletteRunPastTheTileIsRefused() {
        var stream: [UInt8] = [0x82]  // séries, palette de deux entrées
        stream.append(contentsOf: [1, 2, 3])
        stream.append(contentsOf: [4, 5, 6])
        stream.append(0x80)  // entrée 0, suivie d'une longueur
        stream.append(99)  // 100 pixels pour une tuile de 4
        XCTAssertThrowsError(
            try ZRLEDecoder.decode(
                rect: Rect(x: 0, y: 0, width: 2, height: 2),
                data: Data(stream),
                into: Framebuffer(width: 2, height: 2))
        ) { error in
            guard case WisqError.malformedMessage(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("palette"), message)
        }
    }

    /// The other edge, and half the work: a run that fits must still paint. A
    /// guard that refused every run would pass both tests above and break every
    /// real server.
    func testAZRLERunThatFitsIsPainted() throws {
        var stream: [UInt8] = [0x80]
        stream.append(contentsOf: [0x11, 0x22, 0x33])
        stream.append(3)  // 1 + 3 = 4 pixels, exactement la tuile
        let framebuffer = Framebuffer(width: 2, height: 2)
        try ZRLEDecoder.decode(
            rect: Rect(x: 0, y: 0, width: 2, height: 2),
            data: Data(stream), into: framebuffer)
        let pixels = framebuffer.snapshot().pixels
        XCTAssertEqual(Array(pixels.prefix(4)), [0x11, 0x22, 0x33, 255])
        XCTAssertEqual(Array(pixels.suffix(4)), [0x11, 0x22, 0x33, 255])
    }

    // MARK: - GLZ

    /// A GLZ literal run of six pixels into a two-pixel image.
    ///
    /// The control byte carries the count directly — `control + 1`, up to
    /// thirty-two — so nothing but this guard relates it to the image being
    /// decoded. The stream carries all eighteen bytes the run announces, which
    /// is the part that makes it a witness rather than a coincidence: without
    /// the guard the loop does not run out of input and stop, it writes past
    /// the end of an eight-byte buffer.
    func testAGLZLiteralRunPastTheImageIsRefused() {
        var stream: [UInt8] = [5]  // 5 + 1 = 6 pixels littéraux
        stream.append(contentsOf: [UInt8](repeating: 0x7F, count: 6 * 3))
        XCTAssertThrowsError(
            try SpiceGLZ.decodeRGB32(
                stream, from: 0, pixels: 2, imageID: 1, window: SpiceGLZ.Window())
        ) { error in
            XCTAssertEqual(error as? SpiceGLZ.Failure, .truncated)
        }
    }

    /// A GLZ match of three pixels starting one pixel into a two-pixel image.
    ///
    /// One literal first, deliberately: the match's own reference check
    /// (`pixelOffset <= op`) refuses a match at the very start, so a witness
    /// written without that literal would be caught by the wrong guard and
    /// would still pass with this one removed.
    func testAGLZMatchPastTheImageIsRefused() {
        let stream = Self.glzLiteralThenMatch()
        XCTAssertThrowsError(
            try SpiceGLZ.decodeRGB32(
                stream, from: 0, pixels: 2, imageID: 1, window: SpiceGLZ.Window())
        ) { error in
            XCTAssertEqual(error as? SpiceGLZ.Failure, .truncated)
        }
    }

    /// The other edge for both: the same literal-then-match stream, into the
    /// four pixels it actually describes, must decode.
    func testAGLZRunAndMatchThatFitAreDecoded() throws {
        let decoded = try SpiceGLZ.decodeRGB32(
            Self.glzLiteralThenMatch(), from: 0, pixels: 4,
            imageID: 1, window: SpiceGLZ.Window())
        XCTAssertEqual(
            decoded.pixels,
            Array(repeating: [0x11, 0x22, 0x33, 0] as [UInt8], count: 4).flatMap { $0 })
    }

    /// One literal pixel, then a match of three copying it forward.
    ///
    /// `0x60`: length 3 in the top three bits, a short pixel offset, and a low
    /// nibble of zero. The byte after it extends that offset by nothing, and
    /// the one after that is the image-distance code — zero, so the match stays
    /// inside this image and the offset is biased by one, landing on the pixel
    /// just written.
    private static func glzLiteralThenMatch() -> [UInt8] {
        [0x00, 0x11, 0x22, 0x33] + [0x60, 0x00, 0x00]
    }

    // MARK: - LZ, the alpha pass

    /// The two-pass forms run a second loop over the same buffer, with its own
    /// control bytes, and that loop has its own pair of guards. `xxxa` is the
    /// alpha pass alone, so a stream of two control bytes reaches them without
    /// a colour pass in the way.
    func testAnLZAlphaLiteralRunPastTheImageIsRefused() {
        // Six littéraux — un octet chacun — pour une image de deux pixels.
        let payload = Self.lzXXXA(width: 2) + [5] + [UInt8](repeating: 0xAB, count: 6)
        XCTAssertThrowsError(try SpiceLZ.decompressWithAlpha(payload)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .truncated)
        }
    }

    /// The same pass's match loop. `0x60` is length 2 before the alpha pass's
    /// bias of three, so five pixels; the byte after it makes the distance one,
    /// which the single literal before it satisfies.
    func testAnLZAlphaMatchPastTheImageIsRefused() {
        let payload = Self.lzXXXA(width: 2) + [0x00, 0xAB] + [0x60, 0x00]
        XCTAssertThrowsError(try SpiceLZ.decompressWithAlpha(payload)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .truncated)
        }
    }

    /// The other edge: one literal and a match of three, filling four pixels
    /// exactly, must decode — and must decode to the literal repeated, or the
    /// match copied the wrong thing rather than too much of it.
    func testAnLZAlphaRunAndMatchThatFitAreDecoded() throws {
        // `0x20` : un champ de longueur à 1, soit trois pixels une fois
        // décrémenté puis biaisé par la passe alpha.
        let payload = Self.lzXXXA(width: 4) + [0x00, 0xAB] + [0x20, 0x00]
        let (_, pixels) = try SpiceLZ.decompressWithAlpha(payload)
        XCTAssertEqual(pixels.count, 16)
        XCTAssertEqual(stride(from: 3, to: 16, by: 4).map { pixels[$0] }, [0xAB, 0xAB, 0xAB, 0xAB])
    }

    /// A 28-byte `xxxa` header: one row, no stride, top-down.
    private static func lzXXXA(width: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        func be(_ word: UInt32) {
            bytes.append(contentsOf: [
                UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
                UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
            ])
        }
        be(SpiceLZ.magic)
        be(SpiceLZ.versionMajor << 16 | SpiceLZ.versionMinor)
        be(SpiceLZ.ImageType.xxxa.rawValue)
        be(UInt32(width))
        be(1)
        be(0)
        be(1)
        return bytes
    }
}
