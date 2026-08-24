#if os(iOS)
import Foundation
import Observation
import WisqVM

/// Drives one local Linux VM: owns the machine, runs it on its own thread, and
/// mirrors the console into observable state for the terminal view.
@Observable
@MainActor
public final class LocalVMModel {
    public enum Status: Equatable {
        case idle
        case running
        case finished(String)

        public var isRunning: Bool { self == .running }
    }

    public private(set) var status: Status = .idle
    /// Console text, ANSI-stripped and line-edited, bounded in lines.
    public private(set) var consoleText = ""

    private var machine: LocalMachine?
    private let sink = ConsoleSink()
    /// Signalled when the emulation thread leaves `run()`. Suspending has to
    /// wait for that: `snapshot()` reads the machine's state, and reading it
    /// while the interpreter is writing it would save something that never
    /// existed.
    private var runFinished: DispatchSemaphore?
    /// What becomes of the saved machine on each event, decided by a type that
    /// builds on Linux and is therefore covered by tests — this wiring is not.
    private var life = MachineLifecycle()
    private var kernelName = ""
    /// Which run a thread's completion belongs to. Suspending releases the
    /// machine while its thread is still unwinding, so a completion can arrive
    /// after the next machine has already booted; without this it would report
    /// the old machine's exit over the new one and delete its saved state.
    private var run = 0

    public init() {}

    /// Whether leaving and coming back would resume rather than restart.
    public var willResume: Bool { SuspendedMachine.exists(kernel: kernelName) }

    /// Whether returning to the foreground should pick the machine back up.
    /// The view asks, because iOS can take the app away and give it back
    /// without the screen ever disappearing.
    public var shouldResumeOnReturn: Bool { life.shouldResumeOnReturn }

    public func boot(kernelURL: URL) {
        guard machine == nil else { return }
        kernelName = kernelURL.lastPathComponent
        // Coming back from a suspension keeps the console: this is the same
        // model instance the user was looking at a moment ago, so its grid
        // still holds their session. Clearing it would make a resumption look
        // like a reboot — the one thing the whole feature exists to avoid.
        let resuming = life.shouldResumeOnReturn
        life.booted()
        status = .running
        if !resuming {
            consoleText = ""
            sink.reset()
        }

        // One refresh in flight at a time. The guest writes on its own thread
        // and can produce console faster than the main actor can render it; a
        // hop per chunk would queue work without bound and the interface would
        // fall behind the machine it is meant to be showing.
        let machine = LocalMachine { [sink] chunk in
            guard sink.append(chunk) else { return }
            Task { @MainActor [weak self] in
                self?.consoleText = sink.takeText()
            }
        }
        self.machine = machine

        // The emulator owns a whole thread for its lifetime: it is a CPU, not a
        // callback. The quality of service is explicit because the default lets
        // the scheduler park it on an efficiency core, where an interpreter
        // runs several times slower — and this is the thread whose speed the
        // user is watching.
        let finished = DispatchSemaphore(value: 0)
        runFinished = finished
        run += 1
        let thisRun = run
        let saved = SuspendedMachine.load(kernel: kernelURL.lastPathComponent)

        let thread = Thread { [weak self] in
            defer { finished.signal() }
            let outcome: LocalMachine.Outcome
            do {
                // A saved machine is resumed in place of booting. If the file
                // is not a snapshot — an older format, a truncated write — the
                // restore throws and the kernel is booted instead, which is the
                // only useful answer and better than refusing to start.
                if let saved, (try? machine.restore(saved)) != nil {
                    // nothing else to do: the guest is already mid-life
                } else {
                    let image = try Data(contentsOf: kernelURL)
                    try machine.load(kernelImage: image)
                }
                outcome = machine.run()
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, thisRun == self.run else { return }
                    self.finish(with: "Démarrage impossible : \(error.localizedDescription)")
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, thisRun == self.run else { return }
                // The interpreter also returns when we asked it to — suspending
                // stops it on purpose — so the lifecycle decides whether this
                // exit is the machine's own, and only then is it reported.
                let reports = self.life.reportsGuestExit
                if self.life.guestFinished() == .forget {
                    SuspendedMachine.clear(kernel: self.kernelName)
                }
                guard reports else { return }
                switch outcome {
                case .powerOff: self.finish(with: "La machine s'est éteinte.")
                case .reboot: self.finish(with: "La machine a redémarré ; relancez-la.")
                case .stopped: self.finish(with: "Arrêtée.")
                }
            }
        }
        thread.name = "app.wisq.vm"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func send(_ text: String) {
        machine?.send(Data(text.utf8))
    }

    public func sendLine(_ line: String) {
        send(line + "\n")
    }

    /// Ends the machine for good, at the user's request. The saved state goes
    /// too: "Arrêter" has to mean stopped, not hidden.
    public func stop() {
        if life.userStopped() == .forget {
            SuspendedMachine.clear(kernel: kernelName)
        }
        machine?.stop()
    }

    /// Saves the machine and lets it go, so the next visit resumes it.
    ///
    /// Deliberately synchronous. It runs when iOS is taking the app away or the
    /// screen is going, and both of those are moments where returning before
    /// the file is written means not writing it at all. The wait is bounded:
    /// `stop()` takes effect within one 1024-instruction slice, and the write
    /// is a few megabytes. Given the choice between a brief hitch and a machine
    /// that silently fails to save, the hitch is the right one.
    public func suspend() {
        guard let machine, let finished = runFinished else { return }
        guard life.steppedAway() == .save else { return }
        machine.stop()
        // If the interpreter has not come back in time, saving would read state
        // it is still writing. Better to lose the session than to save a
        // machine that never existed.
        guard finished.wait(timeout: .now() + 5) == .success else {
            if life.couldNotSave() == .forget { SuspendedMachine.clear(kernel: kernelName) }
            return
        }
        do {
            try SuspendedMachine.save(machine.snapshot(), kernel: kernelName)
        } catch {
            if life.couldNotSave() == .forget { SuspendedMachine.clear(kernel: kernelName) }
        }
        self.machine = nil
        runFinished = nil
        status = .idle
    }

    private func finish(with message: String) {
        machine = nil
        runFinished = nil
        status = .finished(message)
        _ = sink.append(Data("\n[\(message)]\n".utf8))
        consoleText = sink.takeText()
    }
}

/// Carries console bytes from the emulation thread to the main actor.
///
/// Two jobs, both about not letting a fast guest overwhelm a slow renderer:
/// it applies each chunk to the console once, incrementally, on the thread
/// that produced it; and it reports whether a refresh is already pending, so
/// the main actor is woken once per render rather than once per write.
private final class ConsoleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var console = TerminalGrid()
    private var refreshPending = false

    /// Buffers the chunk. Returns true only for the write that should schedule
    /// a refresh — every write until that refresh happens returns false.
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        console.append(data)
        if refreshPending { return false }
        refreshPending = true
        return true
    }

    func takeText() -> String {
        lock.lock()
        defer { lock.unlock() }
        refreshPending = false
        return console.text
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        console.removeAll()
        refreshPending = false
    }
}

/// Where imported kernel images live, and what is in there.
public enum KernelLibrary {
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Wisq/kernels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func list() -> [URL] {
        guard let directory = try? directory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies a picked file into the library, keeping its name.
    public static func importKernel(from source: URL) throws -> URL {
        let destination = try directory().appendingPathComponent(source.lastPathComponent)
        _ = source.startAccessingSecurityScopedResource()
        defer { source.stopAccessingSecurityScopedResource() }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    public static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
