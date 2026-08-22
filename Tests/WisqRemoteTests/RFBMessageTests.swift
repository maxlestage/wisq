import XCTest
import WisqCore
@testable import WisqRemote

final class RFBMessageTests: XCTestCase {
    func testPointerMessageLayout() {
        let data = VNCSession.pointerMessage(x: 300, y: 200, buttons: [.left])
        XCTAssertEqual([UInt8](data), [5, 0b0000_0001, 0x01, 0x2C, 0x00, 0xC8])
    }

    func testKeyMessageLayout() {
        let data = VNCSession.keyMessage(keysym: 0xFF0D, down: true)
        XCTAssertEqual([UInt8](data), [4, 1, 0, 0, 0x00, 0x00, 0xFF, 0x0D])
    }

    func testUpdateRequestLayout() {
        let data = VNCSession.updateRequestMessage(
            incremental: true,
            rect: Rect(x: 0, y: 0, width: 1024, height: 768)
        )
        XCTAssertEqual([UInt8](data), [3, 1, 0, 0, 0, 0, 0x04, 0x00, 0x03, 0x00])
    }

    func testPixelFormatIsBGRA32() {
        let bytes = [UInt8](PixelFormat.bgra32.encoded)
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(bytes[0], 32)     // bits per pixel
        XCTAssertEqual(bytes[1], 24)     // depth
        XCTAssertEqual(bytes[2], 0)      // little endian
        XCTAssertEqual(bytes[3], 1)      // true colour
        XCTAssertEqual(bytes[10], 16)    // red shift
        XCTAssertEqual(bytes[12], 0)     // blue shift
    }

    func testPixelFormatDecodeIsTheInverseOfEncode() throws {
        let decoded = try PixelFormat.decode(PixelFormat.bgra32.encoded)
        XCTAssertEqual(decoded, .bgra32)
    }

    func testAdvertisedEncodingsAreAllDecodable() {
        let decodable: Set<Int32> = [
            RFB.Encoding.raw.rawValue,
            RFB.Encoding.copyRect.rawValue,
            RFB.Encoding.rre.rawValue,
            RFB.Encoding.hextile.rawValue,
            RFB.Encoding.desktopSize.rawValue,
            RFB.Encoding.extendedDesktopSize.rawValue,
            RFB.Encoding.desktopName.rawValue,
            RFB.Encoding.lastRect.rawValue,
        ]
        // Advertising something we cannot decode would strand the stream mid-rectangle.
        for encoding in RFB.preferredEncodings(lowBandwidth: false) {
            XCTAssertTrue(decodable.contains(encoding), "encodage annoncé mais non décodable : \(encoding)")
        }
        for encoding in RFB.preferredEncodings(lowBandwidth: true) {
            XCTAssertTrue(decodable.contains(encoding), "encodage annoncé mais non décodable : \(encoding)")
        }
    }

    func testCutTextEncodesLatin1() {
        let data = VNCSession.cutTextMessage("café")
        XCTAssertEqual(data[0], 6)
        let length = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        XCTAssertEqual(length, 4)
        XCTAssertEqual(data[data.count - 1], 0xE9)   // é in latin-1
    }

    func testCutTextKeepsWhatItCanWhenTheTextIsNotLatin1() {
        // The spec is latin-1 only. Losing one emoji must not drop the whole paste.
        XCTAssertEqual(VNCSession.latin1Payload("café 🚀"), Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x3F]))
    }

    func testCutTextStripsCarriageReturns() {
        // RFB mandates LF-only line endings; a CR left in place confuses guests.
        XCTAssertEqual(VNCSession.latin1Payload("a\r\nb"), Data([0x61, 0x0A, 0x62]))
    }
}
