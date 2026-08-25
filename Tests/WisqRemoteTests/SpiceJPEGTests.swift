import Foundation
import XCTest
@testable import WisqRemote
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// SPICE's two lossy image types.
///
/// `jpegAlpha` is the interesting one: **two codecs over the same pixels**, a
/// JPEG for the colour and an `xxxa` LZ stream for the opacity, one after the
/// other in a single payload. The boundary between them is a number in the
/// message, not something the bytes announce.
///
/// The shape tests run everywhere. The pixel tests need ImageIO, so they are
/// compiled only where it exists — `#if` rather than a runtime skip, because
/// the imports themselves are unavailable elsewhere. Before the `Cœur (Apple)`
/// CI job they would have run nowhere at all: the package's tests ran only on
/// Linux, where this whole section does not exist.
final class SpiceJPEGTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { SpiceWire.u32(value) }

    private func hex(_ text: String) -> [UInt8] {
        let digits = text.filter { !$0.isWhitespace }
        var out: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            out.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// The reference-encoded alpha-only stream: 8×6, opacity and nothing else.
    private var alphaFixture: SpiceLZFixtures.Case {
        SpiceLZFixtures.all.first { $0.type == .xxxa }!
    }

    private func message(
        type: UInt8, width: UInt32, height: UInt32, body: [UInt8]
    ) -> (message: [UInt8], offset: UInt32) {
        var out = [UInt8](repeating: 0, count: 4)
        let offset = UInt32(out.count)
        out += SpiceWire.u64(9) + [type, 0] + u32(width) + u32(height) + body
        return (out, offset)
    }

    // MARK: - Message shape

    /// Where the JPEG ends is read from the message. A payload split at the
    /// wrong place hands the alpha decoder the tail of a JPEG, which is not an
    /// LZ stream and does not pretend to be one.
    func testAJPEGWithAlphaIsSplitWhereTheMessageSaysAndNotElsewhere() throws {
        let jpeg: [UInt8] = [1, 2, 3, 4, 5]
        let alpha: [UInt8] = [6, 7, 8]
        let built = message(
            type: 108, width: 8, height: 6,
            body: [0x01 /* TOP_DOWN */] + u32(UInt32(jpeg.count))
                + u32(UInt32(jpeg.count + alpha.count)) + jpeg + alpha
        )

        let image = try XCTUnwrap(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        )
        XCTAssertEqual(image.descriptor.type, .jpegAlpha)
        XCTAssertEqual(image.payload, jpeg + alpha)
        XCTAssertEqual(image.jpegAlpha?.jpegBytes, jpeg.count)
        XCTAssertEqual(image.jpegAlpha?.topDown, true)
    }

    /// `TOP_DOWN` is **bit 0** here and bit 2 on a bitmap. Two flag words, two
    /// positions, one name — read with the bitmap's mask, every one of these
    /// images comes out claiming the opposite orientation.
    func testTheTopDownFlagIsBitZeroHereAndNotBitTwo() throws {
        for (flags, expected) in [(UInt8(0x00), false), (0x01, true), (0x04, false)] {
            let built = message(
                type: 108, width: 1, height: 1,
                body: [flags] + u32(2) + u32(2) + [0xFF, 0xD8]
            )
            let image = try SpiceDisplayWire.image(
                at: built.offset, in: SpiceDisplayWire.Body(built.message)
            )
            XCTAssertEqual(
                image?.jpegAlpha?.topDown, expected,
                "drapeaux \(flags) : bit 0, pas bit 2"
            )
        }
    }

    /// A JPEG longer than the payload that contains it is a message
    /// disagreeing with itself, and it is refused before anything is split.
    func testAJPEGLongerThanItsOwnPayloadIsRefused() {
        let built = message(
            type: 108, width: 8, height: 6,
            body: [0x01] + u32(99) + u32(4) + [1, 2, 3, 4]
        )
        XCTAssertThrowsError(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        ) { XCTAssertEqual($0 as? SpiceError, .invalidData) }
    }

    /// Undecodable bytes leave the rectangle alone rather than dropping the
    /// connection. That is the same rule the other encodings follow: an image
    /// this client cannot render is not a malformed message.
    func testRubbishWhereAJPEGShouldBeIsUndrawableRatherThanFatal() throws {
        let built = message(
            type: 105, width: 4, height: 4, body: u32(4) + [0, 1, 2, 3]
        )
        let image = try XCTUnwrap(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image))
    }

    /// The alpha half must be an `xxxa` stream. Any other type would be a
    /// second colour pass quietly overwriting the JPEG.
    func testAnAlphaHalfThatIsNotAnAlphaStreamIsRefused() throws {
        let colourStream = hex(SpiceLZFixtures.all[0].stream)
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        XCTAssertThrowsError(try SpiceLZ.applyAlpha(colourStream, to: &pixels)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .unsupportedImageType(.rgb32))
        }
    }

    /// The alpha pass writes only the fourth byte, leaving what was already
    /// there. That is the whole point of it: the colour came from the JPEG.
    func testTheAlphaPassLeavesTheColourItWasGivenAlone() throws {
        let fixture = alphaFixture
        let count = fixture.width * fixture.height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        for pixel in 0..<count {
            pixels[pixel * 4] = 0x11
            pixels[pixel * 4 + 1] = 0x22
            pixels[pixel * 4 + 2] = 0x33
            pixels[pixel * 4 + 3] = 0xEE   // must be overwritten
        }

        let header = try SpiceLZ.applyAlpha(hex(fixture.stream), to: &pixels)
        XCTAssertEqual(header.type, .xxxa)
        XCTAssertEqual(header.width, fixture.width)

        // The fixture's own output carries the alpha the reference decoder
        // produced, in its fourth bytes.
        let reference = hex(fixture.original)
        for pixel in 0..<count {
            XCTAssertEqual(pixels[pixel * 4], 0x11, "pixel \(pixel) : le bleu du JPEG")
            XCTAssertEqual(pixels[pixel * 4 + 1], 0x22, "pixel \(pixel) : le vert")
            XCTAssertEqual(pixels[pixel * 4 + 2], 0x33, "pixel \(pixel) : le rouge")
            XCTAssertEqual(
                pixels[pixel * 4 + 3], reference[pixel * 4 + 3],
                "pixel \(pixel) : l'opacité du décodeur de référence"
            )
        }
    }

    // MARK: - Real pixels, where there is a decoder

    #if canImport(ImageIO)
    private func encodeJPEG(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        var source = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            source[pixel * 4] = blue
            source[pixel * 4 + 1] = green
            source[pixel * 4 + 2] = red
            source[pixel * 4 + 3] = 255
        }
        let context = try XCTUnwrap(source.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        })
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The whole thing: a real JPEG for the colour, the reference-encoded
    /// `xxxa` stream for the opacity, both halves in one payload, decoded
    /// through the entry point the session uses.
    func testAJPEGAndItsAlphaStreamBecomeOneImage() throws {
        let fixture = alphaFixture
        let jpeg = try encodeJPEG(
            width: fixture.width, height: fixture.height, red: 200, green: 40, blue: 60
        )
        let alpha = hex(fixture.stream)

        let built = message(
            type: 108, width: UInt32(fixture.width), height: UInt32(fixture.height),
            body: [0x01 /* TOP_DOWN */] + u32(UInt32(jpeg.count))
                + u32(UInt32(jpeg.count + alpha.count)) + [UInt8](jpeg) + alpha
        )
        let image = try XCTUnwrap(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        )
        let decoded = try XCTUnwrap(try SpiceDisplayWire.pixels(of: image))

        XCTAssertEqual(decoded.width, fixture.width)
        XCTAssertEqual(decoded.height, fixture.height)

        let reference = hex(fixture.original)
        for pixel in 0..<(fixture.width * fixture.height) {
            // Opacity is exact: it did not go through a lossy codec.
            XCTAssertEqual(
                decoded.pixels[pixel * 4 + 3], reference[pixel * 4 + 3],
                "pixel \(pixel) : l'opacité vient du flux, pas du JPEG"
            )
            // Colour is lossy, so it is checked as "near", on a flat image
            // where JPEG has nothing to smear.
            XCTAssertEqual(Int(decoded.pixels[pixel * 4 + 2]), 200, accuracy: 12)
            XCTAssertEqual(Int(decoded.pixels[pixel * 4 + 1]), 40, accuracy: 12)
            XCTAssertEqual(Int(decoded.pixels[pixel * 4]), 60, accuracy: 12)
        }
    }

    /// A plain SPICE JPEG, with no alpha half at all.
    func testAPlainJPEGImageBecomesPixels() throws {
        let jpeg = try encodeJPEG(width: 8, height: 8, red: 10, green: 220, blue: 30)
        let built = message(
            type: 105, width: 8, height: 8,
            body: u32(UInt32(jpeg.count)) + [UInt8](jpeg)
        )
        let image = try XCTUnwrap(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        )
        let decoded = try XCTUnwrap(try SpiceDisplayWire.pixels(of: image))

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.pixels.count, 8 * 8 * 4)
        XCTAssertEqual(Int(decoded.pixels[1]), 220, accuracy: 12)
        XCTAssertEqual(decoded.pixels[3], 255, "opaque : ce type ne porte pas d'alpha")
    }

    /// The two halves disagreeing about orientation yields nothing, rather
    /// than a picture whose opacity is upside down. The reference canvas
    /// refuses it too.
    func testHalvesThatDisagreeAboutOrientationYieldNothing() throws {
        let fixture = alphaFixture
        let jpeg = try encodeJPEG(
            width: fixture.width, height: fixture.height, red: 1, green: 2, blue: 3
        )
        let alpha = hex(fixture.stream)   // its own header says top-down

        // The outer flag says bottom-up; the stream says otherwise.
        let built = message(
            type: 108, width: UInt32(fixture.width), height: UInt32(fixture.height),
            body: [0x00] + u32(UInt32(jpeg.count))
                + u32(UInt32(jpeg.count + alpha.count)) + [UInt8](jpeg) + alpha
        )
        let image = try XCTUnwrap(
            try SpiceDisplayWire.image(at: built.offset, in: SpiceDisplayWire.Body(built.message))
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image))
    }
    #endif
}
