import Foundation

/// Persistence for the machine list. JSON in the app container, written atomically
/// so a crash mid-save cannot leave a truncated library behind.
///
/// `@unchecked Sendable` on the strength of the serial queue: every touch of
/// `cache`, and every read-modify-write of the file, happens on it. The second
/// half of that sentence is the part that had to be fixed — see `upsert`.
public final class MachineStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.wisq.machine-store")
    private var cache: [Machine]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: `Application Support/Wisq/machines.json`.
    public static func makeDefault(fileManager: FileManager = .default) throws -> MachineStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Wisq", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return MachineStore(fileURL: base.appendingPathComponent("machines.json"))
    }

    public func load() throws -> [Machine] {
        try queue.sync { try loadOnQueue() }
    }

    public func save(_ machines: [Machine]) throws {
        try queue.sync { try saveOnQueue(machines) }
    }

    /// Adds a machine, or replaces the one with the same identity.
    ///
    /// The read, the edit and the write happen in **one** trip through the
    /// queue. They used to be two — `load()` then `save()` — which is a lost
    /// update waiting for a second writer: both read the same list, both write
    /// their own version of it, and whichever finishes second erases the
    /// other's machine. Nothing crashes and nothing is logged; a machine the
    /// user just added is simply not there any more.
    ///
    /// Hence the `…OnQueue` pair below. `DispatchQueue.sync` inside
    /// `DispatchQueue.sync` on a serial queue deadlocks, so the composite
    /// operations cannot reach for the public `load` and `save`.
    public func upsert(_ machine: Machine) throws -> [Machine] {
        try queue.sync {
            var machines = try loadOnQueue()
            if let index = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[index] = machine
            } else {
                machines.append(machine)
            }
            try saveOnQueue(machines)
            return machines
        }
    }

    public func delete(id: Machine.ID) throws -> [Machine] {
        try queue.sync {
            var machines = try loadOnQueue()
            machines.removeAll { $0.id == id }
            try saveOnQueue(machines)
            return machines
        }
    }

    /// Callers must already be on `queue`.
    private func loadOnQueue() throws -> [Machine] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let machines = try Self.decoder.decode([Machine].self, from: data)
            cache = machines
            return machines
        } catch {
            throw WisqError.storageFailure(error.localizedDescription)
        }
    }

    /// Callers must already be on `queue`.
    private func saveOnQueue(_ machines: [Machine]) throws {
        do {
            let data = try Self.encoder.encode(machines)
            try data.write(to: fileURL, options: .atomic)
            cache = machines
        } catch {
            throw WisqError.storageFailure(error.localizedDescription)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
