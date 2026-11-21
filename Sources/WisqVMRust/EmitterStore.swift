import Foundation

/// **Le magasin de la page de la machine de l'émetteur** : ce que la page va
/// chercher, et ce qu'elle reçoit.
///
/// Dans l'application, un `WKURLSchemeHandler` sur `wisq-machine://` lui
/// passe chaque requête (`EmitterDesktop`) ; sous Linux, un test le branche
/// derrière le `fetch` d'un Bun (`EmitterMachineTests`). Les deux appellent la
/// même fonction, `respond`, et c'est ce qui rend le contrat jugeable sans
/// iPhone : la page, la boucle hôte, la carte et ce magasin, de bout en bout.
///
/// Trois sortes de choses, sous un nom chacune :
///
/// - **les fichiers de la page** — `machine.html`, les scripts, le module —
///   et le **plan** (`plan.json`), en octets ;
/// - **les morceaux à poser dans la RAM** — les segments du noyau, l'archive,
///   la page zéro —, lus dans leurs fichiers à la demande : un noyau de
///   cinquante mégaoctets et une archive de cent cinquante n'ont pas à vivre
///   en mémoire à côté de la RAM de l'invité ;
/// - **le disque**, par plages, sur le contrat d'`arriereParUrl`
///   (`web/carte.js`) : `GET disque?a=…&n=…` rend `n` octets à partir de `a`,
///   `PUT disque?a=…` écrit le corps à `a`. Le fichier n'est **jamais
///   écrit** : ce que l'invité écrit va dans une couche en mémoire, secteur
///   par secteur, et une lecture la voit — comme sous `kernel-entry`.
///
/// **Les réponses d'erreur sont nommées**, parce que la page les relaie telles
/// quelles : 404 pour un nom inconnu, 400 pour une plage illisible, 416 pour
/// une plage hors du disque, 405 pour une méthode qui n'a pas de sens ici, 500
/// pour un fichier qui ne se lit plus.
public final class EmitterStore: @unchecked Sendable {
    /// D'où viennent les octets d'un nom.
    public enum Source: Equatable, Sendable {
        case bytes(Data)
        /// `length` octets à partir de `offset` dans le fichier.
        case file(URL, offset: UInt64, length: UInt64)

        public var length: UInt64 {
            switch self {
            case .bytes(let data): return UInt64(data.count)
            case .file(_, _, let length): return length
            }
        }
    }

    public struct Response: Equatable, Sendable {
        public let status: Int
        public let contentType: String
        public let body: Data

