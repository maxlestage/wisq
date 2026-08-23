#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote

/// The boot-before-connect flow, against a real agent: the resolver contacts the
/// daemon, powers the VM on, waits for its console, and rewrites the machine's
/// endpoint with what the agent reports.
final class ConsoleResolverTests: XCTestCase {
    private var agent: RustAgentProcess!
    private var credentials: EphemeralCredentialStore!

    override func setUpWithError() throws {
        agent = try RustAgentProcess()
        credentials = EphemeralCredentialStore(seed: ["agent.test": agent.token])
    }

    override func tearDown() {
        agent?.stop()
        agent = nil
    }

    private func machine(autoStart: Bool = true) -> Machine {
        Machine(
            name: "Debian 13",
            host: "adresse-perimee.local",
            port: 9999,
            proto: .vnc,
            agent: AgentBinding(
                baseURL: agent.baseURL,
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

#if os(macOS) || os(Linux)
/// The full loop the QR code closes: the daemon builds a URL, the app parses it
/// back to exactly the endpoint and token the daemon meant.
final class PairingTests: XCTestCase {
    private var agent: RustAgentProcess!

    override func setUpWithError() throws {
        agent = try RustAgentProcess()
    }

    override func tearDown() {
        agent?.stop()
        agent = nil
    }

    /// The pairing links the daemon prints must be the ones the app can read.
    /// Generation is Rust now and parsing is Swift, so this is the seam where a
    /// drift would show up — and it would show up as a link that silently does
    /// nothing when a person taps it.
    func testTheDaemonsPairingLinksParseWithTheAppsParser() throws {
        let urls = agent.pairingURLs
        XCTAssertFalse(urls.isEmpty, "le démon doit proposer au moins un lien d'appairage")

        for url in urls {
            let payload = try AgentPairing.parse(url)
            XCTAssertEqual(payload.token, agent.token)
            XCTAssertEqual("http://127.0.0.1:\(payload.port)", agent.baseURL.absoluteString)
            XCTAssertFalse(payload.host.isEmpty)
        }
    }

    func testPairingLinksNeverOfferLoopback() {
        for url in agent.pairingURLs {
            XCTAssertFalse(
                url.absoluteString.contains("host=127."),
                "un lien vers la boucle locale ne sert à rien depuis un téléphone : \(url)"
            )
        }
    }
}
#endif
