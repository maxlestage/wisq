import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

final class RFBDecoderTests: XCTestCase {
    func testRawRectangleLandsInTheFramebuffer() async throws {
        var data = Data()
        data.append(contentsOf: [0, 1, 0, 1])                       // x = 1, y = 1
        data.append(contentsOf: [0, 2, 0, 1])                       // 2 × 1
        data.append(contentsOf: [0, 0, 0, 0])                       // encoding: Raw
        data.append(contentsOf: [10, 20, 30, 0, 40, 50, 60, 0])     // two BGRX pixels

        let framebuffer = Framebuffer(width: 4, height: 4)
        let decoder = RFBDecoder(stream: MemoryByteStream(inbound: data), framebuffer: framebuffer)

        guard case .painted(let rect) = try await decoder.decodeRectangle() else {
            return XCTFail("le rectangle aurait dû être dessiné")
        }
        XCTAssertEqual(rect, Rect(x: 1, y: 1, width: 2, height: 1))

        let pixels = framebuffer.snapshot().pixels
        let offset = (1 * 4 + 1) * 4
        XCTAssertEqual(Array(pixels[offset..<(offset + 8)]), [10, 20, 30, 255, 40, 50, 60, 255],
                       "l'octet X doit être forcé à 255 pour servir d'alpha")
    }

    func testRREPaintsBackgroundThenSubrectangles() async throws {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 0])                       // x = 0, y = 0
        data.append(contentsOf: [0, 2, 0, 2])                       // 2 × 2
        data.append(contentsOf: [0, 0, 0, 2])                       // encoding: RRE
        data.append(contentsOf: [0, 0, 0, 1])                       // one subrectangle
        data.append(contentsOf: [1, 1, 1, 0])                       // background
        data.append(contentsOf: [9, 9, 9, 0])                       // subrect colour
        data.append(contentsOf: [0, 1, 0, 1, 0, 1, 0, 1])           // at (1,1), 1 × 1

        let framebuffer = Framebuffer(width: 2, height: 2)
        let decoder = RFBDecoder(stream: MemoryByteStream(inbound: data), framebuffer: framebuffer)
        _ = try await decoder.decodeRectangle()

        let pixels = framebuffer.snapshot().pixels
        XCTAssertEqual(Array(pixels[0..<4]), [1, 1, 1, 255])
        XCTAssertEqual(Array(pixels[12..<16]), [9, 9, 9, 255])
    }

    func testDesktopSizeIsReportedRatherThanPainted() async throws {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [3, 32, 2, 88])                     // 800 × 600
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x21])           // encoding: -223

        let decoder = RFBDecoder(
            stream: MemoryByteStream(inbound: data),
            framebuffer: Framebuffer(width: 1, height: 1)
        )
        guard case .resized(let width, let height) = try await decoder.decodeRectangle() else {
            return XCTFail("DesktopSize aurait dû être signalé comme un redimensionnement")
        }
        XCTAssertEqual(width, 800)
        XCTAssertEqual(height, 600)
    }

    func testUnknownEncodingIsRejectedInsteadOfDesynchronising() async throws {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 0, 0, 1, 0, 1])
        data.append(contentsOf: [0x00, 0x00, 0x30, 0x39])           // encoding 12345

        let decoder = RFBDecoder(
            stream: MemoryByteStream(inbound: data),
            framebuffer: Framebuffer(width: 1, height: 1)
        )
        do {
            _ = try await decoder.decodeRectangle()
            XCTFail("un encodage inconnu doit interrompre la session")
        } catch let error as WisqError {
            XCTAssertEqual(error, .unsupportedEncoding(12345))
        }
    }
}
