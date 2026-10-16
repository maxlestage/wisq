import Foundation

/// Une machine installée, emportée hors du téléphone — et ramenée.
///
/// **Ce que le fichier porte.** Le nom, l'image que la machine démarre, sa
/// mémoire, le disque qu'on lui a choisi, ses sessions suspendues et ses
/// couches d'écriture : tout ce qui fait qu'elle est *cette* machine-là et pas
/// une installation fraîche. Rapporté sur un autre téléphone, elle reprend où
/// elle en était.
///
/// **Ce qu'il ne porte pas : l'image.** Un ISO pèse des gibioctets, il est déjà
/// dans la bibliothèque de qui en a besoin, et il ne change jamais. L'import le
/// demande par son nom, et refuse en le nommant s'il n'est pas là — plutôt que
/// de créer une machine qui ne démarrerait pas. Un disque vierge créé pour la
/// machine n'est pas porté non plus : ce n'est qu'une taille, et l'import en
/// recrée un.
///
/// **Le format**, simple exprès : une marque, la longueur du manifeste, le
/// manifeste en JSON, puis les fichiers bout à bout, dans l'ordre et aux
/// longueurs que le manifeste annonce. Rien n'est compressé — les couches sont
/// déjà tassées, et les sessions déjà repliées.
public enum MachineArchive {
    /// L'extension qu'on donne au fichier, et que l'import reconnaît.
    public static let fileExtension = "wisqmachine"

    static let magic = Array("WISQMACH".utf8) + [UInt8(1)]

