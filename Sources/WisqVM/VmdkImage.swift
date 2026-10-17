import Foundation

/// Un disque VMDK « sparse », lu sur place, sans conversion.
///
/// **Pourquoi ce type existe.** Les appliances se distribuent en OVA, et un
/// OVA n'est qu'une archive tar autour d'un VMDK « streamOptimized » ;
/// VMware Workstation et Fusion rangent leurs disques en « monolithicSparse ».
/// Les deux sont la même structure — un en-tête, un répertoire de tables, des
/// tables de grains, des grains — et ce type la lit telle qu'elle a été
/// téléchargée.
///
/// **Ce qu'il lit.** Un fichier qui porte le disque entier et son descripteur :
/// `monolithicSparse` et `streamOptimized`. Les grains ordinaires, les grains
/// absents (des zéros), les grains marqués « zéro » quand l'en-tête le permet,
/// et les grains **compressés**, chacun précédé de son marqueur et compressé
/// en zlib — deflate entouré d'un en-tête de deux octets et d'une somme
/// Adler-32, que ce type vérifie. Le répertoire peut être en tête du fichier
/// ou, comme l'écrit `ovftool`, à la fin, derrière un pied qui répète
/// l'en-tête : c'est la forme que permet l'écriture en un seul passage.
///
/// **Ce qu'il refuse, en le nommant** : un disque découpé en plusieurs
/// fichiers ou décrit par un descripteur à part (le fichier ouvert n'en est
/// qu'un morceau), un disque différentiel qui s'appuie sur un parent, une
/// compression qu'il ne connaît pas, et tout drapeau inconnu. Lire un de
/// ceux-là « à peu près » rendrait à l'invité un disque faux sans le dire.
///
/// Les nombres sont petit-boutistes, et les décalages comptés en secteurs de
/// 512 octets (« Virtual Disk Format 5.0 », VMware).
public final class VmdkImage: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notVmdk
        case unsupportedVersion(UInt32)
        /// Le fichier n'est qu'une partie du disque : son descripteur, qui dit
        /// où sont les autres, est ailleurs ou nomme un autre type.
        case notMonolithic(String)
        case parentDisk
        case unknownCompression(UInt16)
        case unknownFlags(UInt32)
        /// Un champ de l'en-tête ou une table qui ne tient pas debout.
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notVmdk: return "ce fichier n'est pas un VMDK."
            case .unsupportedVersion(let version):
                return "VMDK version \(version) : wisq lit les versions 1 à 3."
            case .notMonolithic(let kind):
                return "ce VMDK (\(kind)) n'est qu'une partie du disque ; wisq lit "
                    + "les disques d'un seul fichier, monolithicSparse et streamOptimized."
            case .parentDisk:
                return "ce VMDK est un disque différentiel qui s'appuie sur un parent, que wisq n'a pas."
            case .unknownCompression(let algorithm):
                return "ce VMDK est compressé par l'algorithme \(algorithm) ; wisq lit le deflate."
            case .unknownFlags(let bits):
                return "ce VMDK demande des fonctionnalités inconnues (0x\(String(bits, radix: 16)))."
            case .malformed(let what): return "le VMDK est mal formé : \(what)."
            }
        }
    }

    public let virtualSize: UInt64
    /// La taille d'un grain, en octets — 64 Kio partout en pratique.
    public let grainSize: Int
    private let grainSectors: UInt64
    private let entriesPerTable: Int
    private let directory: [UInt32]
    private let compressed: Bool
    private let zeroGrains: Bool
    private let fd: Int32
    /// Où commence le VMDK dans le fichier ouvert : 0 d'ordinaire, le début
    /// du membre quand le disque est dans une archive OVA. Toutes les
    /// lectures passent par là, et `fileSize` est la taille du VMDK, pas du
    /// fichier.
    private let origin: off_t
    private let fileSize: UInt64

    /// Les tables de grains déjà lues, par secteur. Une table de 512 entrées
    /// couvre 32 Mio de disque : une poignée suffit à un démarrage.
    private var tableCache: [UInt32: [UInt32]] = [:]
    private var tableOrder: [UInt32] = []
    private static let tableCacheLimit = 64
    /// Le dernier grain décompressé : l'invité lit un grain de 64 Kio par
    /// blocs de 4 Kio, et le décompresser seize fois serait seize fois trop.
    private var lastGrain: (sector: UInt32, bytes: [UInt8])?
    private let lock = NSLock()

    static let magic = Array("KDMV".utf8)
    /// Le répertoire est à la fin du fichier, et le pied dit où.
    private static let directoryAtEnd = UInt64.max
    private static let flagValidNewlines: UInt32 = 1 << 0
    private static let flagRedundantTable: UInt32 = 1 << 1
    private static let flagZeroGrains: UInt32 = 1 << 2
    private static let flagCompressed: UInt32 = 1 << 16
    private static let flagMarkers: UInt32 = 1 << 17

    /// Ouvre `url` en lecture seule.
    public convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.malformed("le fichier n'a pas pu être ouvert") }
        do { try self.init(takingOwnershipOf: fd) } catch { close(fd); throw error }
    }

    /// Les champs d'un en-tête — celui du début, ou celui du pied.
    private struct Header {
        let version: UInt32
        let flags: UInt32
        let capacity: UInt64
        let grainSectors: UInt64
        let descriptorOffset: UInt64
        let descriptorSectors: UInt64
        let entriesPerTable: UInt32
        let directoryOffset: UInt64
        let compression: UInt16

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= 79, Array(bytes[0..<4]) == VmdkImage.magic else { return nil }
            func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
            func u32(_ at: Int) -> UInt32 {
                bytes[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
            }
            func u64(_ at: Int) -> UInt64 {
                bytes[at..<(at + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
            }
            version = u32(4)
            flags = u32(8)
            capacity = u64(12)
            grainSectors = u64(20)
            descriptorOffset = u64(28)
            descriptorSectors = u64(36)
            entriesPerTable = u32(44)
            directoryOffset = u64(56)
            compression = u16(77)
        }
    }

    /// Lit l'en-tête de `fd`, qui appartient ensuite à l'image. `member`
    /// désigne le VMDK quand il n'est qu'une partie du fichier — le membre
    /// d'une archive OVA, lu en place.
    public init(takingOwnershipOf fd: Int32, member: (offset: UInt64, length: UInt64)? = nil) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let whole = UInt64(info.st_size)
        let origin = member?.offset ?? 0
        let fileSize = member?.length ?? whole
        guard origin <= whole, fileSize <= whole - origin else {
            throw Refusal.malformed("le disque déborde de l'archive")
        }
        func block(at offset: UInt64, count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            let from = off_t(origin) + off_t(offset)
            return VirtualDiskImages.readAll(fd, into: &bytes, at: from) ? bytes : nil
        }
        guard let first = block(at: 0, count: 512), var header = Header(first) else {
            throw Refusal.notVmdk
        }
        guard (1...3).contains(header.version) else {
            throw Refusal.unsupportedVersion(header.version)
        }
        // **Le répertoire à la fin.** Un fichier écrit d'un seul passage ne
        // sait pas, en écrivant son en-tête, où ira le répertoire : il le met
        // après les grains, et répète l'en-tête, complet cette fois, dans le
        // pied — l'avant-dernier secteur, entre le marqueur de pied et celui
        // de fin de flux.
        if header.directoryOffset == Self.directoryAtEnd {
            guard fileSize >= 1536, let tail = block(at: fileSize - 1024, count: 512),
                  let footer = Header(tail), footer.directoryOffset != Self.directoryAtEnd
            else { throw Refusal.malformed("répertoire annoncé en fin de fichier, pied absent") }
            header = footer
        }

        let known = Self.flagValidNewlines | Self.flagRedundantTable | Self.flagZeroGrains
            | Self.flagCompressed | Self.flagMarkers
        guard header.flags & ~known == 0 else { throw Refusal.unknownFlags(header.flags & ~known) }
        let compressed = header.flags & Self.flagCompressed != 0
        if compressed {
            guard header.compression == 1 else { throw Refusal.unknownCompression(header.compression) }
            // Sans marqueur, rien ne dit où finit un grain compressé.
            guard header.flags & Self.flagMarkers != 0 else {
                throw Refusal.malformed("grains compressés sans marqueurs")
            }
        } else if header.compression != 0 {
            throw Refusal.unknownCompression(header.compression)
        }

        // **Le descripteur dit ce qu'est ce fichier.** Un morceau d'un disque
        // découpé a le même en-tête qu'un disque entier, à une capacité près
        // qui serait la sienne : seul le descripteur, embarqué dans les
        // formes d'un seul fichier, permet de ne pas prendre une partie pour
        // le tout.
        guard header.descriptorOffset > 0, header.descriptorSectors > 0 else {
            throw Refusal.notMonolithic("descripteur à part")
        }
        guard header.descriptorSectors <= 2048,
              header.descriptorOffset <= fileSize / 512,
              header.descriptorSectors <= fileSize / 512 - header.descriptorOffset,
              let raw = block(at: header.descriptorOffset * 512, count: Int(header.descriptorSectors) * 512)
        else { throw Refusal.malformed("descripteur hors du fichier") }
        let descriptor = Self.descriptorFields(raw)
        let createType = descriptor["createType"] ?? "type absent"
        guard createType == "monolithicSparse" || createType == "streamOptimized" else {
            throw Refusal.notMonolithic(createType)
        }
        if let parent = descriptor["parentCID"], parent.lowercased() != "ffffffff" {
            throw Refusal.parentDisk
        }

        guard header.capacity > 0 else { throw Refusal.malformed("disque de capacité nulle") }
        guard (1...(1 << 16)).contains(header.grainSectors) else {
            throw Refusal.malformed("grains de \(header.grainSectors) secteurs")
        }
        guard (1...(1 << 16)).contains(header.entriesPerTable) else {
            throw Refusal.malformed("tables de \(header.entriesPerTable) entrées")
        }
        guard header.capacity <= UInt64.max / 512 else {
            throw Refusal.malformed("capacité hors de portée")
        }
        let perTable = header.grainSectors * UInt64(header.entriesPerTable)
        let tables = (header.capacity + perTable - 1) / perTable
        // Un répertoire plus grand que le fichier ne peut pas exister : la
        // borne protège l'allocation qui suit d'un en-tête hostile.
        guard tables * 4 <= fileSize, header.directoryOffset <= fileSize / 512,
              header.directoryOffset * 512 <= fileSize - tables * 4,
              let rawDirectory = block(at: header.directoryOffset * 512, count: Int(tables) * 4)
        else { throw Refusal.malformed("répertoire hors du fichier") }

        self.fd = fd
        self.origin = off_t(origin)
        self.fileSize = fileSize
        self.virtualSize = header.capacity * 512
        self.grainSectors = header.grainSectors
        self.grainSize = Int(header.grainSectors) * 512
        self.entriesPerTable = Int(header.entriesPerTable)
        self.directory = Self.littleEndianWords(rawDirectory)
        self.compressed = compressed
        self.zeroGrains = header.flags & Self.flagZeroGrains != 0
    }

    deinit { close(fd) }

    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        lock.lock()
        defer { lock.unlock() }
        var done = 0
        var at = offset
        let grainBytes = UInt64(grainSize)
        while done < buffer.count {
            let grain = at / grainBytes
            let within = Int(at % grainBytes)
            let take = min(buffer.count - done, grainSize - within)
            guard let sector = grainSector(grain) else { return false }
            if sector == 0 || (sector == 1 && zeroGrains) {
                // Absent, ou marqué zéro : sans parent, les deux se lisent
                // comme des zéros.
                for index in done..<(done + take) { buffer[index] = 0 }
            } else if compressed {
                guard let bytes = decompressed(sector, grain: grain) else { return false }
                buffer.replaceSubrange(done..<(done + take), with: bytes[within..<(within + take)])
            } else {
                var piece = [UInt8](repeating: 0, count: take)
                let from = origin + off_t(sector) * 512 + off_t(within)
                guard VirtualDiskImages.readAll(fd, into: &piece, at: from) else { return false }
                buffer.replaceSubrange(done..<(done + take), with: piece)
            }
            done += take
            at += UInt64(take)
        }
        return true
    }

    /// Le secteur où commence le grain `grain` ; `0` quand rien n'est alloué,
    /// `nil` quand une table est illisible.
    private func grainSector(_ grain: UInt64) -> UInt32? {
        let tableIndex = Int(grain / UInt64(entriesPerTable))
        let entry = Int(grain % UInt64(entriesPerTable))
        guard tableIndex < directory.count else { return nil }
        let tableSector = directory[tableIndex]
        if tableSector == 0 { return 0 }
        if let table = tableCache[tableSector] { return table[entry] }
        var raw = [UInt8](repeating: 0, count: entriesPerTable * 4)
        guard VirtualDiskImages.readAll(fd, into: &raw, at: origin + off_t(tableSector) * 512) else { return nil }
        let table = Self.littleEndianWords(raw)
        tableCache[tableSector] = table
        tableOrder.append(tableSector)
        if tableOrder.count > Self.tableCacheLimit { tableCache[tableOrder.removeFirst()] = nil }
        return table[entry]
    }

    /// Le grain compressé qui commence au secteur `sector`, décompressé.
    ///
    /// Le marqueur qui le précède porte l'adresse du grain sur le disque, en
    /// secteurs, et la longueur des données compressées. L'adresse est
    /// vérifiée : un grain rangé sous une autre entrée que la sienne est un
    /// fichier abîmé, pas un disque à lire.
    private func decompressed(_ sector: UInt32, grain: UInt64) -> [UInt8]? {
        if let last = lastGrain, last.sector == sector { return last.bytes }
        let start = UInt64(sector) * 512
        guard start <= fileSize, fileSize - start >= 12 else { return nil }
        var marker = [UInt8](repeating: 0, count: 12)
        guard VirtualDiskImages.readAll(fd, into: &marker, at: origin + off_t(start)) else { return nil }
        let lba = marker[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let length = UInt64(marker[8..<12].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard lba == grain * grainSectors, length > 6, length <= fileSize - start - 12 else { return nil }
        var input = [UInt8](repeating: 0, count: Int(length))
        guard VirtualDiskImages.readAll(fd, into: &input, at: origin + off_t(start + 12)) else { return nil }
        // Le dernier grain d'un disque dont la taille n'est pas un multiple
        // du grain est plus court, et compressé tel quel : c'est ce qu'écrit
        // `qemu-img`, et la somme ne porte que sur ces octets-là. Ce qui
        // manque n'est jamais lu, la lecture s'arrêtant à la fin du disque.
        let remaining = virtualSize - grain * UInt64(grainSize)
        let expected = Int(min(UInt64(grainSize), remaining))
        guard let bytes = Self.inflateZlib(input, expected: expected) else { return nil }
        lastGrain = (sector, bytes)
        return bytes
    }

    /// Un flux zlib (RFC 1950) : deux octets d'en-tête, deflate brut, et la
    /// somme Adler-32 des octets décompressés, gros-boutiste. La somme est
    /// vérifiée — c'est le seul contrôle que le format offre sur un grain.
    static func inflateZlib(_ input: [UInt8], expected: Int) -> [UInt8]? {
        guard input.count >= 6 else { return nil }
        let cmf = input[0], flg = input[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0,
              flg & 0x20 == 0
        else { return nil }
        guard let bytes = Inflate.raw(Array(input[2...]), limit: expected, exact: true) else { return nil }
        // La somme suit le flux deflate, dont `Inflate` ne rend pas la fin :
        // il s'arrête à `expected`. Elle est donc prise dans les quatre
        // derniers octets que le marqueur annonce — sa longueur est celle des
        // données compressées, exactement, sans bourrage.
        let sum = input[(input.count - 4)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return adler32(bytes) == sum ? bytes : nil
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        var index = 0
        // 5 552 octets, la plus longue suite qui ne déborde pas d'un UInt32
        // avant le modulo.
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            for byte in bytes[index..<end] {
                low += UInt32(byte)
                high += low
            }
            low %= 65521
            high %= 65521
            index = end
        }
        return high << 16 | low
    }

    /// Les lignes `clé="valeur"` ou `clé=valeur` du descripteur.
    static func descriptorFields(_ raw: [UInt8]) -> [String: String] {
        let end = raw.firstIndex(of: 0) ?? raw.count
        let text = String(decoding: raw[0..<end], as: UTF8.self)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    private static func littleEndianWords(_ raw: [UInt8]) -> [UInt32] {
        (0..<(raw.count / 4)).map { index in
            raw[(index * 4)..<(index * 4 + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    /// Le fichier commence-t-il comme un VMDK « sparse » ? Sans rien valider
    /// d'autre.
    public static func looksLikeOne(fd: Int32) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 4)
        let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 4, 0) }
        return got == 4 && bytes == magic
    }
}