        static func refusal(_ status: Int, _ why: String) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(why.utf8))
        }
    }

    /// La taille d'un secteur, celle de la couche.
    public static let sector = 512
    /// **La plus grande plage servie d'un coup** : ce que la carte confie au
    /// plus à son arrière (64 Mio). Au-delà, c'est une page qui a divergé.
    public static let largestRange: UInt64 = 64 << 20

    private let files: [String: Source]
    private let disk: (url: URL, bytes: UInt64)?
    private let lock = NSLock()
    /// La couche d'écriture : un secteur par entrée.
    private var layer: [UInt64: Data] = [:]
    /// Ce que le disque a servi, pour qu'un test et l'écran le disent.
    public private(set) var reads = 0
    public private(set) var bytesRead: UInt64 = 0
    public private(set) var writes = 0

    /// Le nom sous lequel le disque est servi.
    public static let diskName = "disque"

    public init(files: [String: Source], disk: (url: URL, bytes: UInt64)? = nil) {
        self.files = files
        self.disk = disk
    }

    /// Combien de secteurs la couche tient.
    public var layeredSectors: Int {
        lock.lock()
        defer { lock.unlock() }
        return layer.count
    }

    /// **Répondre à une requête de la page.** `url` est l'URL entière ; seul
    /// son chemin (sans la barre du début) et sa requête comptent.
    public func respond(method: String, url: URL, body: Data? = nil) -> Response {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var name = parts?.path ?? url.path
        while name.hasPrefix("/") { name.removeFirst() }
        if name.isEmpty { name = "machine.html" }
        let query = Dictionary(
            (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        if name == Self.diskName, disk != nil {
            switch method {
            case "GET": return readDisk(query)
            case "PUT": return writeDisk(query, body ?? Data())
            default: return .refusal(405, "\(method) n'a pas de sens pour le disque")
            }
        }
        guard method == "GET" else { return .refusal(405, "\(method) n'a pas de sens pour \(name)") }
        guard let source = files[name] else { return .refusal(404, "\(name) n'est pas dans ce magasin") }
        do {
            return Response(status: 200, contentType: Self.type(of: name), body: try Self.read(source))
        } catch {
            return .refusal(500, "\(name) ne se lit plus : \(error)")
        }
    }

    static func type(of name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }

    static func read(_ source: Source) throws -> Data {
        switch source {
        case .bytes(let data): return data
        case .file(let url, let offset, let length):
            return try read(url, at: offset, count: Int(length))
        }
    }

    /// `count` octets à `offset`, ou une erreur : un fichier plus court que
    /// promis ne rend pas moins, il refuse.
    static func read(_ url: URL, at offset: UInt64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(data.count) octets à \(offset) pour \(count)",
            ])
        }
        return data
    }

    /// Une plage lisible du disque, ou la réponse qui la refuse.
    private enum Plage {
        case lisible(UInt64, UInt64)
        case refusee(Response)
    }

    private func range(_ query: [String: String], needsLength: Bool) -> Plage {
        guard let disk else { return .refusee(.refusal(404, "pas de disque")) }
        guard let text = query["a"], let at = UInt64(text) else {
            return .refusee(.refusal(400, "la plage n'a pas de début lisible"))
        }
        var length: UInt64 = 0
        if needsLength {
            guard let text = query["n"], let count = UInt64(text), count > 0 else {
                return .refusee(.refusal(400, "la plage n'a pas de longueur lisible"))
            }
            guard count <= Self.largestRange else {
                return .refusee(.refusal(400, "\(count) octets d'un coup, au-delà de \(Self.largestRange)"))
            }
            length = count
        }
        // Écrit en soustrayant : `at + length` déborderait pour un `at`
        // proche du maximum, et Swift piégerait au lieu de refuser.
        guard at <= disk.bytes, length <= disk.bytes - at else {
            return .refusee(.refusal(416, "la plage sort du disque de \(disk.bytes) octets"))
        }
        return .lisible(at, length)
    }

    private func readDisk(_ query: [String: String]) -> Response {
        guard let disk else { return .refusal(404, "pas de disque") }
        let at: UInt64
        let count: UInt64
        switch range(query, needsLength: true) {
        case .refusee(let refusal): return refusal
        case .lisible(let debut, let longueur): (at, count) = (debut, longueur)
        }
        var data: Data
        do {
            data = try Self.read(disk.url, at: at, count: Int(count))
        } catch {
            return .refusal(500, "le disque ne se lit plus : \(error)")
        }
        lock.lock()
        defer { lock.unlock() }
        if !layer.isEmpty {
            for (sector, from, to) in Self.sectors(at: at, count: count) {
                guard let written = layer[sector] else { continue }
                let base = sector * UInt64(Self.sector)
                data.replaceSubrange(
                    Int(from - at)..<Int(to - at),
                    with: written[Int(from - base)..<Int(to - base)])
            }
        }
        reads += 1
        bytesRead += count
        return Response(status: 200, contentType: "application/octet-stream", body: data)
    }

    private func writeDisk(_ query: [String: String], _ body: Data) -> Response {
        guard let disk else { return .refusal(404, "pas de disque") }
        guard !body.isEmpty else { return .refusal(400, "une écriture sans octets") }
        let at: UInt64
        switch range(query, needsLength: false) {
        case .refusee(let refusal): return refusal
        case .lisible(let debut, _): at = debut
        }
        let count = UInt64(body.count)
        guard count <= Self.largestRange, count <= disk.bytes - at else {
            return .refusal(416, "l'écriture sort du disque de \(disk.bytes) octets")
        }
        let bytes = Data(body)
        lock.lock()
        defer { lock.unlock() }
        for (sector, from, to) in Self.sectors(at: at, count: count) {
            let base = sector * UInt64(Self.sector)
            var current: Data
            if let written = layer[sector] {
                current = written
            } else {
                // Le secteur d'origine d'abord : une écriture qui n'en couvre
                // qu'une partie garde le reste.
                let length = Int(min(UInt64(Self.sector), disk.bytes - base))
                do {
                    current = try Self.read(disk.url, at: base, count: length)
                } catch {
                    return .refusal(500, "le disque ne se lit plus : \(error)")
                }
            }
            current.replaceSubrange(
                Int(from - base)..<Int(to - base),
                with: bytes[Int(from - at)..<Int(to - at)])
            layer[sector] = current
        }
        writes += 1
        return Response(status: 200, contentType: "text/plain; charset=utf-8", body: Data())
    }

    /// Les secteurs qu'une plage touche : le numéro, puis le début et la fin
    /// de ce qu'elle en couvre, en octets du disque.
    static func sectors(at: UInt64, count: UInt64) -> [(UInt64, UInt64, UInt64)] {
        let size = UInt64(sector)
        var touched: [(UInt64, UInt64, UInt64)] = []
        var position = at
        let end = at + count
        while position < end {
            let number = position / size
            let next = min(end, (number + 1) * size)
            touched.append((number, position, next))
            position = next
        }
        return touched
    }
}
