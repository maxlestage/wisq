import XCTest
import WisqCore
@testable import WisqRemote
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class JPEGTests: XCTestCase {
    /// The quality pseudo-encoding licenses the server to send lossy rectangles,
    /// so it must only ever be advertised where a decoder actually exists.
    func testQualityIsOnlyAdvertisedWhereDecodable() {
        let advertised = RFB.preferredEncodings(lowBandwidth: false, jpegQuality: 6)
        if JPEGDecoder.isAvailable {
            XCTAssertTrue(advertised.contains(-26))   // -32 + 6
        } else {
            XCTAssertFalse(advertised.contains(where: { (-32...(-23)).contains($0) }))
        }
        // No quality requested: never advertised, decoder or not.
        XCTAssertFalse(
            RFB.preferredEncodings(lowBandwidth: false, jpegQuality: nil)
                .contains(where: { (-32...(-23)).contains($0) })
        )
    }

    /// Skipped rather than returned early where there is no decoder.
    ///
    /// It used to `return`, which reports the test as **passed** while it
    /// asserts nothing — and on Linux, where `JPEGDecoder` is unavailable,
    /// that is every run. A green tick for a body that never executed is worse
    /// than a red one: it is the shape of coverage without the substance.
    func testQualityIsClampedIntoTheSpecRange() throws {
        try XCTSkipUnless(JPEGDecoder.isAvailable, "pas de décodeur JPEG ici")
        XCTAssertTrue(RFB.preferredEncodings(lowBandwidth: false, jpegQuality: 42).contains(-23))
        XCTAssertTrue(RFB.preferredEncodings(lowBandwidth: false, jpegQuality: -3).contains(-32))
    }

    #if canImport(ImageIO)
    /// Self-contained round trip: encode a known image through ImageIO, decode it
    /// through our path, and check the colours survived (within JPEG loss).
    func testDecodesARealJPEG() throws {
        let width = 8, height = 8
        // Left half red, right half blue — big flat areas so JPEG stays accurate.
        var source = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                if x < width / 2 {
                    source[base] = 0; source[base + 1] = 0; source[base + 2] = 255      // red in BGRA
                } else {
                    source[base] = 255; source[base + 1] = 0; source[base + 2] = 0      // blue
                }
            }
        }

        let jpeg = try Self.encodeJPEG(bgra: source, width: width, height: height)
        let decoded = try JPEGDecoder.decode(jpeg)

        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        // Sample the centre of each half; JPEG loss stays well under this margin
        // on flat colour.
        let left = Array(decoded.bgra[((2 * width + 1) * 4)..<((2 * width + 1) * 4 + 4)])
        let right = Array(decoded.bgra[((2 * width + 6) * 4)..<((2 * width + 6) * 4 + 4)])
        XCTAssertGreaterThan(left[2], 200, "le côté gauche doit rester rouge")
        XCTAssertLessThan(left[0], 60)
        XCTAssertGreaterThan(right[0], 200, "le côté droit doit rester bleu")
        XCTAssertLessThan(right[2], 60)
        XCTAssertEqual(left[3], 255, "l'alpha doit être forcé opaque")
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try JPEGDecoder.decode(Data([0xFF, 0xD8, 0x00, 0x01, 0x02])))
    }

    private static func encodeJPEG(bgra: [UInt8], width: Int, height: Int) throws -> Data {
        var pixels = bgra
        let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else { throw WisqError.malformedMessage("contexte introuvable") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw WisqError.malformedMessage("destination introuvable") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WisqError.malformedMessage("encodage JPEG impossible")
        }
        return output as Data
    }
    #else
    /// Without ImageIO the decoder must refuse, not misdecode.
    func testDecoderRefusesWithoutImageIO() {
        XCTAssertFalse(JPEGDecoder.isAvailable)
        XCTAssertThrowsError(try JPEGDecoder.decode(Data([0xFF, 0xD8])))
    }
    #endif
}
