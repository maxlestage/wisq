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
    /// Entries the file holds that this build cannot decode, kept verbatim so
    /// that saving does not delete them.
    private var preserved: [JSONValue] = []

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

    /// What a load found, including what it could not read.
    ///
    /// The count is not decoration. Dropping an entry is a loss too, and a loss
    /// nobody is told about is worse than a refusal: the number is what lets
    /// the list say "une machine sur douze n'a pas pu être lue" instead of
    /// quietly showing eleven.
    public struct LoadOutcome: Equatable, Sendable {
        public var machines: [Machine]
        /// How many entries the file held that this build could not decode.
        public var unreadable: Int

        public init(machines: [Machine], unreadable: Int = 0) {
            self.machines = machines
            self.unreadable = unreadable
        }
    }

    public func load() throws -> [Machine] {
        try queue.sync { try loadOnQueue().machines }
    }

    /// The same load, with the count of entries it had to leave behind.
    public func loadReportingUnreadable() throws -> LoadOutcome {
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
            var machines = try loadOnQueue().machines
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
            var machines = try loadOnQueue().machines
            machines.removeAll { $0.id == id }
            try saveOnQueue(machines)
            return machines
        }
    }

    /// Callers must already be on `queue`.
    ///
    /// Decoded **one entry at a time**. It used to be `decode([Machine].self)`
    /// in a single call, which meant one unreadable entry did not cost the
    /// entry, or even the machine — it cost the whole library, with no way to
    /// repair it from inside an app that cannot reach its own container.
    ///
    /// What cannot be decoded is not discarded either: it is kept verbatim in
    /// `unreadable` and written back out by `saveOnQueue`. Otherwise the fix
    /// would introduce a worse bug than the one it closes — an older build
    /// reading a newer file, dropping the entries it does not understand, and
    /// deleting them the first time anything is saved.
    private func loadOnQueue() throws -> LoadOutcome {
        if let cache { return LoadOutcome(machines: cache, unreadable: preserved.count) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            preserved = []
            return LoadOutcome(machines: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try Self.decoder.decode([JSONValue].self, from: data)
            var machines: [Machine] = []
            var kept: [JSONValue] = []
            for entry in entries {
                let raw = try Self.encoder.encode(entry)
                if let machine = try? Self.decoder.decode(Machine.self, from: raw) {
                    machines.append(machine)
                } else {
                    kept.append(entry)
                }
            }
            cache = machines
            preserved = kept
            return LoadOutcome(machines: machines, unreadable: kept.count)
        } catch {
            throw WisqError.storageFailure(error.localizedDescription)
        }
    }

    /// Callers must already be on `queue`.
    ///
    /// Entries this build could not read are written back out alongside the
    /// ones it could. They go last, which is a choice about nothing — the list
    /// is sorted for display anyway — and the point is only that they are still
    /// there for the build that understands them.
    private func saveOnQueue(_ machines: [Machine]) throws {
        do {
            var entries = try Self.decoder.decode(
                [JSONValue].self, from: try Self.encoder.encode(machines))
            entries.append(contentsOf: preserved)
            let data = try Self.encoder.encode(entries)
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
