import Foundation

/// **Un système de fichiers FAT**, en lecture seule : FAT12, FAT16 et FAT32,
/// noms longs compris.
///
/// **Pourquoi ce type existe.** Gentoo — ses images « di » pour machines
/// virtuelles — monte la partition EFI sur `/boot` : le noyau, l'initramfs et
/// `grub/grub.cfg` y sont, et nulle part ailleurs. Sans lire le FAT, wisq ne
/// trouvait aucun noyau dans une image pourtant complète, et la refusait.
///
/// **Ce qu'il lit** : le secteur de démarrage (le BPB), la table d'allocation,
/// les répertoires — la racine fixe de FAT12/16 ou en chaîne de FAT32 —, les
/// noms longs (VFAT) vérifiés contre la somme du nom court, et les noms
/// courts avec la casse que Windows NT range dans l'octet `0x0C`. Les noms se
/// comparent sans tenir compte de la casse, comme le fait le FAT.
///
/// **Ce qu'il refuse, en le disant** : une chaîne qui sort de la table ou
/// boucle, un cluster marqué défectueux, un fichier plus grand que sa
/// chaîne. Tout ce qui se lit dans le secteur de démarrage est borné avant
/// d'être multiplié : l'image vient d'ailleurs.
public final class FatVolume: LinuxVolume {
    public enum Failure: Error, Equatable, LocalizedError {
        case notFat
        case corrupt(String)
        case notFound(String)
        case notAFile(String)
        case tooLarge(String, UInt64)

        public var errorDescription: String? {
            switch self {
            case .notFat: return "ce n'est pas un système de fichiers FAT."
            case .corrupt(let what): return "le FAT est abîmé : \(what)"
            case .notFound(let path): return "\(path) est introuvable."
            case .notAFile(let path): return "\(path) n'est pas un fichier."
            case .tooLarge(let path, let size): return "\(path) fait \(size) octets, trop pour être lu."
            }
        }
    }

    public enum Kind: Equatable, Sendable { case fat12, fat16, fat32 }

    public let kind: Kind
    public let clusterSize: Int
    public static let readLimit = Ext4Volume.readLimit

    private let read: (UInt64, Int) -> [UInt8]?
    private let bytesPerSector: UInt64
    private let fatOffset: UInt64
    private let fatBytes: Int
    /// La racine fixe de FAT12/16 : où, et combien d'entrées.
    private let rootOffset: UInt64
    private let rootEntries: Int
    /// La racine de FAT32, qui est une chaîne comme les autres.
    private let rootCluster: UInt32
    private let dataOffset: UInt64
    /// Les clusters de données sont numérotés de 2 à `clusterCount + 1`.
    private let clusterCount: UInt32
    private lazy var fat: [UInt8]? = read(fatOffset, fatBytes)

    /// Une entrée de répertoire : son nom, ce qu'elle est, où elle commence.
    struct Entry {
        let name: String
        let isDirectory: Bool
        let firstCluster: UInt32
        let size: UInt64
    }

