#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote

/// The power-off flow the app runs against a real agent, in both of its
/// honest shapes: a guest that answers the ACPI request in its own time, and
/// one that has not answered when patience runs out — the outcome the
/// interface must present rather than spin on, per docs/AGENT-PROTOCOL.md.
final class VMPowerTests: XCTestCase {
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

    private func machine(vm identifier: String = "debian-13") -> Machine {
        Machine(
            name: "Debian 13",
            host: "adresse-perimee.local",
            port: 9999,
            proto: .vnc,
            agent: AgentBinding(
                baseURL: agent.baseURL,
                vmIdentifier: identifier,
                credentialRef: "agent.test"
            )
        )
    }

    private func client() -> AgentClient {
        AgentClient(baseURL: agent.baseURL, token: agent.token)
    }

    private func boot(_ identifier: String) async throws {
        _ = try await client().start(vm: identifier)
        _ = try await client().waitUntilRunning(
            vm: identifier, timeout: .seconds(5), pollInterval: .milliseconds(20)
        )
    }

    /// The normal ending: the guest receives ACPI, keeps running for a moment,
    /// and the poll follows it down to `stopped`.
    func testAGracefulShutdownFollowsTheGuestToStopped() async throws {
        try await boot("debian-13")

        let outcome = try await VMPower.shutDown(
            machine(),
            credentials: credentials,
            patience: .seconds(5),
            pollInterval: .milliseconds(20)
        )
        XCTAssertEqual(outcome, .stopped)

        let after = try await client().status(vm: "debian-13")
        XCTAssertEqual(after.state, .stopped)
        XCTAssertNil(after.consolePort, "une VM arrêtée n'a plus de console")
    }

    /// A guest can ignore ACPI forever, so patience running out is an answer,
    /// not an error — and the cord must still work afterwards.
    ///
    /// Zero patience makes the non-answer deterministic: the daemon's demo
    /// guest takes ~50 ms to comply, and the protocol guarantees the immediate
    /// reply to a polite stop still says `running`. A conduct that waited
    /// until `stopped` no matter what would return `.stopped` here (the demo
    /// guest does get there) and fail the first assertion.
    func testAnUnansweredRequestIsReportedAndTheCordStillWorks() async throws {
        try await boot("debian-13")

        let asked = try await VMPower.shutDown(
            machine(),
            credentials: credentials,
            patience: .zero
        )
        XCTAssertEqual(asked, .stillRunning, "l'invité n'a pas encore répondu : il faut le dire")

        let forced = try await VMPower.shutDown(
            machine(),
            credentials: credentials,
            force: true,
            patience: .seconds(5),
            pollInterval: .milliseconds(20)
        )
        XCTAssertEqual(forced, .stopped)
        let after = try await client().status(vm: "debian-13")
        XCTAssertEqual(after.state, .stopped)
    }

    /// The cord alone: `force: true` answers `stopped` at once, no poll needed.
    func testForceCutsThePowerWithoutWaitingOnTheGuest() async throws {
        try await boot("win11")

        let outcome = try await VMPower.shutDown(
            machine(vm: "win11"),
            credentials: credentials,
            force: true,
            patience: .zero
        )
        XCTAssertEqual(outcome, .stopped, "le cordon n'attend pas l'invité")
    }

    /// Asking a machine that is already off is answered on the spot — with
    /// zero patience, only the immediate reply can produce this `.stopped`.
    func testAnAlreadyStoppedGuestAnswersStoppedImmediately() async throws {
        let outcome = try await VMPower.shutDown(
            machine(),
            credentials: credentials,
            patience: .zero
        )
        XCTAssertEqual(outcome, .stopped)
    }

    /// A machine without a binding has no agent to ask: refused with the
    /// machine's name, never sent anywhere.
    func testAMachineWithoutABindingIsRefusedByName() async throws {
        let plain = Machine(name: "Poste direct", host: "10.0.0.5", port: 5900)
        do {
            _ = try await VMPower.shutDown(plain, credentials: credentials)
            XCTFail("une machine sans agent ne peut pas être éteinte à distance")
        } catch let error as WisqError {
            guard case .agentFailure(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("Poste direct"), "le message doit nommer la machine : \(message)")
        }
    }

    /// The token travels from the credential store through the shared client
    /// factory; a wrong one surfaces the agent's refusal instead of a hang.
    func testAWrongTokenSurfacesTheAgentError() async throws {
        try credentials.setSecret("mauvais-jeton", for: "agent.test")
        do {
            _ = try await VMPower.shutDown(machine(), credentials: credentials)
            XCTFail("un jeton invalide doit faire échouer l'arrêt")
        } catch let error as WisqError {
            guard case .agentFailure = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
    }
}
#endif
