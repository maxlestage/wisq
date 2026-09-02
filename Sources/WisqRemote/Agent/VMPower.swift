import Foundation
import WisqCore

/// Powers a remote VM off through its host agent — the other half of what
/// `ConsoleResolver` does at connect time.
///
/// The shape comes from the protocol (docs/AGENT-PROTOCOL.md): `stop` answers
/// immediately with the state observable at that instant, and the two values
/// of `force` do not lead to the same place. `force: true` is the power cord —
/// the next read says `stopped`. `force: false` is the button: ACPI is
/// delivered and the guest is still running, console open, until it decides
/// otherwise — which can take a minute, and can be never, because a guest
/// without an ACPI handler ignores the request and nothing in the protocol can
/// force it. So a client polls to `stopped`, and running out of patience is
/// not a transport failure: it is an answer the interface has to present,
/// together with the cord. Waiting longer here would not make the guest
/// answer; it would only hide the question from the person holding the phone.
public enum VMPower {
    public enum ShutdownOutcome: Equatable, Sendable {
        /// The agent reported `stopped` within the patience window.
        case stopped
        /// The request was delivered and the guest had not complied when
        /// patience ran out. The caller decides whether to cut the power.
        case stillRunning
    }

    public static func shutDown(
        _ machine: Machine,
        credentials: CredentialStore,
        force: Bool = false,
        patience: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2)
    ) async throws -> ShutdownOutcome {
        guard let binding = machine.agent else {
            throw WisqError.agentFailure(
                "la machine « \(machine.name) » n'est liée à aucun agent hôte"
            )
        }
        let client = try AgentClient(binding: binding, credentials: credentials)

        // The immediate answer settles two cases without a single poll: a
        // forced stop, and a guest that was already off — asking politely a
        // machine that is not running is answered `stopped` on the spot.
        let answered = try await client.stop(vm: binding.vmIdentifier, force: force)
        if answered.state == .stopped { return .stopped }

        let deadline = ContinuousClock.now.advanced(by: patience)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            if try await client.status(vm: binding.vmIdentifier).state == .stopped {
                return .stopped
            }
        }
        return .stillRunning
    }
}
