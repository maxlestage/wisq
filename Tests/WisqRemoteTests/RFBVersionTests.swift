import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

/// The version the client answers with, and the security handshake that goes
/// with it: see `RFB.Version`.
final class RFBVersionTests: XCTestCase {
    func testTheClientNeverAnswersAboveTheServer() {
        XCTAssertEqual(RFB.Version.negotiate("RFB 003.003\n"), .v3_3)
        XCTAssertEqual(RFB.Version.negotiate("RFB 003.005\n"), .v3_3, "3.5 is 3.3, per RFC 6143")
        XCTAssertEqual(RFB.Version.negotiate("RFB 003.007\n"), .v3_7)
        XCTAssertEqual(RFB.Version.negotiate("RFB 003.008\n"), .v3_8)
        XCTAssertEqual(RFB.Version.negotiate("RFB 003.889\n"), .v3_8, "Apple's 3.889")
        XCTAssertEqual(RFB.Version.negotiate("RFB 004.001\n"), .v3_8)
        XCTAssertNil(RFB.Version.negotiate("RFB 002.000\n"))
        XCTAssertNil(RFB.Version.negotiate("HTTP/1.1 200"))
        XCTAssertNil(RFB.Version.negotiate("RFB 003.008 "))
        XCTAssertEqual(RFB.Version.v3_3.reply, "RFB 003.003\n")
        XCTAssertEqual(RFB.Version.v3_7.reply, "RFB 003.007\n")
        XCTAssertEqual(RFB.Version.v3_8.reply, "RFB 003.008\n")
    }

    /// 3.3 with None: the server imposes the type, and nothing follows it.
    func testA33ServerWithoutAPasswordReachesReady() async throws {
        var script = Data("RFB 003.003\n".utf8)
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(Self.serverInit())
        let (outcome, written) = await Self.run(script, password: nil)
        XCTAssertEqual(outcome, "ready")
        XCTAssertEqual(Array(written.prefix(12)), Array("RFB 003.003\n".utf8))
        guard written.count > 12 else { return XCTFail("the client stopped after \(written.count) bytes") }
        XCTAssertEqual(written[12], 1, "the shared flag comes straight after: no type is chosen in 3.3")
    }

    /// 3.3 with VNC authentication: challenge, response, a result.
    func testA33ServerWithAPasswordReachesReady() async throws {
        var script = Data("RFB 003.003\n".utf8)
        script.append(contentsOf: [0, 0, 0, 2])
        script.append(Data(repeating: 0x5A, count: 16))
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInit())
        let (outcome, written) = await Self.run(script, password: "secret")
        XCTAssertEqual(outcome, "ready")
        let response = VNCAuth.response(challenge: Data(repeating: 0x5A, count: 16), password: "secret")
        guard written.count > 28 else { return XCTFail("the client stopped after \(written.count) bytes") }
        XCTAssertEqual(Array(written[12..<28]), Array(response))
        XCTAssertEqual(written[28], 1)
    }

    /// 3.3 refusing outright says why.
    func testA33RefusalCarriesItsReason() async throws {
        var script = Data("RFB 003.003\n".utf8)
        script.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 4])
        script.append(Data("plus".utf8))
        let (outcome, _) = await Self.run(script, password: nil)
        XCTAssertEqual(outcome, String(describing: WisqError.handshakeFailed("plus")))
    }

    /// 3.7 with None: a list, and no result after it.
    func testA37ServerWithoutAPasswordReachesReady() async throws {
        var script = Data("RFB 003.007\n".utf8)
        script.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        script.append(Self.serverInit())
        let (outcome, written) = await Self.run(script, password: nil)
        XCTAssertEqual(outcome, "ready")
        XCTAssertEqual(Array(written.prefix(12)), Array("RFB 003.007\n".utf8))
    }

    /// 3.7 refusing a password sends no reason after the result.
    func testA37RefusedPasswordIsAnAuthenticationFailure() async throws {
        var script = Data("RFB 003.007\n".utf8)
        script.append(contentsOf: [1, RFB.SecurityType.vncAuth.rawValue])
        script.append(Data(repeating: 1, count: 16))
        script.append(contentsOf: [0, 0, 0, 1])
        let (outcome, _) = await Self.run(script, password: "faux")
        XCTAssertEqual(outcome, String(describing: WisqError.authenticationFailed("mot de passe refusé")))
    }

    private static func serverInit() -> Data {
        var data = Data([0x04, 0x00, 0x03, 0x00])
        data.append(PixelFormat.bgra32.encoded)
        data.append(contentsOf: [0, 0, 0, 3])
        data.append(Data("old".utf8))
        return data
    }

    /// "ready", or the error the session ended on, and what the client wrote.
    private static func run(_ script: Data, password: String?) async -> (String, [UInt8]) {
        let stream = MemoryByteStream(inbound: script)
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900, password: password),
            streamProvider: { _ in stream })
        await session.start()
        var outcome = "ended"
        for await event in session.events {
            if case .ready = event { outcome = "ready"; break }
            if case .disconnected(let error) = event {
                outcome = error.map { String(describing: $0) } ?? "ended"
                break
            }
        }
        await session.stop()
        return (outcome, [UInt8](await stream.written))
    }
}
