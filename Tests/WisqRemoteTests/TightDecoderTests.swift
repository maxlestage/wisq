import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

final class TightDecoderTests: XCTestCase {
    private func decode(_ fixture: [UInt8], rect: Rect, into framebuffer: Framebuffer) async throws {
        try await CompressedHarness.decode(fixture, encoding: .tight, rect: rect, into: framebuffer)
    }

    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        CompressedHarness.pixel(framebuffer, x, y)
    }

    func testFill() async throws {
        let framebuffer = Framebuffer(width: 3, height: 3)
        try await decode(CompressedFixtures.tightFill, rect: Rect(x: 0, y: 0, width: 3, height: 3), into: framebuffer)
        // TPIXEL is R,G,B — the reverse of ZRLE's CPIXEL. R=0xAA G=0xBB B=0xCC.
        for x in 0..<3 {
            for y in 0..<3 {
                XCTAssertEqual(pixel(framebuffer, x, y), [0xCC, 0xBB, 0xAA, 255])
            }
        }
    }

    /// Six bytes is under the twelve-byte threshold, so the server sends them
    /// uncompressed and the zlib stream is not touched at all.
    func testCopyBelowCompressionThreshold() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        try await decode(CompressedFixtures.tightCopyShort, rect: Rect(x: 0, y: 0, width: 2, height: 1), into: framebuffer)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [3, 2, 1, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [6, 5, 4, 255])
    }

    func testCopyAboveCompressionThreshold() async throws {
        let framebuffer = Framebuffer(width: 4, height: 4)
        try await decode(CompressedFixtures.tightCopyLong, rect: Rect(x: 0, y: 0, width: 4, height: 4), into: framebuffer)
        for index in 0..<16 {
            let expected: [UInt8] = [
                UInt8(index * 7 % 256), UInt8(index * 5 % 256), UInt8(index * 3 % 256), 255,
            ]
            XCTAssertEqual(pixel(framebuffer, index % 4, index / 4), expected, "pixel \(index)")
        }
    }

    /// 780 compressed bytes need two bytes of compact length; a one-byte reader
    /// would take the continuation bit for data and desynchronise the socket.
    func testMultiByteCompactLength() async throws {
        let framebuffer = Framebuffer(width: 16, height: 16)
        try await decode(CompressedFixtures.tightCopyBig, rect: Rect(x: 0, y: 0, width: 16, height: 16), into: framebuffer)
        for index in 0..<256 {
            let expected: [UInt8] = [
                UInt8(index * 17 % 256), UInt8(index * 91 % 256), UInt8(index * 37 % 256), 255,
            ]
            XCTAssertEqual(pixel(framebuffer, index % 16, index / 16), expected, "pixel \(index)")
        }
    }

    func testPaletteFilterWithTwoColours() async throws {
        let framebuffer = Framebuffer(width: 10, height: 2)
        try await decode(CompressedFixtures.tightPalette, rect: Rect(x: 0, y: 0, width: 10, height: 2), into: framebuffer)
        let red: [UInt8] = [0, 0, 0xFF, 255]
        let blue: [UInt8] = [0xFF, 0, 0, 255]
        for x in 0..<10 {
            XCTAssertEqual(pixel(framebuffer, x, 0), x % 2 == 0 ? blue : red, "ligne 0, colonne \(x)")
            XCTAssertEqual(pixel(framebuffer, x, 1), x % 2 == 0 ? red : blue, "ligne 1, colonne \(x)")
        }
    }

    /// The gradient filter sends residuals against a prediction from the pixels
    /// left, above and above-left. If the prediction is wrong the error
    /// accumulates across the rectangle rather than staying local.
    func testGradientFilter() async throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        try await decode(CompressedFixtures.tightGradient, rect: Rect(x: 0, y: 0, width: 2, height: 2), into: framebuffer)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [30, 20, 10, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 0), [60, 50, 40, 255])
        XCTAssertEqual(pixel(framebuffer, 0, 1), [90, 80, 70, 255])
        XCTAssertEqual(pixel(framebuffer, 1, 1), [120, 110, 100, 255])
    }

    func testReservedControlByteIsRejected() async throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        do {
            try await decode([0xA0], rect: Rect(x: 0, y: 0, width: 2, height: 2), into: framebuffer)
            XCTFail("un octet de contrôle réservé doit interrompre la session")
        } catch let error as WisqError {
            guard case .malformedMessage = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
    }

    /// We never advertise a JPEG quality level, so a compliant server never sends
    /// JPEG. If one does anyway, fail loudly rather than paint garbage.
    func testJPEGIsRejectedRatherThanMisdecoded() async throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        do {
            try await decode([0x90], rect: Rect(x: 0, y: 0, width: 2, height: 2), into: framebuffer)
            XCTFail("le JPEG doit être signalé comme non pris en charge")
        } catch let error as WisqError {
            XCTAssertEqual(error, .unsupportedEncoding(RFB.Encoding.tight.rawValue))
        }
    }
}

final class ZlibEncodingTests: XCTestCase {
    func testRawPixelsThroughTheSessionStream() async throws {
        let framebuffer = Framebuffer(width: 2, height: 1)
        try await CompressedHarness.decode(
            CompressedFixtures.zlibRect,
            encoding: .zlib,
            rect: Rect(x: 0, y: 0, width: 2, height: 1),
            into: framebuffer
        )
        // The X byte is undefined on the wire and must be forced to opaque.
        XCTAssertEqual(CompressedHarness.pixel(framebuffer, 0, 0), [0x30, 0x20, 0x10, 255])
        XCTAssertEqual(CompressedHarness.pixel(framebuffer, 1, 0), [0x60, 0x50, 0x40, 255])
    }
}
