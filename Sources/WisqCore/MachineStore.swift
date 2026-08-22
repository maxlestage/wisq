import Foundation

/// Persistence for the machine list. JSON in the app container, written atomically
/// so a crash mid-save cannot leave a truncated library behind.
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
        try queue.sync {
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
    }

    public func save(_ machines: [Machine]) throws {
        try queue.sync {
            do {
                let data = try Self.encoder.encode(machines)
                try data.write(to: fileURL, options: .atomic)
                cache = machines
            } catch {
                throw WisqError.storageFailure(error.localizedDescription)
            }
        }
    }

    public func upsert(_ machine: Machine) throws -> [Machine] {
        var machines = try load()
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
        try save(machines)
        return machines
    }

    public func delete(id: Machine.ID) throws -> [Machine] {
        var machines = try load()
        machines.removeAll { $0.id == id }
        try save(machines)
        return machines
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
