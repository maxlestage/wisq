import XCTest
import WisqCore
import WisqNet
@testable import WisqRemote

final class ReconnectingSessionTests: XCTestCase {
    /// Millisecond backoff so the tests run at test speed.
    private static let fastPolicy = ReconnectPolicy(
        maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(4)
    )

    /// Handshake bytes for a healthy no-auth server.
    private static func healthyScript() -> Data {
        var data = Data("RFB 003.008\n".utf8)
        data.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: [0x02, 0x80, 0x01, 0xE0])           // 640×480
        data.append(PixelFormat.bgra32.encoded)
        data.append(contentsOf: [0, 0, 0, 4])
        data.append(contentsOf: Array("wisq".utf8))
        return data
    }

    /// First connection dies mid-handshake; the second succeeds. The session
    /// object must survive the drop and come back ready.
    func testReconnectsAfterANetworkDrop() async throws {
        let attempts = Attempts()
        let session = ReconnectingSession(policy: Self.fastPolicy) { framebuffer in
            let attempt = attempts.next()
            let script = attempt == 1 ? Data("RFB 003.008\n".utf8) : Self.healthyScript()
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: script) }
            )
        }

        await session.start()

        var sawReconnecting = false
        var ready = false
        for await event in session.events {
            switch event {
            case .reconnecting(let attempt):
                XCTAssertEqual(attempt, 1)
                sawReconnecting = true
            case .ready(let name, let width, let height):
                XCTAssertEqual(name, "wisq")
                XCTAssertEqual(width, 640)
                XCTAssertEqual(height, 480)
                ready = true
            case .disconnected(let error):
                XCTAssertNil(error)
            default:
                break
            }
            if ready { break }
        }

        XCTAssertTrue(sawReconnecting, "la coupure aurait dû déclencher une reconnexion")
        XCTAssertEqual(attempts.count, 2)
        // The renderer's framebuffer reference must be the one the new session wrote.
        XCTAssertEqual(session.framebuffer.snapshot().width, 640)
        await session.stop()
    }

    /// A wrong password must not be retried: hammering auth can lock accounts.
    func testAuthenticationFailureIsTerminal() async throws {
        let attempts = Attempts()
        let session = ReconnectingSession(policy: Self.fastPolicy) { framebuffer in
            _ = attempts.next()
            var script = Data("RFB 003.008\n".utf8)
            script.append(contentsOf: [1, RFB.SecurityType.vncAuth.rawValue])
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: script) }
            )
        }

        await session.start()

        var outcome: WisqError?
        for await event in session.events {
            if case .disconnected(let error) = event {
                outcome = error
                break
            }
        }

        XCTAssertEqual(outcome, .authenticationRequired)
        XCTAssertEqual(attempts.count, 1, "une erreur d'authentification ne doit pas être retentée")
    }

    /// When every attempt fails, the last error surfaces after the budget runs out.
    func testGivesUpAfterMaxAttempts() async throws {
        let attempts = Attempts()
        let session = ReconnectingSession(policy: Self.fastPolicy) { framebuffer in
            _ = attempts.next()
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: Data("RFB 003.008\n".utf8)) }
            )
        }

        await session.start()

        var reconnects = 0
        var outcome: WisqError?
        for await event in session.events {
            switch event {
            case .reconnecting:
                reconnects += 1
            case .disconnected(let error):
                outcome = error
            default:
                break
            }
        }

        XCTAssertEqual(reconnects, 3)
        XCTAssertEqual(attempts.count, 4, "l'essai initial plus trois reconnexions")
        XCTAssertEqual(outcome, .connectionClosed)
    }

    func testBackoffGrowsAndCaps() {
        let policy = ReconnectPolicy(
            maxAttempts: 10, initialDelay: .seconds(1), maxDelay: .seconds(30), multiplier: 2
        )
        XCTAssertEqual(policy.delay(forAttempt: 1), .seconds(1))
        XCTAssertEqual(policy.delay(forAttempt: 2), .seconds(2))
        XCTAssertEqual(policy.delay(forAttempt: 4), .seconds(8))
        XCTAssertEqual(policy.delay(forAttempt: 10), .seconds(30), "le plafond doit tenir")
    }

    /// Thread-safe attempt counter for the factory closures.
    private final class Attempts: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
