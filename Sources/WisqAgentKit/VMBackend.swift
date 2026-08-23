#if os(macOS) || os(Linux)
import Foundation
import WisqCore

/// What the agent knows how to do to VMs, whatever runs them underneath.
public protocol VMBackend: Sendable {
    func list() throws -> [AgentVM]
    func get(id: String) throws -> AgentVM?
    func start(id: String) throws -> AgentVM
    func stop(id: String, force: Bool) throws -> AgentVM
}

/// In-memory backend with realistic state transitions. Two uses: exercising the
/// full client–agent round trip in tests, and trying the app without libvirt —
/// `wisq-agent --demo` gives the phone something honest to talk to.
public final class DemoBackend: VMBackend, @unchecked Sendable {
    private struct Entry {
        var vm: AgentVM
        var runningPort: Int
    }

    private var entries: [String: Entry]
    private let lock = NSLock()
    /// How long a "boot" takes. Milliseconds in tests, seconds in the demo.
    private let startupDelay: TimeInterval

    public init(startupDelay: TimeInterval = 2.0) {
        self.startupDelay = startupDelay
        self.entries = [
            "debian-13": Entry(
                vm: AgentVM(id: "debian-13", name: "Debian 13", state: .stopped, guestOS: .linux),
                runningPort: 5901
            ),
            "win11": Entry(
                vm: AgentVM(id: "win11", name: "Windows 11", state: .stopped, guestOS: .windows),
                runningPort: 5902
            ),
        ]
    }

    public func list() throws -> [AgentVM] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.vm).sorted { $0.id < $1.id }
    }

    public func get(id: String) throws -> AgentVM? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]?.vm
    }

    public func start(id: String) throws -> AgentVM {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id] else { throw AgentError("VM introuvable : \(id)") }
        guard entry.vm.state != .running else { return entry.vm }

        entry.vm.state = .starting
        entry.vm.consolePort = nil
        entries[id] = entry

        // The boot completes on its own, the way a real guest would; the client
        // discovers it by polling, exactly as it will against libvirt.
        DispatchQueue.global().asyncAfter(deadline: .now() + startupDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard var entry = self.entries[id], entry.vm.state == .starting else { return }
            entry.vm.state = .running
            entry.vm.consoleProtocol = .vnc
            entry.vm.consolePort = entry.runningPort
            self.entries[id] = entry
        }
        return entry.vm
    }

    public func stop(id: String, force: Bool) throws -> AgentVM {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[id] else { throw AgentError("VM introuvable : \(id)") }
        entry.vm.state = .stopped
        entry.vm.consolePort = nil
        entry.vm.consoleProtocol = nil
        entries[id] = entry
        return entry.vm
    }
}

/// libvirt backend, driven through the `virsh` CLI rather than the C library:
/// no linking headache, and the daemon degrades gracefully to a clear error on
/// hosts without libvirt.
public struct VirshBackend: VMBackend {
    private let virshPath: String

    public init(virshPath: String = "/usr/bin/virsh") {
        self.virshPath = virshPath
    }

    public func list() throws -> [AgentVM] {
        let names = try run(["list", "--all", "--name"])
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        return try names.map { try describe(id: $0) }
    }

    public func get(id: String) throws -> AgentVM? {
        do {
            return try describe(id: id)
        } catch {
            return nil
        }
    }

    public func start(id: String) throws -> AgentVM {
        _ = try run(["start", id])
        return try describe(id: id)
    }

    public func stop(id: String, force: Bool) throws -> AgentVM {
        // ACPI shutdown by default; destroy is the power cord.
        _ = try run([force ? "destroy" : "shutdown", id])
        return try describe(id: id)
    }

    private func describe(id: String) throws -> AgentVM {
        let state = Self.parseDomstate(try run(["domstate", id]))
        var vm = AgentVM(id: id, name: id, state: state)
        if state == .running,
           let port = Self.parseVNCDisplay(try? run(["vncdisplay", id])) {
            vm.consoleProtocol = .vnc
            vm.consolePort = port
        }
        return vm
    }

    // MARK: - Parsing (pure, tested without libvirt)

    static func parseDomstate(_ output: String) -> AgentVM.State {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "running": return .running
        case "paused": return .paused
        case "shut off", "in shutdown", "crashed": return .stopped
        case "pmsuspended": return .paused
        default: return .unknown
        }
    }

    /// virsh prints VNC displays as `:N` or `host:N`; the port is 5900 + N.
    static func parseVNCDisplay(_ output: String?) -> Int? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":"),
              let display = Int(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return 5900 + display
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: virshPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw AgentError("virsh introuvable (\(virshPath)) : \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AgentError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
#endif