    /// Pourquoi une archive n'a pas été lue ou écrite.
    public enum Refusal: Error, Equatable, LocalizedError {
        case notAnArchive
        case damaged
        /// L'image que la machine démarre n'est pas dans la bibliothèque.
        case missingImage(String)
        /// Un nom de fichier qui sortirait de son dossier : refusé, jamais écrit.
        case unsafeName(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "Ce fichier n'est pas une machine exportée par wisq."
            case .damaged:
                return "Cette machine exportée est incomplète ou abîmée ; rien n'a été importé."
            case .missingImage(let image):
                return """
                    Cette machine démarre \(image), qui n'est pas dans la \
                    bibliothèque. Importez d'abord ce fichier, puis la machine.
                    """
            case .unsafeName(let name):
                return "Cette machine exportée contient un nom de fichier refusé : \(name)."
            }
        }
    }

    struct Manifest: Codable, Equatable {
        var version = 1
        var name: String
        var image: String
        var memory: UInt64?
        var disk: String?
        /// La taille du disque vierge propre à la machine, s'il y en avait un.
        var ownDiskBytes: UInt64?
        var files: [Entry]

        struct Entry: Codable, Equatable {
            enum Kind: String, Codable { case session, writes, map }
            var kind: Kind
            /// Pour une session, l'empreinte de son noyau ; pour une couche ou
            /// sa carte, le nom du disque qu'elle recouvre.
            var name: String
            var length: UInt64
        }
    }

    /// Les octets lus et écrits d'un coup : assez gros pour aller vite, assez
    /// petit pour qu'une couche de plusieurs gibioctets ne passe jamais toute en
    /// mémoire.
    static let chunk = 1 << 20

    // MARK: - Exporter

    /// Écrit la machine dans `destination`.
    ///
    /// `kernels` est le dossier de la bibliothèque : il sert à mesurer le disque
    /// vierge propre à la machine, qu'on ne copie pas.
    public static func export(
        _ machine: InstalledMachine, kernels: URL, in directory: URL? = nil, to destination: URL
    ) throws {
        let folder = try directory ?? SuspendedMachine.directory()
        let writes = try LocalDisk.writesDirectory(in: directory)
        var entries: [Manifest.Entry] = []
        var sources: [URL] = []

        let prefix = "machine-\(SuspendedMachine.safeName(machine.key))-"
        for file in SuspendedMachine.savedMachineFiles(named: machine.key, in: directory) {
            let url = folder.appendingPathComponent(file)
            let digest = String(file.dropFirst(prefix.count).dropLast(".wisqvm".count))
            entries.append(.init(kind: .session, name: digest, length: try size(of: url)))
            sources.append(url)
        }
        let overlayPrefix = machine.keys.overlayPrefix
        let layers = try FileManager.default.contentsOfDirectory(atPath: writes.path)
            .filter { $0.hasPrefix(overlayPrefix) && $0.hasSuffix(".writes") }
            .sorted()
        for layer in layers {
            let disk = String(layer.dropFirst(overlayPrefix.count).dropLast(".writes".count))
            let url = writes.appendingPathComponent(layer)
            entries.append(.init(kind: .writes, name: disk, length: try size(of: url)))
            sources.append(url)
            let map = URL(fileURLWithPath: url.path + ".map")
            if FileManager.default.fileExists(atPath: map.path) {
                entries.append(.init(kind: .map, name: disk, length: try size(of: map)))
                sources.append(map)
            }
        }

        let ownDiskBytes = machine.ownDisk.flatMap {
            try? size(of: kernels.appendingPathComponent($0))
        }
        let memory = KernelMemory.size(forKernel: machine.key, in: directory, ceiling: .max)
        let manifest = Manifest(
            name: machine.name, image: machine.image,
            memory: memory == KernelMemory.defaultSize ? nil : memory,
            disk: LocalDisk.recordedName(forKernel: machine.key, in: directory),
            ownDiskBytes: ownDiskBytes, files: entries)

        let encoded = try JSONEncoder().encode(manifest)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: Data(magic))
        try output.write(contentsOf: withUnsafeBytes(of: UInt64(encoded.count).littleEndian) { Data($0) })
        try output.write(contentsOf: encoded)
        for (entry, source) in zip(entries, sources) {
            try copy(from: source, count: entry.length, into: output)
        }
    }

    // MARK: - Importer

    /// Ce fichier est-il une machine exportée ? Lit la marque, rien de plus —
    /// c'est ce qui permet au bouton « Importer » de la bibliothèque de
    /// reconnaître seul ce qu'on lui donne.
    public static func isArchive(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)).map { [UInt8]($0) == magic } ?? false
    }

    /// Lit une machine exportée et l'installe ici, sous une clé neuve.
    ///
    /// **Tout ou rien.** Le manifeste est lu et vérifié en entier avant que quoi
    /// que ce soit soit écrit ; une archive tronquée en cours de route retire la
    /// machine à moitié faite, et ce qu'elle avait reçu.
    ///
    /// `createOwnDisk` crée un disque vierge de la taille donnée dans la
    /// bibliothèque et rend son nom — c'est l'appelant qui connaît la
    /// bibliothèque, et les tests y passent un dossier à eux.
    @discardableResult
    public static func `import`(
        from source: URL, library: [String], in directory: URL? = nil,
        now: Date = Date(), id: String = InstalledMachines.newIdentifier(),
        createOwnDisk: (String, UInt64) throws -> String
    ) throws -> InstalledMachine {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let mark = try input.read(upToCount: magic.count), [UInt8](mark) == magic else {
            throw Refusal.notAnArchive
        }
        guard let lengthBytes = try input.read(upToCount: 8), lengthBytes.count == 8 else {
            throw Refusal.damaged
        }
        let length = lengthBytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length <= 1 << 20, let body = try input.read(upToCount: Int(length)),
              body.count == Int(length),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: body),
              manifest.version == 1
        else { throw Refusal.damaged }

        for name in [manifest.image] + manifest.files.map(\.name) + [manifest.disk].compactMap({ $0 })
        where !isSafe(name) {
            throw Refusal.unsafeName(name)
        }
        guard library.contains(manifest.image) else { throw Refusal.missingImage(manifest.image) }
        // La taille annoncée doit être celle du fichier : une archive tronquée est
        // refusée ici, avant d'avoir rien créé.
        let announced = manifest.files.reduce(UInt64(magic.count) + 8 + length) { $0 + $1.length }
        guard announced == (try size(of: source)) else { throw Refusal.damaged }

        var machine = try InstalledMachines.install(
            image: manifest.image, name: manifest.name, in: directory, now: now, id: id)
        do {
            if let memory = manifest.memory {
                KernelMemory.setSize(memory, forKernel: machine.key, in: directory)
            }
            var disk = manifest.disk
            if let bytes = manifest.ownDiskBytes {
                let created = try createOwnDisk(machine.name, bytes)
                try InstalledMachines.setOwnDisk(created, id: machine.id, in: directory)
                machine.ownDisk = created
                disk = created
            }
            if let disk { LocalDisk.attach(disk, forKernel: machine.key, in: directory) }

            let folder = try directory ?? SuspendedMachine.directory()
            for entry in manifest.files {
                let target: URL
                switch entry.kind {
                case .session:
                    target = folder.appendingPathComponent(
                        "machine-\(SuspendedMachine.safeName(machine.key))-\(entry.name).wisqvm")
                case .writes, .map:
                    // Le disque propre a changé de nom : sa couche suit.
                    let diskName = entry.name == manifest.disk ? (disk ?? entry.name) : entry.name
                    let base = try LocalDisk.writesURL(
                        for: machine.keys.overlay(forDisk: diskName), in: directory)
                    target = entry.kind == .map ? URL(fileURLWithPath: base.path + ".map") : base
                }
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                    throw Refusal.damaged
                }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                try copy(from: input, count: entry.length, into: output)
            }
        } catch {
            _ = try? InstalledMachines.remove(id: machine.id, in: directory)
            throw error is Refusal ? error : Refusal.damaged
        }
        return machine
    }

    // MARK: - Outils

    /// Un nom qui reste dans son dossier : ni séparateur, ni `..`, ni vide.
    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func copy(from source: URL, count: UInt64, into output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try copy(from: input, count: count, into: output)
    }

    /// Recopie exactement `count` octets, par morceaux. Moins que ça est une
    /// archive tronquée — ou un fichier qui a changé sous nos pieds.
    private static func copy(from input: FileHandle, count: UInt64, into output: FileHandle) throws {
        var left = count
        while left > 0 {
            let wanted = Int(min(left, UInt64(chunk)))
            guard let data = try input.read(upToCount: wanted), data.count == wanted else {
                throw Refusal.damaged
            }
            try output.write(contentsOf: data)
            left -= UInt64(wanted)
        }
    }
}
