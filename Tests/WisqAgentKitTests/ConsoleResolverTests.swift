#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote
@testable import WisqAgentKit

/// The boot-before-connect flow, against a real agent: the resolver contacts the
/// daemon, powers the VM on, waits for its console, and rewrites the machine's
/// endpoint with what the agent reports.
final class ConsoleResolverTests: XCTestCase {
    private var server: HTTPServer!
    private var credentials: EphemeralCredentialStore!

    override func setUpWithError() throws {
        let service = AgentService(
            backend: DemoBackend(startupDelay: 0.05),
            token: "secret-token"
        )
        server = HTTPServer { service.handle($0) }
        try server.start(port: 0)
        credentials = EphemeralCredentialStore(seed: ["agent.test": "secret-token"])
    }

    override func tearDown() {
        server.stop()
    }

    private func machine(autoStart: Bool = true) -> Machine {
        Machine(
            name: "Debian 13",
            host: "adresse-perimee.local",
            port: 9999,
            proto: .vnc,
            agent: AgentBinding(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                vmIdentifier: "debian-13",
                autoStart: autoStart,
                credentialRef: "agent.test"
            )
        )
    }

    func testBootsTheVMAndRewritesTheEndpoint() async throws {
        let resolved = try await ConsoleResolver.resolve(
            machine(),
            credentials: credentials,
            timeout: .seconds(5),
            pollInterval: .milliseconds(20)
        )

        // The stale host and port stored on the machine must both be replaced by
        // what the agent reports once the VM is up.
        XCTAssertEqual(resolved.host, "127.0.0.1")
        XCTAssertEqual(resolved.port, 5901)
        XCTAssertEqual(resolved.proto, .vnc)
    }

    func testWithoutABindingNothingChanges() async throws {
        let plain = Machine(name: "Direct", host: "10.0.0.5", port: 5900)
        let resolved = try await ConsoleResolver.resolve(plain, credentials: credentials)
        XCTAssertEqual(resolved, plain)
    }

    func testAutoStartOffRefusesToBootAStoppedVM() async throws {
        do {
            _ = try await ConsoleResolver.resolve(
                machine(autoStart: false),
                credentials: credentials,
                timeout: .seconds(5),
                pollInterval: .milliseconds(20)
            )
            XCTFail("une VM arrêtée sans démarrage automatique doit être une erreur")
        } catch let error as WisqError {
            guard case .agentFailure(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("Debian 13"), "le message doit nommer la VM : \(message)")
        }
    }

    func testWrongTokenSurfacesTheAgentError() async throws {
        try credentials.setSecret("mauvais-jeton", for: "agent.test")
        do {
            _ = try await ConsoleResolver.resolve(
                machine(),
                credentials: credentials,
                timeout: .seconds(5),
                pollInterval: .milliseconds(20)
            )
            XCTFail("un jeton invalide doit faire échouer la résolution")
        } catch let error as WisqError {
            guard case .agentFailure = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
    }
}
#endif
