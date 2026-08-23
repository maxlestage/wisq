import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

/// Drives a full RFB 3.8 handshake against a scripted server held in memory.
final class VNCHandshakeTests: XCTestCase {
    func testHandshakeReachesReady() async throws {
        let stream = MemoryByteStream(inbound: Self.serverScript(name: "qemu-debian", width: 1024, height: 768))
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            streamProvider: { _ in stream }
        )

        await session.start()

        var ready: (name: String, width: Int, height: Int)?
        for await event in session.events {
            switch event {
            case .ready(let name, let width, let height):
                ready = (name, width, height)
            case .disconnected(let error):
                XCTAssertNil(error, "la session s'est terminée sur une erreur")
            default:
                break
            }
            if ready != nil { break }
        }

        XCTAssertEqual(ready?.name, "qemu-debian")
        XCTAssertEqual(ready?.width, 1024)
        XCTAssertEqual(ready?.height, 768)

        let written = [UInt8](await stream.written)
        XCTAssertEqual(Array(written.prefix(12)), Array("RFB 003.008\n".utf8))
        XCTAssertEqual(written[12], RFB.SecurityType.none.rawValue)
        XCTAssertEqual(written[13], 1, "le drapeau « partagé » doit rester activé")
        XCTAssertEqual(written[14], RFB.ClientMessage.setPixelFormat.rawValue)
    }

    func testMissingPasswordIsReportedBeforeConnecting() async throws {
        // Server offers VNC auth only, and the machine has no stored secret.
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, RFB.SecurityType.vncAuth.rawValue])
        let stream = MemoryByteStream(inbound: script)

        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            streamProvider: { _ in stream }
        )
        await session.start()

        var failure: WisqError?
        for await event in session.events {
            if case .disconnected(let error) = event {
                failure = error
                break
            }
        }
        XCTAssertEqual(failure, .authenticationRequired)
    }

    func testRejectsAServerThatIsNotSpeakingRFB() async throws {
        let stream = MemoryByteStream(inbound: Data("HTTP/1.1 20".utf8) + Data([0x30]))
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 80),
            streamProvider: { _ in stream }
        )
        await session.start()

        for await event in session.events {
            if case .disconnected(let error) = event {
                guard case .handshakeFailed = error else {
                    return XCTFail("erreur inattendue : \(String(describing: error))")
                }
                return
            }
        }
        XCTFail("la session aurait dû se terminer")
    }

    /// Bytes a compliant server sends, up to and including ServerInit.
    private static func serverScript(name: String, width: Int, height: Int) -> Data {
        var data = Data("RFB 003.008\n".utf8)
        data.append(contentsOf: [1, RFB.SecurityType.none.rawValue])   // one security type: None
        data.append(contentsOf: [0, 0, 0, 0])                          // SecurityResult: OK
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xFF)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xFF)])
        data.append(PixelFormat.bgra32.encoded)
        let nameBytes = Array(name.utf8)
        data.append(contentsOf: [0, 0, 0, UInt8(nameBytes.count)])
        data.append(contentsOf: nameBytes)
        return data
    }
}
