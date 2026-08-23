import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

final class CursorDecodingTests: XCTestCase {
    /// A 3×2 cursor with hotspot (2,1): pixels in negotiated BGRX order, then a
    /// bitmask whose rows pad to a byte, MSB = leftmost pixel.
    func testDecodesPixelsAndAppliesTheMask() async throws {
        var data = Data()
        data.append(contentsOf: [0, 2, 0, 1])            // hotspot x=2, y=1
        data.append(contentsOf: [0, 3, 0, 2])            // 3×2
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x11]) // encoding -239
        for value in 1...6 {                              // six BGRX pixels
            data.append(contentsOf: [UInt8(value), UInt8(value), UInt8(value), 0])
        }
        data.append(contentsOf: [0b1010_0000, 0b0100_0000]) // row masks

        let decoder = RFBDecoder(
            stream: MemoryByteStream(inbound: data),
            framebuffer: Framebuffer(width: 1, height: 1),
            streams: try RFBStreams()
        )
        guard case .cursorChanged(let cursor) = try await decoder.decodeRectangle() else {
            return XCTFail("le pseudo-encodage Cursor doit produire un curseur")
        }

        XCTAssertEqual(cursor.width, 3)
        XCTAssertEqual(cursor.height, 2)
        XCTAssertEqual(cursor.hotspotX, 2)
        XCTAssertEqual(cursor.hotspotY, 1)
        // Row 0: visible, hidden, visible. Row 1: hidden, visible, hidden.
        let alphas = stride(from: 3, to: cursor.bgra.count, by: 4).map { cursor.bgra[$0] }
        XCTAssertEqual(alphas, [255, 0, 255, 0, 255, 0])
        XCTAssertEqual(Array(cursor.bgra[0..<3]), [1, 1, 1], "les octets de couleur restent tels quels")
    }

    func testEmptyCursorHidesRatherThanFails() async throws {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x11])

        let decoder = RFBDecoder(
            stream: MemoryByteStream(inbound: data),
            framebuffer: Framebuffer(width: 1, height: 1),
            streams: try RFBStreams()
        )
        guard case .cursorChanged(let cursor) = try await decoder.decodeRectangle() else {
            return XCTFail("attendu un curseur")
        }
        XCTAssertTrue(cursor.isEmpty)
    }
}

final class ContinuousUpdatesTests: XCTestCase {
    /// Server: full handshake, then the unprompted EndOfContinuousUpdates that
    /// announces support, then one framebuffer update.
    private static func script() -> Data {
        var data = Data("RFB 003.008\n".utf8)
        data.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [0x02, 0x80, 0x01, 0xE0])           // 640×480
        data.append(PixelFormat.bgra32.encoded)
        data.append(contentsOf: [0, 0, 0, 4])
        data.append(contentsOf: Array("wisq".utf8))
        data.append(150)                                             // EndOfContinuousUpdates
        // One update: a single raw 1×1 rectangle.
        data.append(contentsOf: [0, 0, 0, 1])                        // header + count
        data.append(contentsOf: [0, 0, 0, 0, 0, 1, 0, 1])            // rect 1×1 at origin
        data.append(contentsOf: [0, 0, 0, 0])                        // encoding raw
        data.append(contentsOf: [7, 7, 7, 0])                        // one pixel
        return data
    }

    func testEnablesOnAnnouncementAndStopsPollingPerFrame() async throws {
        let stream = MemoryByteStream(inbound: Self.script())
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            streamProvider: { _ in stream }
        )
        await session.start()

        var sawFrame = false
        for await event in session.events {
            switch event {
            case .framebufferChanged:
                sawFrame = true
            case .disconnected:
                break
            default:
                continue
            }
            if sawFrame { break }
        }
        XCTAssertTrue(sawFrame)

        let written = [UInt8](await stream.written)
        // The client must have answered the announcement with Enable(1, full screen).
        let expectedEnable: [UInt8] = [150, 1, 0, 0, 0, 0, 0x02, 0x80, 0x01, 0xE0]
        XCTAssertTrue(
            written.contains(subsequence: expectedEnable),
            "EnableContinuousUpdates plein écran attendu dans le flux sortant"
        )
        // Exactly one FramebufferUpdateRequest: the initial full request. The
        // update that followed the announcement must NOT have triggered another.
        let requestCount = written.count(ofMessageType: 3, payloadLength: 9)
        XCTAssertEqual(requestCount, 1, "en mode continu, plus aucune demande par image")
        await session.stop()
    }

    func testAdvertisesTheContinuousUpdatesPseudoEncoding() {
        XCTAssertTrue(
            RFB.preferredEncodings(lowBandwidth: false).contains(RFB.Encoding.continuousUpdates.rawValue)
        )
    }

    func testCursorPseudoEncodingFollowsTheSetting() {
        XCTAssertTrue(
            RFB.preferredEncodings(lowBandwidth: false, localCursor: true)
                .contains(RFB.Encoding.cursor.rawValue)
        )
        XCTAssertFalse(
            RFB.preferredEncodings(lowBandwidth: false, localCursor: false)
                .contains(RFB.Encoding.cursor.rawValue)
        )
    }
}

private extension [UInt8] {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return (0...(count - needle.count)).contains { start in
            Array(self[start..<(start + needle.count)]) == needle
        }
    }

    /// Counts wire messages of one type by walking known message lengths. Only
    /// valid for the fixed-length client messages used in these tests.
    func count(ofMessageType type: UInt8, payloadLength: Int) -> Int {
        // The outgoing stream is: 12-byte version, 1-byte security choice,
        // 1-byte shared flag, then framed client messages. Walk them.
        var index = 14
        var found = 0
        while index < count {
            let messageType = self[index]
            let length: Int
            switch messageType {
            case 0: length = 20                                   // SetPixelFormat
            case 2:
                guard index + 4 <= count else { return found }
                let n = Int(self[index + 2]) << 8 | Int(self[index + 3])
                length = 4 + n * 4                                // SetEncodings
            case 3: length = 10                                   // UpdateRequest
            case 4: length = 8                                    // KeyEvent
            case 5: length = 6                                    // PointerEvent
            case 150: length = 10                                 // EnableContinuousUpdates
            default: return found                                 // unknown: stop walking
            }
            if messageType == type { found += 1 }
            index += length
        }
        return found
    }
}
