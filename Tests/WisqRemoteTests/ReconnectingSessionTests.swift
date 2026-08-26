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
            // `let` binding: a captured var would race under Swift 6 rules.
            let script: Data = attempts.next() == 1 ? Data("RFB 003.008\n".utf8) : Self.healthyScript()
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
            let script = Data("RFB 003.008\n".utf8) + Data([1, RFB.SecurityType.vncAuth.rawValue])
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

    /// A connection that lives long enough to build decoder state, then drops.
    ///
    /// Every other test here kills the first attempt **mid-handshake**, before
    /// any decoder exists. That leaves the claim in `ReconnectingSession`'s own
    /// doc comment — "the zlib dictionaries above all die with the underlying
    /// session and are rebuilt fresh" — asserted in prose and exercised by
    /// nothing. It is one of the two properties that comment calls load-bearing,
    /// and it is the one no test could see go.
    ///
    /// The instrument is the fixture itself rather than any assertion about
    /// objects. `zlibRect` is a complete deflate stream: it opens with the two
    /// header bytes `78 9C` and closes with `Z_SYNC_FLUSH`. Fed to a *fresh*
    /// inflate stream it decodes; fed to one that already read it once, those
    /// same two bytes are not a header any more but compressed data, and the
    /// decode fails or returns something else. So sending the identical bytes
    /// on both connections asks exactly the question — is this a new stream? —
    /// and the answer is a pixel value, not a timing.
    ///
    /// The two rectangles land at different coordinates, and the pixel the
    /// first one wrote is asserted **blank** afterwards. Without that, a green
    /// could mean the second connection decoded correctly or that nobody wiped
    /// the first one's work; those are different worlds and the test has to
    /// separate them.
    func testDecoderStateDoesNotSurviveAReconnect() async throws {
        let attempts = Attempts()
        let session = ReconnectingSession(policy: Self.fastPolicy) { framebuffer in
            let script: Data = attempts.next() == 1
                ? Self.scriptWithAZlibRectangle(x: 0)
                : Self.scriptWithAZlibRectangle(x: 4)
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: script) }
            )
        }

        await session.start()

        // Two connections, so two `.ready`s. The second one is the one under
        // test; waiting for its framebuffer change is what says its decode ran.
        var readies = 0
        var paintedAfterReconnect = false
        for await event in session.events {
            switch event {
            case .ready:
                readies += 1
            case .framebufferChanged where readies == 2:
                paintedAfterReconnect = true
            default:
                break
            }
            if paintedAfterReconnect { break }
        }

        XCTAssertEqual(attempts.count, 2, "la seconde connexion n'a pas eu lieu")
        XCTAssertTrue(paintedAfterReconnect)

        let framebuffer = session.framebuffer
        // Decoded by a stream that had never seen these bytes before.
        XCTAssertEqual(CompressedHarness.pixel(framebuffer, 4, 0), [0x30, 0x20, 0x10, 255])
        XCTAssertEqual(CompressedHarness.pixel(framebuffer, 5, 0), [0x60, 0x50, 0x40, 255])
        // And the first connection's pixel is gone, so the two above cannot be
        // leftovers.
        XCTAssertEqual(CompressedHarness.pixel(framebuffer, 0, 0), [0, 0, 0, 0])

        await session.stop()
    }

    /// The healthy handshake followed by one framebuffer update carrying a
    /// single zlib-encoded rectangle, two pixels wide.
    private static func scriptWithAZlibRectangle(x: Int) -> Data {
        var data = healthyScript()
        data.append(contentsOf: [0, 0, 0, 1])                    // FramebufferUpdate, 1 rectangle
        data.append(contentsOf: [0, UInt8(x), 0, 0])             // x, y = 0
        data.append(contentsOf: [0, 2, 0, 1])                    // 2 × 1
        data.append(contentsOf: [0, 0, 0, 6])                    // encoding 6, zlib
        data.append(contentsOf: CompressedFixtures.zlibRect)
        return data
    }

    /// A server that finishes the handshake and then drops, over and over.
    ///
    /// This is the shape the budget could not stop. `.ready` used to refill it,
    /// and every server emits `.ready` — including one that completes the
    /// handshake and dies a millisecond later. Measured before the fix: with
    /// `maxAttempts` at 3, the loop had reconnected **13** times and was still
    /// going when the counter below cut it off. Worse than unbounded, it was
    /// unbounded *at full speed*: `attempt` was 1 again after every reset, so
    /// `delay(forAttempt: 1)` returned `initialDelay` for ever and the
    /// exponential backoff never happened either.
    ///
    /// The reader would have seen a session that never connects and never
    /// fails, while the phone re-handshakes once a second until the battery
    /// runs out.
    ///
    /// A `healthyScript()` with nothing after it is exactly that server: the
    /// handshake completes, `.ready` goes out, and the next read hits the end
    /// of the data — `connectionClosed`, which is retryable, as it should be.
    func testAServerThatDropsRightAfterTheHandshakeStillRunsOutOfBudget() async throws {
        let attempts = Attempts()
        let session = ReconnectingSession(policy: Self.fastPolicy) { framebuffer in
            _ = attempts.next()
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: Self.healthyScript()) }
            )
        }

        await session.start()

        var reconnects = 0
        var outcome: WisqError?
        var readies = 0
        for await event in session.events {
            switch event {
            case .ready:
                readies += 1
            case .reconnecting:
                reconnects += 1
            case .disconnected(let error):
                outcome = error
            default:
                break
            }
            // A guard rather than an assertion: without the fix this stream
            // never ends, and a test that hangs reports nothing at all.
            if reconnects > Self.fastPolicy.maxAttempts + 5 { break }
        }

        XCTAssertEqual(reconnects, 3, "le budget doit s'épuiser malgré les .ready")
        XCTAssertEqual(attempts.count, 4, "l'essai initial plus trois reconnexions")
        XCTAssertEqual(outcome, .connectionClosed, "l'échec doit finir par remonter")
        // Each attempt really did get through the handshake — otherwise this
        // would be the ordinary mid-handshake case another test already covers,
        // and it would prove nothing about `.ready` refilling the budget.
        XCTAssertEqual(readies, 4)

        await session.stop()
    }

    /// The other edge, and it is the one over-correcting would break.
    ///
    /// A phone changes network constantly; a session that came up, was used and
    /// then lost its socket must get the full schedule again, or the retry
    /// budget becomes a lifetime quota and the fifth cell handoff of the day
    /// drops the user back to the machine list.
    ///
    /// The threshold is set to zero here rather than waiting out a real one:
    /// what is under test is the rule — a connection that lasts long enough
    /// refills the budget — and pinning it to a stopwatch would make the test
    /// answer a question about this container's scheduler instead.
    func testAConnectionThatLastsLongEnoughStillRefillsTheBudget() async throws {
        let policy = ReconnectPolicy(
            maxAttempts: 3, initialDelay: .milliseconds(1), maxDelay: .milliseconds(4),
            minimumUptimeToResetBudget: .zero
        )
        let attempts = Attempts()
        let session = ReconnectingSession(policy: policy) { framebuffer in
            _ = attempts.next()
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in MemoryByteStream(inbound: Self.healthyScript()) }
            )
        }

        await session.start()

        var reconnects = 0
        for await event in session.events {
            if case .reconnecting = event { reconnects += 1 }
            if reconnects > policy.maxAttempts + 2 { break }
        }
        await session.stop()

        XCTAssertGreaterThan(
            reconnects, policy.maxAttempts,
            "une connexion qui a duré doit rendre son budget"
        )
    }

    /// The third condition, which the two tests above cannot separate.
    ///
    /// The budget is refilled only when a connection **both** reached `.ready`
    /// and lasted. Drop the `.ready` half and the rule still passes every test
    /// above, because a connection that dies in the handshake also dies fast —
    /// the two conditions agree in every case those tests build. They part here:
    /// a handshake that hangs for longer than the floor and then fails is a long
    /// connection that never worked, and it must not buy another round.
    ///
    /// The sleep is the point rather than an inconvenience, so the numbers leave
    /// room: a 20 ms floor against a 120 ms stall. A loaded container can only
    /// make the stall longer, which pushes further into the case under test; the
    /// assertion is that the budget runs out, and no amount of slowness turns
    /// that green by accident.
    func testASlowHandshakeThatFailsDoesNotBuyAnotherRound() async throws {
        let policy = ReconnectPolicy(
            maxAttempts: 2, initialDelay: .milliseconds(1), maxDelay: .milliseconds(4),
            minimumUptimeToResetBudget: .milliseconds(20)
        )
        let attempts = Attempts()
        let session = ReconnectingSession(policy: policy) { framebuffer in
            _ = attempts.next()
            return VNCSession(
                configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
                framebuffer: framebuffer,
                streamProvider: { _ in StallingByteStream(before: Data("RFB 003.008\n".utf8)) }
            )
        }

        await session.start()

        var reconnects = 0
        var readies = 0
        var outcome: WisqError?
        for await event in session.events {
            switch event {
            case .ready: readies += 1
            case .reconnecting: reconnects += 1
            case .disconnected(let error): outcome = error
            default: break
            }
            if reconnects > policy.maxAttempts + 3 { break }
        }
        await session.stop()

        XCTAssertEqual(readies, 0, "aucune connexion n'a abouti : le test perdrait son sujet")
        XCTAssertEqual(reconnects, 2, "une poignée de main lente et ratée n'est pas un succès")
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

/// A stream that takes its time and then gives up.
///
/// `MemoryByteStream` throws the instant it runs out, which is the right
/// default and the wrong shape for one question: what a *slow* failure does to
/// the retry budget. This one answers the first read, then stalls before
/// reporting the peer gone.
actor StallingByteStream: ByteStream {
    private var pending: Data
    private let stall: Duration

    init(before data: Data, stall: Duration = .milliseconds(120)) {
        self.pending = data
        self.stall = stall
    }

    func read(exactly count: Int) async throws -> Data {
        if pending.count >= count, count > 0 {
            let chunk = pending.prefix(count)
            pending.removeFirst(count)
            return Data(chunk)
        }
        try? await Task.sleep(for: stall)
        throw WisqError.connectionClosed
    }

    func write(_ data: Data) async throws {}
    func close() {}
}
