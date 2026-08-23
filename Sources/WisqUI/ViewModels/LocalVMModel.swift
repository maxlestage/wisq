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
    /// Console text, ANSI-stripped and line-edited, capped so a chatty guest
    /// cannot grow it without bound.
    public private(set) var consoleText = ""

    private var machine: LinuxMachine?
    private var rawConsole = ""
    private static let consoleCap = 200_000

    public init() {}

    public func boot(kernelURL: URL) {
        guard machine == nil else { return }
        status = .running
        consoleText = ""
        rawConsole = ""

        let machine = LinuxMachine { [weak self] chunk in
            let text = String(decoding: chunk, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendConsole(text)
            }
        }
        self.machine = machine

        // The emulator owns a whole thread for its lifetime: it is a CPU, not a
        // callback. Detached so the UI never inherits its priority.
        Thread.detachNewThread { [weak self] in
            let outcome: LinuxMachine.Outcome
            do {
                let image = try Data(contentsOf: kernelURL)
                try machine.load(kernelImage: image)
                outcome = machine.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.finish(with: "Démarrage impossible : \(error.localizedDescription)")
                }
                return
            }
            Task { @MainActor [weak self] in
                switch outcome {
                case .powerOff: self?.finish(with: "La machine s'est éteinte.")
                case .reboot: self?.finish(with: "La machine a redémarré ; relancez-la.")
                case .stopped: self?.finish(with: "Arrêtée.")
                }
            }
        }
    }

    public func send(_ text: String) {
        machine?.send(Data(text.utf8))
    }

    public func sendLine(_ line: String) {
        send(line + "\n")
    }

    public func stop() {
        machine?.stop()
    }

    private func appendConsole(_ text: String) {
        rawConsole += ANSIFilter.strip(text)
        if rawConsole.count > Self.consoleCap {
            rawConsole = String(rawConsole.suffix(Self.consoleCap / 2))
        }
        consoleText = ANSIFilter.applyLineEdits(rawConsole)
    }

    private func finish(with message: String) {
        machine = nil
        status = .finished(message)
        appendConsole("\n[\(message)]\n")
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