    /// Ouvre le FAT d'une partition de `size` octets ; `read(offset, count)`
    /// lit dans la partition.
    public init(size: UInt64, _ read: @escaping (UInt64, Int) -> [UInt8]?) throws {
        guard size >= 512, let boot = read(0, 512), boot[510] == 0x55, boot[511] == 0xAA,
              boot[0] == 0xEB || boot[0] == 0xE9
        else { throw Failure.notFat }
        func u16(_ at: Int) -> UInt64 { UInt64(boot[at]) | UInt64(boot[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt64 { u16(at) | u16(at + 2) << 16 }
        let bytesPerSector = u16(11)
        let sectorsPerCluster = UInt64(boot[13])
        let reserved = u16(14)
        let fats = UInt64(boot[16])
        let rootEntries = u16(17)
        let totalSectors = u16(19) != 0 ? u16(19) : u32(32)
        let fatSectors = u16(22) != 0 ? u16(22) : u32(36)
        // Tout est borné avant d'être multiplié : des puissances de deux
        // raisonnables, deux tables au plus en pratique, une racine fixe d'au
        // plus 65 535 entrées.
        guard [512, 1024, 2048, 4096].contains(bytesPerSector),
              sectorsPerCluster > 0, sectorsPerCluster <= 128, sectorsPerCluster & (sectorsPerCluster - 1) == 0,
              reserved > 0, (1...4).contains(fats), fatSectors > 0, totalSectors > 0,
              totalSectors <= size / bytesPerSector
        else { throw Failure.notFat }
        let rootSectors = (rootEntries * 32 + bytesPerSector - 1) / bytesPerSector
        let metadata = reserved + fats * fatSectors + rootSectors
        guard metadata < totalSectors else { throw Failure.notFat }
        let clusters = (totalSectors - metadata) / sectorsPerCluster
        // Le genre se décide au nombre de clusters, et à lui seul : c'est la
        // règle de Microsoft, et celle de Linux.
        let kind: Kind = clusters < 4085 ? .fat12 : clusters < 65525 ? .fat16 : .fat32
        if kind == .fat32 {
            guard rootEntries == 0 else { throw Failure.notFat }
        } else {
            guard rootEntries > 0 else { throw Failure.notFat }
        }
        let entryBits: UInt64 = kind == .fat12 ? 12 : kind == .fat16 ? 16 : 32
        let tableBytes = ((clusters + 2) * entryBits + 7) / 8
        guard tableBytes <= fatSectors * bytesPerSector, tableBytes <= 64 << 20 else {
            throw Failure.corrupt("la table d'allocation ne couvre pas les clusters.")
        }
        self.kind = kind
        self.read = read
        self.bytesPerSector = bytesPerSector
        clusterSize = Int(sectorsPerCluster * bytesPerSector)
        fatOffset = reserved * bytesPerSector
        fatBytes = Int(tableBytes)
        rootOffset = (reserved + fats * fatSectors) * bytesPerSector
        self.rootEntries = Int(rootEntries)
        rootCluster = kind == .fat32 ? UInt32(truncatingIfNeeded: u32(44)) : 0
        dataOffset = metadata * bytesPerSector
        clusterCount = UInt32(clusters)
        if kind == .fat32 {
            guard isData(rootCluster) else { throw Failure.corrupt("la racine est hors des clusters.") }
        }
    }

    public convenience init(_ partition: PartitionTable.Partition, in image: any VirtualDiskImage) throws {
        try self.init(size: partition.length) { offset, count in
            guard offset <= partition.length, UInt64(count) <= partition.length - offset else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            return image.read(into: &buffer, at: partition.start + offset) ? buffer : nil
        }
    }

    // MARK: - La table

    private func isData(_ cluster: UInt32) -> Bool { cluster >= 2 && cluster - 2 < clusterCount }

    /// Le cluster qui suit `cluster` ; `nil` en fin de chaîne.
    func next(_ cluster: UInt32) throws -> UInt32? {
        guard let fat else { throw Failure.corrupt("la table d'allocation est illisible.") }
        let value: UInt32
        let end: UInt32
        let bad: UInt32
        switch kind {
        case .fat12:
            let at = Int(cluster) * 3 / 2
            guard at + 1 < fat.count else { throw Failure.corrupt("un cluster hors de la table.") }
            let pair = UInt32(fat[at]) | UInt32(fat[at + 1]) << 8
            value = cluster & 1 == 0 ? pair & 0xFFF : pair >> 4
            (end, bad) = (0xFF8, 0xFF7)
        case .fat16:
            let at = Int(cluster) * 2
            guard at + 1 < fat.count else { throw Failure.corrupt("un cluster hors de la table.") }
            value = UInt32(fat[at]) | UInt32(fat[at + 1]) << 8
            (end, bad) = (0xFFF8, 0xFFF7)
        case .fat32:
            let at = Int(cluster) * 4
            guard at + 3 < fat.count else { throw Failure.corrupt("un cluster hors de la table.") }
            value = (UInt32(fat[at]) | UInt32(fat[at + 1]) << 8 | UInt32(fat[at + 2]) << 16
                | UInt32(fat[at + 3]) << 24) & 0x0FFF_FFFF
            (end, bad) = (0x0FFF_FFF8, 0x0FFF_FFF7)
        }
        if value >= end { return nil }
        guard value != bad else { throw Failure.corrupt("un cluster marqué défectueux.") }
        guard isData(value) else { throw Failure.corrupt("une chaîne qui sort des clusters.") }
        return value
    }

    /// Les octets d'une chaîne, au plus `limit` — un fichier s'arrête à sa
    /// taille, un répertoire au bout de sa chaîne. **Un cluster déjà lu est
    /// une boucle**, refusée : borner le nombre de pas ne suffisait pas, un
    /// fichier qui boucle sur lui-même s'arrêtait à sa taille et rendait le
    /// même cluster cent fois, sans le dire.
    func chain(from first: UInt32, limit: UInt64) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var cluster: UInt32? = first
        var visited = Set<UInt32>()
        while let current = cluster, UInt64(bytes.count) < limit {
            guard isData(current) else { throw Failure.corrupt("une chaîne qui sort des clusters.") }
            guard visited.insert(current).inserted else { throw Failure.corrupt("une chaîne qui boucle.") }
            let offset = dataOffset + UInt64(current - 2) * UInt64(clusterSize)
            guard let piece = read(offset, clusterSize) else { throw Failure.corrupt("un cluster illisible.") }
            bytes += piece
            cluster = try next(current)
        }
        return bytes
    }

    // MARK: - Les répertoires

    /// Les entrées d'un répertoire, `.` et `..` exclus.
    func entries(ofDirectoryAt cluster: UInt32?) throws -> [Entry] {
        let raw: [UInt8]
        if let cluster {
            raw = try chain(from: cluster, limit: .max)
        } else {
            guard let fixed = read(rootOffset, rootEntries * 32) else {
                throw Failure.corrupt("la racine est illisible.")
            }
            raw = fixed
        }
        var found: [Entry] = []
        var long: [Int: [UInt16]] = [:]
        var longChecksum: UInt8?
        for at in stride(from: 0, to: raw.count - 31, by: 32) {
            let entry = raw[at..<(at + 32)]
            let first = entry[at]
            if first == 0x00 { break }
            if first == 0xE5 { long = [:]; continue }
            let attributes = entry[at + 11]
            if attributes & 0x3F == 0x0F {
                // Un morceau de nom long : treize unités UTF-16, en trois
                // endroits de l'entrée, numérotées depuis la fin.
                let order = Int(first & 0x1F)
                var units: [UInt16] = []
                for offset in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] {
                    units.append(UInt16(entry[at + offset]) | UInt16(entry[at + offset + 1]) << 8)
                }
                if first & 0x40 != 0 { long = [:] }
                long[order] = units
                longChecksum = entry[at + 13]
                continue
            }
            defer { long = [:]; longChecksum = nil }
            // L'étiquette du volume n'est pas un fichier.
            if attributes & 0x08 != 0 { continue }
            let short = Array(entry[at..<(at + 11)])
            let name: String
            if !long.isEmpty, longChecksum == Self.checksum(short) {
                let units = long.keys.sorted().flatMap { long[$0] ?? [] }
                let cut = units.prefix { $0 != 0x0000 && $0 != 0xFFFF }
                name = String(decoding: cut, as: UTF16.self)
            } else {
                name = Self.shortName(short, caseFlags: entry[at + 12])
            }
            if name == "." || name == ".." { continue }
            let high = UInt32(entry[at + 20]) | UInt32(entry[at + 21]) << 8
            let low = UInt32(entry[at + 26]) | UInt32(entry[at + 27]) << 8
            let size = UInt64(entry[at + 28]) | UInt64(entry[at + 29]) << 8
                | UInt64(entry[at + 30]) << 16 | UInt64(entry[at + 31]) << 24
            found.append(Entry(name: name, isDirectory: attributes & 0x10 != 0,
                               firstCluster: (kind == .fat32 ? high << 16 : 0) | low, size: size))
        }
        return found
    }

    /// La somme que chaque morceau de nom long porte, du nom court qu'il
    /// accompagne : un nom long dont la somme ne correspond pas a été laissé
    /// par un système qui ne connaissait que les noms courts.
    static func checksum(_ short: [UInt8]) -> UInt8 {
        short.reduce(UInt8(0)) { (($0 & 1) << 7 | $0 >> 1) &+ $1 }
    }

    /// `KERNEL~1 57` en `KERNEL~1.57` ; en minuscules quand NT l'a noté.
    static func shortName(_ short: [UInt8], caseFlags: UInt8) -> String {
        var base = String(decoding: short[0..<8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var ext = String(decoding: short[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if short[0] == 0x05 { base = "\u{E5}" + base.dropFirst() }
        if caseFlags & 0x08 != 0 { base = base.lowercased() }
        if caseFlags & 0x10 != 0 { ext = ext.lowercased() }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// L'entrée au bout de `path`, la racine pour `/`.
    func resolve(_ path: String) throws -> Entry {
        var current = Entry(name: "/", isDirectory: true, firstCluster: kind == .fat32 ? rootCluster : 0, size: 0)
        for component in path.split(separator: "/") where component != "." {
            guard current.isDirectory else { throw Failure.notFound(path) }
            let wanted = component.lowercased()
            let listing = try entries(ofDirectoryAt: current.firstCluster == 0 ? nil : current.firstCluster)
            guard let match = listing.first(where: { $0.name.lowercased() == wanted }) else {
                throw Failure.notFound(path)
            }
            current = match
        }
        return current
    }

    // MARK: - LinuxVolume

    public func contents(of path: String) throws -> [UInt8] {
        let found = try resolve(path)
        guard !found.isDirectory else { throw Failure.notAFile(path) }
        guard found.size <= Self.readLimit else { throw Failure.tooLarge(path, found.size) }
        if found.size == 0 { return [] }
        let bytes = try chain(from: found.firstCluster, limit: found.size)
        guard UInt64(bytes.count) >= found.size else {
            throw Failure.corrupt("\(path) est plus court que sa taille.")
        }
        return Array(bytes[0..<Int(found.size)])
    }

    public func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)] {
        let found = try resolve(path)
        guard found.isDirectory else { throw Failure.notFound(path) }
        return try entries(ofDirectoryAt: found.firstCluster == 0 ? nil : found.firstCluster)
            .map { ($0.name, $0.isDirectory ? .directory : .file) }
    }

    public func exists(_ path: String) -> Bool { (try? resolve(path)) != nil }
}
