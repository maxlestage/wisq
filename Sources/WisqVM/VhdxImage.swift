import Foundation

/// Un disque VHDX — celui d'Hyper-V depuis Windows Server 2012, et de Windows
/// 10 et 11 —, lu sur place, sans conversion.
///
/// **Le format**, relevé sur de vrais fichiers de `qemu-img` : la marque
/// `vhdxfile` en tête, puis **deux** en-têtes (64 Kio et 128 Kio) dont on
/// garde le plus récent de ceux dont la somme tient, et deux copies de la
/// table des régions (192 Kio et 256 Kio). La table donne deux régions : la
/// table des blocs (BAT) et les métadonnées, où se lisent la taille des blocs,
/// la taille du disque et celle de ses secteurs. Les sommes sont des CRC-32C,
/// calculées sur la structure entière, le champ de la somme compté à zéro.
/// Les nombres sont petit-boutistes ; les GUID, dans l'ordre de Windows.
///
/// **La table des blocs** a une entrée de 64 bits par bloc : l'état dans les
/// trois bits du bas, l'adresse du bloc dans le fichier, en mébioctets, à
/// partir du bit 20. Toutes les `chunkRatio` entrées s'intercale celle d'une
/// carte de secteurs, qui ne sert qu'aux disques différentiels : on la saute.
/// Un bloc absent, indéfini, mis à zéro ou démappé se lit en zéros.
///
/// **Ce qu'il refuse, en le nommant** : le disque différentiel, qui ne se lit
/// qu'avec son parent ; un journal qui n'a pas été rejoué — le fichier n'est
/// alors pas encore cohérent, et le lire tel quel rendrait des blocs d'avant
/// la dernière écriture ; une somme fausse dans les deux copies ; une région
/// ou une métadonnée obligatoire inconnue ; ce qui ne tient pas debout.
///
/// Lecture seule : les écritures de l'invité vont dans la couche de
/// `FileDiskStore`, et le fichier reste celui d'Hyper-V.
public final class VhdxImage: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notVhdx
        /// Un disque différentiel, qui ne se lit qu'avec son parent.
        case differencing
        /// Un journal à rejouer : Hyper-V n'a pas fermé le disque proprement.
        case pendingLog
        /// La somme des deux copies d'une structure.
        case badChecksum(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notVhdx: return "ce fichier n'est pas un VHDX."
            case .differencing:
                return "le VHDX est un disque différentiel, qui ne se lit qu'avec le disque dont il dépend."
            case .pendingLog:
                return "le journal du VHDX n'a pas été rejoué : le disque n'a pas été fermé proprement. "
                    + "L'ouvrir puis le fermer dans Hyper-V, ou `qemu-img check -r all`, le remet d'aplomb."
            case .badChecksum(let what): return "la somme de contrôle \(what) du VHDX est fausse, dans les deux copies."
            case .malformed(let what): return "le VHDX est mal formé : \(what)."
            }
        }
    }

    static let mark = Array("vhdxfile".utf8)

    /// Un GUID tel que Windows le range : les trois premiers champs
    /// petit-boutistes, les huit derniers octets dans l'ordre.
    static func guid(_ text: String) -> [UInt8] {
        let hex = Array(text.replacingOccurrences(of: "-", with: "").utf8)
        let bytes = stride(from: 0, to: 32, by: 2).map {
            UInt8(String(decoding: hex[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
        }
        return bytes[0..<4].reversed() + bytes[4..<6].reversed() + bytes[6..<8].reversed() + bytes[8...]
    }

    static let batRegion = guid("2dc27766-f623-4200-9d64-115e9bfd4a08")
    static let metadataRegion = guid("8b7ca206-4790-4b9a-b8fe-575f050f886e")
    static let fileParameters = guid("caa16737-fa36-4d43-b3b6-33f0aa44e76b")
    static let virtualDiskSize = guid("2fa54224-cd1b-4876-b211-5dbed83bf4b8")
    static let logicalSectorSize = guid("8141bf1d-a96f-4709-ba47-f233a8faab5f")
    /// Lues par Hyper-V, inutiles ici, mais connues : leur drapeau
    /// « obligatoire » ne doit pas faire refuser le disque.
    static let known = [
        guid("beca12ab-b2e6-4523-93ef-c309e000c746"),  // identifiant SCSI de la page 83
        guid("cda348c7-445d-4471-9cc9-e9885251c556"),  // taille du secteur physique
        guid("a8d35f2d-b30b-454d-abf7-d3d84834ab0c"),  // où trouver le parent
    ]

    public let virtualSize: UInt64
    public let blockSize: Int
    /// Le nombre de blocs de données entre deux entrées de carte de secteurs.
    private let chunkRatio: Int
    private let entries: [UInt64]
    private let fd: Int32
    private let fileSize: UInt64

    /// Le fichier commence-t-il comme un VHDX ?
    static func looksLikeOne(fd: Int32) -> Bool {
        var head = [UInt8](repeating: 0, count: 8)
        let got = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 8, 0) }
        return got == 8 && head == mark
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0x82F6_3B78 : value >> 1 }
        return value
    }

    /// Le CRC-32C (Castagnoli) de `bytes`, les quatre octets en `field`
    /// comptés à zéro.
    static func checksum(_ bytes: [UInt8], skipping field: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for (index, byte) in bytes.enumerated() {
            let value = (field..<(field + 4)).contains(index) ? 0 : byte
            crc = crcTable[Int((crc ^ UInt32(value)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    /// Ouvre `url` en lecture seule.
    public convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.malformed("le fichier n'a pas pu être ouvert") }
        do { try self.init(takingOwnershipOf: fd) } catch { close(fd); throw error }
    }

    /// Lit les en-têtes, la table des régions, les métadonnées et la table des
    /// blocs de `fd`, qui appartient ensuite à l'image.
    public init(takingOwnershipOf fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let fileSize = UInt64(max(info.st_size, 0))
        func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
            bytes[at..<(at + 2)].reversed().reduce(0) { $0 << 8 | UInt16($1) }
        }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            bytes[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
            bytes[at..<(at + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        func read(_ count: Int, at offset: UInt64) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            // Sans addition : un décalage proche de 2⁶⁴ passait `&+`, puis
            // faisait tomber `off_t(décalage)`.
            guard offset <= fileSize, UInt64(count) <= fileSize - offset,
                  VirtualDiskImages.readAll(fd, into: &bytes, at: off_t(offset)) else { return nil }
            return bytes
        }
        /// Une structure à sa marque et à sa somme, ou `nil`.
        func valid(_ count: Int, at offset: UInt64, mark: String) -> [UInt8]? {
            guard let bytes = read(count, at: offset), Array(bytes[0..<4]) == Array(mark.utf8),
                  u32(bytes, 4) == Self.checksum(bytes, skipping: 4) else { return nil }
            return bytes
        }

        guard read(8, at: 0) == Self.mark else { throw Refusal.notVhdx }

        // **Le plus récent des en-têtes valides**, au numéro de séquence :
        // Hyper-V réécrit l'un puis l'autre, et une coupure entre les deux
        // laisse un en-tête abîmé ou périmé. Celui qui a la somme juste et le
        // plus grand numéro est le bon.
        let headers = [valid(4096, at: 64 << 10, mark: "head"), valid(4096, at: 128 << 10, mark: "head")]
            .compactMap { $0 }
        guard let header = headers.max(by: { u64($0, 8) < u64($1, 8) }) else {
            throw Refusal.badChecksum("des en-têtes")
        }
        guard u16(header, 66) == 1 else { throw Refusal.malformed("version \(u16(header, 66))") }
        // Un GUID de journal non nul : des écritures attendent d'être
        // rejouées, et le fichier tel quel n'est pas le disque.
        guard header[48..<64].allSatisfy({ $0 == 0 }) else { throw Refusal.pendingLog }

        // Les deux copies de la table des régions sont identiques ; la
        // première dont la somme tient fait foi.
        guard let regions = valid(64 << 10, at: 192 << 10, mark: "regi")
            ?? valid(64 << 10, at: 256 << 10, mark: "regi") else {
            throw Refusal.badChecksum("de la table des régions")
        }
        let regionCount = Int(u32(regions, 8))
        guard regionCount <= 2047 else { throw Refusal.malformed("\(regionCount) régions") }
        var batAt: (offset: UInt64, length: UInt64)?
        var metadataAt: (offset: UInt64, length: UInt64)?
        for index in 0..<regionCount {
            let entry = Array(regions[(16 + index * 32)..<(48 + index * 32)])
            let place = (offset: u64(entry, 16), length: UInt64(u32(entry, 24)))
            switch Array(entry[0..<16]) {
            case Self.batRegion: batAt = place
            case Self.metadataRegion: metadataAt = place
            default:
                if u32(entry, 28) & 1 == 1 { throw Refusal.malformed("région obligatoire inconnue") }
            }
        }
        guard let batAt, let metadataAt else { throw Refusal.malformed("table des blocs ou métadonnées absentes") }

        // Les métadonnées : une table de 64 Kio en tête de la région, dont
        // chaque entrée situe sa valeur par rapport au début de la région.
        guard metadataAt.length >= 64 << 10,
              let table = read(64 << 10, at: metadataAt.offset),
              Array(table[0..<8]) == Array("metadata".utf8) else {
            throw Refusal.malformed("table des métadonnées absente")
        }
        let itemCount = Int(u16(table, 10))
        guard itemCount <= 2047 else { throw Refusal.malformed("\(itemCount) métadonnées") }
        var items: [[UInt8]: [UInt8]] = [:]
        for index in 0..<itemCount {
            let entry = Array(table[(32 + index * 32)..<(64 + index * 32)])
            let id = Array(entry[0..<16])
            let offset = UInt64(u32(entry, 16))
            let length = Int(u32(entry, 20))
            let required = u32(entry, 24) & 4 != 0
            if [Self.fileParameters, Self.virtualDiskSize, Self.logicalSectorSize].contains(id) {
                guard length <= 16, offset &+ UInt64(length) <= metadataAt.length,
                      let value = read(length, at: metadataAt.offset + offset) else {
                    throw Refusal.malformed("métadonnée hors de sa région")
                }
                items[id] = value
            } else if required && !Self.known.contains(id) {
                throw Refusal.malformed("métadonnée obligatoire inconnue")
            }
        }
        guard let parameters = items[Self.fileParameters], parameters.count >= 8,
              let size = items[Self.virtualDiskSize], size.count >= 8,
              let sector = items[Self.logicalSectorSize], sector.count >= 4 else {
            throw Refusal.malformed("métadonnées incomplètes")
        }
        // Le bit 1 : « a un parent ».
        if u32(parameters, 4) & 2 != 0 { throw Refusal.differencing }
        let blockSize = UInt64(u32(parameters, 0))
        guard blockSize >= 1 << 20, blockSize <= 256 << 20, blockSize & (blockSize - 1) == 0 else {
            throw Refusal.malformed("bloc de \(blockSize) octets")
        }
        let sectorSize = UInt64(u32(sector, 0))
        guard sectorSize == 512 || sectorSize == 4096 else {
            throw Refusal.malformed("secteur de \(sectorSize) octets")
        }
        let virtualSize = u64(size, 0)
        guard virtualSize >= sectorSize, virtualSize <= 64 << 40 else {
            throw Refusal.malformed("disque de \(virtualSize) octets")
        }

        // Une carte de secteurs couvre 2^23 secteurs : autant de blocs de
        // données passent entre deux de ses entrées.
        let chunkRatio = Int((UInt64(1) << 23) * sectorSize / blockSize)
        let blocks = Int((virtualSize + blockSize - 1) / blockSize)
        let needed = blocks + (blocks - 1) / chunkRatio
        guard UInt64(needed) * 8 <= batAt.length, let bat = read(needed * 8, at: batAt.offset) else {
            throw Refusal.malformed("table de blocs hors du fichier")
        }
        entries = (0..<needed).map { u64(bat, $0 * 8) }
        self.fd = fd
        self.fileSize = fileSize
        self.virtualSize = virtualSize
        self.blockSize = Int(blockSize)
        self.chunkRatio = chunkRatio
    }

    deinit { close(fd) }

    /// Bloc par bloc. Les états 0 à 3 — absent, indéfini, mis à zéro,
    /// démappé — se lisent en zéros ; 6, « présent », se lit dans le
    /// fichier ; 7, « en partie présent », n'existe que dans un disque
    /// différentiel et fait échouer la lecture, comme tout état inconnu.
    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        let size = UInt64(blockSize)
        var done = 0
        while done < buffer.count {
            let position = offset + UInt64(done)
            let block = Int(position / size)
            let within = position % size
            let length = min(buffer.count - done, Int(size - within))
            let entry = entries[block + block / chunkRatio]
            switch entry & 7 {
            case 0...3:
                buffer.withUnsafeMutableBytes { raw in
                    _ = memset(raw.baseAddress! + done, 0, length)
                }
            case 6:
                // La table n'a pas de somme : une entrée hostile peut nommer
                // n'importe quel mébioctet, et l'addition déborder.
                let start = (entry >> 20) << 20
                guard start <= fileSize, within + UInt64(length) <= fileSize - start else { return false }
                let at = start + within
                var chunk = [UInt8](repeating: 0, count: length)
                guard VirtualDiskImages.readAll(fd, into: &chunk, at: off_t(at)) else { return false }
                buffer.replaceSubrange(done..<(done + length), with: chunk)
            default:
                return false
            }
            done += length
        }
        return true
    }
}
