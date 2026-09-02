import Foundation
import WisqCore

/// Turns a machine bound to a host agent into a machine ready to connect to.
///
/// This is the step that makes the promise real: tap a powered-off VM, it boots,
/// the console appears. Without an agent binding this is the identity function,
/// so the session path stays uniform.
public enum ConsoleResolver {
    public static func resolve(
        _ machine: Machine,
        credentials: CredentialStore,
        timeout: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2)
    ) async throws -> Machine {
        guard let binding = machine.agent else { return machine }

        let client = try AgentClient(binding: binding, credentials: credentials)

        var vm = try await client.status(vm: binding.vmIdentifier)
        if vm.state != .running || vm.consolePort == nil {
            guard binding.autoStart else {
                throw WisqError.agentFailure(
                    "la VM « \(vm.name) » est \(vm.state.displayName.lowercased()) et le démarrage automatique est désactivé"
                )
            }
            if vm.state != .running, vm.state != .starting {
                vm = try await client.start(vm: binding.vmIdentifier)
            }
            // Either just started or already booting: wait for the console either way.
            vm = try await client.waitUntilRunning(
                vm: binding.vmIdentifier, timeout: timeout, pollInterval: pollInterval
            )
        }

        var resolved = machine
        // The console is served by the machine the agent runs on — and the port
        // can move between boots, which is exactly why it is resolved late.
        if let host = binding.baseURL.host {
            resolved.host = host
        }
        if let port = vm.consolePort {
            resolved.port = port
        }
        if let proto = vm.consoleProtocol {
            resolved.proto = proto
        }
        return resolved
    }
}
