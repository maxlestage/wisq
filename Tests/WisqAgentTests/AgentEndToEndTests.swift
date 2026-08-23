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

    func testStopTearsDownTheConsole() async throws {
        _ = try await client.start(vm: "win11")
        _ = try await client.waitUntilRunning(
            vm: "win11", timeout: .seconds(5), pollInterval: .milliseconds(20)
        )
        let stopped = try await client.stop(vm: "win11")
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.consolePort)
    }
}
#endif
