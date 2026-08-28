#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote

/// The full loop across two languages: the real Rust daemon on an ephemeral
/// port, spoken to by the same `AgentClient` the iPhone app embeds. If these
/// pass, the wire format documented in docs/AGENT-PROTOCOL.md is what both
/// sides actually implement — which is the only thing that matters now that
/// they are not written in the same language.
final class AgentEndToEndTests: XCTestCase {
    private var agent: RustAgentProcess!
    private var client: AgentClient!

    override func setUpWithError() throws {
        agent = try RustAgentProcess()
        client = AgentClient(baseURL: agent.baseURL, token: agent.token)
    }

    override func tearDown() {
        agent?.stop()
        agent = nil
    }

    func testListsVMs() async throws {
        let vms = try await client.listVMs()
        XCTAssertEqual(vms.map(\.id), ["debian-13", "win11"])
        XCTAssertEqual(vms[0].state, .stopped)
        XCTAssertEqual(vms[0].guestOS, .linux)
        XCTAssertEqual(vms[1].guestOS, .windows)
    }

    func testRejectsAMissingOrWrongToken() async throws {
        for client in [
            AgentClient(baseURL: agent.baseURL),
            AgentClient(baseURL: agent.baseURL, token: "wrong"),
            // A correct prefix must not be enough.
            AgentClient(baseURL: agent.baseURL, token: "secret"),
        ] {
            do {
                _ = try await client.listVMs()
                XCTFail("l'accès sans jeton valide doit être refusé")
            } catch let error as WisqError {
                guard case .agentFailure = error else {
                    return XCTFail("erreur inattendue : \(error)")
                }
            }
        }
    }

    func testUnknownVMIs404WithAReadableMessage() async throws {
        do {
            _ = try await client.status(vm: "nope")
            XCTFail("une VM inconnue doit être une erreur")
        } catch let error as WisqError {
            guard case .agentFailure(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("nope"), "le message doit nommer la VM : \(message)")
        }
    }

    /// The boot flow the app runs: start, then poll until running — exactly what
    /// `waitUntilRunning` does against a real host.
    func testStartThenWaitUntilRunning() async throws {
        let started = try await client.start(vm: "debian-13")
        XCTAssertEqual(started.state, .starting)
        XCTAssertNil(started.consolePort, "pas de console avant la fin du démarrage")

        let running = try await client.waitUntilRunning(
            vm: "debian-13",
            timeout: .seconds(5),
            pollInterval: .milliseconds(20)
        )
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.consolePort, 5901)
        XCTAssertEqual(running.consoleProtocol, .vnc)
    }

    /// Cutting the power tears the console down at once.
    ///
    /// This is the only place `force` is checked where it actually travels:
    /// the Rust tests call the backend directly, so they cannot show that the
    /// `{"force": true}` body survives being serialised, sent, parsed and
    /// routed. Here it crosses a real socket.
    func testForcingAStopTearsDownTheConsole() async throws {
        _ = try await client.start(vm: "win11")
        _ = try await client.waitUntilRunning(
            vm: "win11", timeout: .seconds(5), pollInterval: .milliseconds(20)
        )
        let stopped = try await client.stop(vm: "win11", force: true)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.consolePort)
    }

    /// And asking politely does not.
    ///
    /// This test used to assert `.stopped` here, because the daemon's demo
    /// backend ignored `force` and answered `stopped` to both — so three
    /// artefacts agreed with each other and none of them with libvirt, where
    /// `virsh shutdown` sends ACPI and returns while the guest is still
    /// running, console and all.
    ///
    /// The two halves are asserted separately: a `force: false` that behaved
    /// like a power cut fails the first, and one whose request never reached
    /// the guest fails the second.
    func testAGracefulStopIsARequestRatherThanAnAct() async throws {
        _ = try await client.start(vm: "debian-13")
        let running = try await client.waitUntilRunning(
            vm: "debian-13", timeout: .seconds(5), pollInterval: .milliseconds(20)
        )
        XCTAssertNotNil(running.consolePort)

        let asked = try await client.stop(vm: "debian-13", force: false)
        XCTAssertEqual(asked.state, .running, "un arrêt ACPI revient avant l'invité")
        XCTAssertNotNil(asked.consolePort, "et sa console est encore ouverte")

        // The daemon under test runs with a short delay, so the guest gets
        // there on its own — polled rather than slept through, so a slow
        // machine lengthens the test instead of failing it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await client.status(vm: "debian-13").state == .stopped { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("l'invité n'a jamais fini de s'arrêter")
    }
}
#endif
