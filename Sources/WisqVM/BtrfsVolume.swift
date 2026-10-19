import Foundation

/// Un système de fichiers btrfs, lu sans rien écrire.
///
/// **Ce qu'il sert à faire.** La même chose qu'`Ext4Volume`, pour l'image de
/// cloud de Fedora : sa partition principale est un btrfs, et son noyau, son
/// initramfs et ses entrées de démarrage vivent dans le sous-volume `boot`.
/// Il sait suivre un chemin (liens symboliques et sous-volumes compris),
/// lister un répertoire et lire un fichier.
///
/// **Comment on y lit.** Tout btrfs est fait d'arbres, adressés en adresses
/// *logiques* que l'arbre des tronçons traduit en positions sur le disque.
/// Le superbloc porte les premiers tronçons (ceux du système), assez pour lire
/// l'arbre des tronçons lui-même ; puis l'arbre racine donne celui de chaque
/// sous-volume, où vivent les inodes, les entrées de répertoire et les extents
/// des fichiers. Un fichier se lit extent par extent : en ligne dans l'arbre,
/// ou ailleurs sur le disque, compressé ou non.
///
/// **Ce qu'il refuse, en le disant** : un btrfs sur plusieurs disques, RAID5
/// et RAID6, les extents compressés en LZO, les fichiers chiffrés. Les sommes
/// de contrôle ne sont pas vérifiées, pour la raison d'`Ext4Volume` : ce
/// lecteur n'écrit pas, et l'image entière a sa somme publiée.
public final class BtrfsVolume: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notBtrfs
        case unsupported(String)
        case corrupt(String)
        case notFound(String)
        case notADirectory(String)
        case notAFile(String)
        case tooManyLinks(String)
        case tooLarge(String, UInt64)

        public var errorDescription: String? {
            switch self {
            case .notBtrfs: return "la partition n'est pas un système de fichiers btrfs."
            case .unsupported(let what): return "ce btrfs utilise \(what), que wisq ne lit pas."
            case .corrupt(let why): return "le système de fichiers est abîmé : \(why)"
            case .notFound(let path): return "« \(path) » n'existe pas."
            case .notADirectory(let path): return "« \(path) » n'est pas un répertoire."
            case .notAFile(let path): return "« \(path) » n'est pas un fichier."
            case .tooManyLinks(let path): return "« \(path) » passe par trop de liens symboliques."
            case .tooLarge(let path, let size): return "« \(path) » fait \(size) octets, plus que wisq n'en lit."
            }
        }
    }

    public typealias EntryKind = Ext4Volume.EntryKind

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let kind: EntryKind
    }

    /// L'UUID du système de fichiers (`fsid`), en minuscules comme `blkid`.
    public let uuid: String
    public let label: String
    public let sectorSize: Int
    public let nodeSize: Int

    private let read: (UInt64, Int) -> [UInt8]?
    private var chunks: [Chunk] = []
    private var rootTree: UInt64 = 0
    private var rootLevel: UInt8 = 0

    static let superblockOffset: UInt64 = 0x10000
    static let magic = Array("_BHRfS_M".utf8)
    public static let readLimit = Ext4Volume.readLimit

    // Les types de clés.
    static let inodeItem: UInt8 = 1
    static let dirIndex: UInt8 = 96
    static let extentData: UInt8 = 108
    static let rootItem: UInt8 = 132
    static let rootRef: UInt8 = 156
    static let chunkItem: UInt8 = 228

    /// L'arbre de fichiers du sommet, et l'inode de son répertoire racine.
    static let topTree: UInt64 = 5
    static let firstFreeObject: UInt64 = 256

    /// Les fonctions incompatibles qu'on sait lire, et celles qu'on nomme en
    /// les refusant.
    static let readable: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x100 | 0x200 | 0x400 | 0x800
        | 0x1000 | 0x10000
    static let named: [(UInt64, String)] = [
        (0x80, "RAID5 ou RAID6"),
        (0x2000, "l'arbre d'extents v2"),
        (0x4000, "l'arbre des bandes RAID"),
    ]

    struct Key: Comparable {
        var object: UInt64
        var type: UInt8
        var offset: UInt64

        static func < (a: Key, b: Key) -> Bool {
            (a.object, a.type, a.offset) < (b.object, b.type, b.offset)
        }

        init(object: UInt64, type: UInt8, offset: UInt64) {
            self.object = object; self.type = type; self.offset = offset
        }

        init(_ bytes: ArraySlice<UInt8>) {
            let base = bytes.startIndex
            object = le64(bytes, base)
            type = bytes[base + 8]
            offset = le64(bytes, base + 9)
        }
    }

    struct Chunk {
        let logical: UInt64
        let length: UInt64
        /// La position sur le disque du premier exemplaire : sur un seul
        /// disque, DUP en range deux et l'un suffit.
        let physical: UInt64
    }

    /// Ouvre le btrfs d'une partition de `size` octets ; `read(offset, count)`
    /// lit dans la partition.
    public init(size: UInt64, _ read: @escaping (UInt64, Int) -> [UInt8]?) throws {
        guard size >= Self.superblockOffset + 4096, let superblock = read(Self.superblockOffset, 4096),
              Array(superblock[0x40..<0x48]) == Self.magic
        else { throw Failure.notBtrfs }
        self.read = read
        uuid = Ext4Volume.uuidString(Array(superblock[0x20..<0x30]))
        label = String(decoding: superblock[0x12B..<0x22B].prefix { $0 != 0 }, as: UTF8.self)
        sectorSize = Int(le32(superblock[...], 0x90))
        nodeSize = Int(le32(superblock[...], 0x94))
        guard sectorSize >= 512, sectorSize <= 65536, nodeSize >= 4096, nodeSize <= 65536 else {
            throw Failure.corrupt("son superbloc donne des tailles impossibles.")
        }
        guard le64(superblock[...], 0x88) == 1 else { throw Failure.unsupported("plusieurs disques") }
        let incompat = le64(superblock[...], 0xBC)
        for (bit, name) in Self.named where incompat & bit != 0 { throw Failure.unsupported(name) }
        let unknown = incompat & ~Self.readable
        guard unknown == 0 else {
            throw Failure.unsupported("une fonction inconnue (0x\(String(unknown, radix: 16)))")
        }

        // Les tronçons du système, rangés dans le superbloc : clé, puis l'objet.
        let arraySize = Int(le32(superblock[...], 0xA0))
        guard arraySize <= 2048 else { throw Failure.corrupt("la table des tronçons du système déborde.") }
        let array = superblock[0x32B..<(0x32B + arraySize)]
        var position = array.startIndex
        while position + 17 + 48 <= array.endIndex {
            let key = Key(array[position..<(position + 17)])
            position += 17
            guard key.type == Self.chunkItem else { throw Failure.corrupt("un objet inattendu parmi les tronçons.") }
            let (chunk, length) = try Self.chunk(array[position...], logical: key.offset)
            chunks.append(chunk)
            position += length
        }

        // Puis l'arbre des tronçons entier.
        let chunkRoot = le64(superblock[...], 0x58)
        let chunkLevel = superblock[0xC7]
        let found = try items(in: chunkRoot, level: chunkLevel,
                              from: Key(object: 0, type: Self.chunkItem, offset: 0),
                              to: Key(object: .max, type: Self.chunkItem, offset: .max))
        for (key, data) in found where key.type == Self.chunkItem {
            let (chunk, _) = try Self.chunk(data, logical: key.offset)
            if !chunks.contains(where: { $0.logical == chunk.logical }) { chunks.append(chunk) }
        }
        rootTree = le64(superblock[...], 0x50)
        rootLevel = superblock[0xC6]
    }

    /// Le btrfs d'une partition d'un disque virtuel.
    public convenience init(_ partition: PartitionTable.Partition, in image: any VirtualDiskImage) throws {
        try self.init(size: partition.length) { offset, count in
            guard offset + UInt64(count) <= partition.length else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            return image.read(into: &buffer, at: partition.start + offset) ? buffer : nil
        }
    }

    static func chunk(_ bytes: ArraySlice<UInt8>, logical: UInt64) throws -> (Chunk, Int) {
        let base = bytes.startIndex
        guard bytes.count >= 48 else { throw Failure.corrupt("un tronçon tronqué.") }
        let length = le64(bytes, base)
        let stripes = Int(le16(bytes, base + 44))
        guard stripes >= 1, bytes.count >= 48 + 32 * stripes else { throw Failure.corrupt("un tronçon sans bande.") }
        let physical = le64(bytes, base + 48 + 8)
        return (Chunk(logical: logical, length: length, physical: physical), 48 + 32 * stripes)
    }

    /// Une adresse logique, sur le disque.
    func physical(_ logical: UInt64) throws -> UInt64 {
        for chunk in chunks where logical >= chunk.logical && logical - chunk.logical < chunk.length {
            return chunk.physical + (logical - chunk.logical)
        }
        throw Failure.corrupt("l'adresse logique 0x\(String(logical, radix: 16)) n'est dans aucun tronçon.")
    }

    /// `count` octets à une adresse logique, à travers autant de tronçons
    /// qu'il le faut.
    func readLogical(_ logical: UInt64, _ count: Int) throws -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(count)
        var address = logical
        while output.count < count {
            guard let chunk = chunks.first(where: { address >= $0.logical && address - $0.logical < $0.length })
            else { throw Failure.corrupt("l'adresse logique 0x\(String(address, radix: 16)) n'est dans aucun tronçon.") }
            let inChunk = Int(min(UInt64(count - output.count), chunk.length - (address - chunk.logical)))
            guard let bytes = read(chunk.physical + (address - chunk.logical), inChunk) else {
                throw Failure.corrupt("une lecture hors de la partition.")
            }
            output += bytes
            address += UInt64(inChunk)
        }
        return output
    }

    // MARK: - Les arbres

    /// Les objets d'un arbre dont la clé tombe dans `[from, to]`, dans l'ordre.
    /// La descente ne suit que les enfants dont l'intervalle peut en contenir.
    func items(in root: UInt64, level: UInt8, from: Key, to: Key) throws -> [(Key, ArraySlice<UInt8>)] {
        guard from <= to else { return [] }
        var found: [(Key, ArraySlice<UInt8>)] = []
        try visit(root, expectedLevel: level, keys: from...to, depth: 0, into: &found)
        return found
    }

    private func visit(_ address: UInt64, expectedLevel: UInt8, keys: ClosedRange<Key>, depth: Int,
                       into found: inout [(Key, ArraySlice<UInt8>)]) throws {
        guard depth <= 8 else { throw Failure.corrupt("un arbre trop profond.") }
        let node = try readLogical(address, nodeSize)
        guard le64(node[...], 0x30) == address else { throw Failure.corrupt("un nœud qui n'est pas à son adresse.") }
        let count = Int(le32(node[...], 0x60))
        let level = node[0x64]
        guard level == expectedLevel else { throw Failure.corrupt("un nœud au mauvais niveau.") }
        let header = 0x65
        if level == 0 {
            guard header + 25 * count <= nodeSize else { throw Failure.corrupt("une feuille qui déborde.") }
            for index in 0..<count {
                let at = header + 25 * index
                let key = Key(node[at..<(at + 17)])
                guard key >= keys.lowerBound else { continue }
                guard key <= keys.upperBound else { break }
                let offset = header + Int(le32(node[...], at + 17))
                let size = Int(le32(node[...], at + 21))
                guard offset + size <= nodeSize else { throw Failure.corrupt("un objet hors de sa feuille.") }
                found.append((key, node[offset..<(offset + size)]))
            }
            return
        }
        guard header + 33 * count <= nodeSize else { throw Failure.corrupt("un nœud qui déborde.") }
        for index in 0..<count {
            let at = header + 33 * index
            let key = Key(node[at..<(at + 17)])
            // L'enfant couvre de sa clé à celle du suivant.
            if key > keys.upperBound { break }
            if index + 1 < count {
                let next = Key(node[(at + 33)..<(at + 50)])
                if next <= keys.lowerBound { continue }
            }
            try visit(le64(node[...], at + 17), expectedLevel: level - 1, keys: keys,
                      depth: depth + 1, into: &found)
        }
    }

    /// L'arbre d'un sous-volume : l'adresse et le niveau de sa racine.
    func tree(_ id: UInt64) throws -> (root: UInt64, level: UInt8) {
        let found = try items(in: rootTree, level: rootLevel,
                              from: Key(object: id, type: Self.rootItem, offset: 0),
                              to: Key(object: id, type: Self.rootItem, offset: .max))
        guard let (_, data) = found.last, data.count >= 239 else {
            throw Failure.corrupt("le sous-volume \(id) n'a pas d'arbre.")
        }
        return (le64(data, data.startIndex + 176), data[data.startIndex + 238])
    }

    /// Les sous-volumes du sommet, par nom : `root`, `boot`, `home`… chez Fedora.
    public func subvolumes() throws -> [String: UInt64] {
        let found = try items(in: rootTree, level: rootLevel,
                              from: Key(object: Self.topTree, type: Self.rootRef, offset: 0),
                              to: Key(object: Self.topTree, type: Self.rootRef, offset: .max))
        var names: [String: UInt64] = [:]
        for (key, data) in found where data.count >= 18 {
            let length = Int(le16(data, data.startIndex + 16))
            guard data.count >= 18 + length else { continue }
            let start = data.startIndex + 18
            names[String(decoding: data[start..<(start + length)], as: UTF8.self)] = key.offset
        }
        return names
    }

    // MARK: - Les chemins

    /// Un inode, dans l'arbre d'un sous-volume.
    struct Inode {
        let tree: (root: UInt64, level: UInt8)
        let number: UInt64
        let size: UInt64
        let mode: UInt32

        var kind: EntryKind {
            switch mode & 0o170000 {
            case 0o100000: return .file
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .other
            }
        }
    }

    func inode(_ number: UInt64, in tree: (root: UInt64, level: UInt8)) throws -> Inode {
        let found = try items(in: tree.root, level: tree.level,
                              from: Key(object: number, type: Self.inodeItem, offset: 0),
                              to: Key(object: number, type: Self.inodeItem, offset: .max))
        guard let (_, data) = found.first, data.count >= 56 else {
            throw Failure.corrupt("l'inode \(number) manque.")
        }
        return Inode(tree: tree, number: number, size: le64(data, data.startIndex + 16),
                     mode: le32(data, data.startIndex + 52))
    }

    /// Ce qu'un répertoire contient, d'après ses `DIR_INDEX` : dans l'ordre de
    /// création, et sans le hachage des noms qu'il faudrait pour `DIR_ITEM`.
    private func children(of directory: Inode) throws -> [(name: String, location: Key, kind: EntryKind)] {
        let found = try items(in: directory.tree.root, level: directory.tree.level,
                              from: Key(object: directory.number, type: Self.dirIndex, offset: 0),
                              to: Key(object: directory.number, type: Self.dirIndex, offset: .max))
        return found.compactMap { _, data in
            guard data.count >= 30 else { return nil }
            let base = data.startIndex
            let location = Key(data[base..<(base + 17)])
            let nameLength = Int(le16(data, base + 27))
            guard data.count >= 30 + nameLength else { return nil }
            let name = String(decoding: data[(base + 30)..<(base + 30 + nameLength)], as: UTF8.self)
            let kind: EntryKind
            switch data[base + 29] {
            case 1: kind = .file
            case 2: kind = .directory
            case 7: kind = .symlink
            default: kind = .other
            }
            return (name, location, kind)
        }
    }

    /// Où mène une entrée : un inode du même arbre, ou la racine d'un autre
    /// sous-volume.
    private func target(of location: Key, from tree: (root: UInt64, level: UInt8)) throws -> Inode {
        if location.type == Self.rootItem {
            let subtree = try self.tree(location.object)
            return try inode(Self.firstFreeObject, in: subtree)
        }
        return try inode(location.object, in: tree)
    }

    private func top() throws -> Inode {
        try inode(Self.firstFreeObject, in: tree(Self.topTree))
    }

    func resolve(_ path: String) throws -> Inode {
        var links = 0
        return try walk(Self.components(path), from: top(), parents: [], path: path, links: &links)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    private func walk(_ parts: [String], from start: Inode, parents: [Inode], path: String,
                      links: inout Int) throws -> Inode {
        var current = start
        var stack = parents
        for (index, part) in parts.enumerated() {
            if part == ".." {
                current = stack.popLast() ?? current
                continue
            }
            guard current.kind == .directory else { throw Failure.notADirectory(path) }
            guard let entry = try children(of: current).first(where: { $0.name == part }) else {
                throw Failure.notFound(path)
            }
            var next = try target(of: entry.location, from: current.tree)
            if next.kind == .symlink {
                links += 1
                guard links <= 8 else { throw Failure.tooManyLinks(path) }
                let destination = String(decoding: try data(of: next), as: UTF8.self)
                let rest = Array(parts[(index + 1)...])
                if destination.hasPrefix("/") {
                    return try walk(Self.components(destination) + rest, from: top(), parents: [],
                                    path: path, links: &links)
                }
                next = try walk(Self.components(destination), from: current, parents: stack,
                                path: path, links: &links)
                return try walk(rest, from: next, parents: stack + [current], path: path, links: &links)
            }
            stack.append(current)
            current = next
        }
        return current
    }

    // MARK: - Ce qu'on lit

    public func contents(of path: String) throws -> [UInt8] {
        let found = try resolve(path)
        guard found.kind == .file else { throw Failure.notAFile(path) }
        guard found.size <= Self.readLimit else { throw Failure.tooLarge(path, found.size) }
        return try data(of: found)
    }

    public func list(_ path: String) throws -> [Entry] {
        let found = try resolve(path)
        guard found.kind == .directory else { throw Failure.notADirectory(path) }
        return try children(of: found).map { Entry(name: $0.name, kind: $0.kind) }
    }

    public func exists(_ path: String) -> Bool { (try? resolve(path)) != nil }

    /// Le contenu d'un fichier ou d'un lien, extent par extent. Ce que les
    /// extents ne couvrent pas (un trou, avec `NO_HOLES`) se lit en zéros.
    func data(of inode: Inode) throws -> [UInt8] {
        let size = Int(inode.size)
        var output = [UInt8](repeating: 0, count: size)
        let found = try items(in: inode.tree.root, level: inode.tree.level,
                              from: Key(object: inode.number, type: Self.extentData, offset: 0),
                              to: Key(object: inode.number, type: Self.extentData, offset: .max))
        for (key, item) in found {
            let base = item.startIndex
            guard item.count >= 21 else { throw Failure.corrupt("un extent tronqué.") }
            let memory = Int(le64(item, base + 8))
            let compression = item[base + 16]
            guard item[base + 17] == 0 else { throw Failure.unsupported("le chiffrement") }
            let fileOffset = Int(key.offset)
            guard fileOffset < size else { continue }
            var piece: [UInt8]
            switch item[base + 20] {
            case 0:
                // En ligne : les octets suivent, compressés ou non.
                piece = try Self.decompress(Array(item[(base + 21)...]), compression, expected: memory)
            case 1, 2:
                guard item.count >= 53 else { throw Failure.corrupt("un extent tronqué.") }
                let disk = le64(item, base + 21)
                let diskLength = Int(le64(item, base + 29))
                let offset = Int(le64(item, base + 37))
                let length = Int(le64(item, base + 45))
                // Un extent préalloué, ou un trou explicite : des zéros.
                if item[base + 20] == 2 || disk == 0 { continue }
                if compression == 0 {
                    piece = try readLogical(disk + UInt64(offset), length)
                } else {
                    var whole = try Self.decompress(try readLogical(disk, diskLength), compression,
                                                    expected: memory)
                    // **La fin d'un fichier se décompresse plus courte** que
                    // l'extent, arrondi au secteur : le reste est fait de
                    // zéros, comme Linux le lit.
                    guard whole.count <= memory, offset + length <= memory else {
                        throw Failure.corrupt("un extent compressé plus grand que dit.")
                    }
                    whole += [UInt8](repeating: 0, count: memory - whole.count)
                    piece = Array(whole[offset..<(offset + length)])
                }
            default:
                throw Failure.corrupt("un extent de type inconnu.")
            }
            let count = min(piece.count, size - fileOffset)
            output.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<count { buffer[fileOffset + index] = piece[index] }
            }
        }
        return output
    }

    static func decompress(_ bytes: [UInt8], _ compression: UInt8, expected: Int) throws -> [UInt8] {
        switch compression {
        case 0: return bytes
        case 1:
            // zlib : deux octets d'en-tête, puis le deflate.
            guard bytes.count > 2, let inflated = Inflate.raw(Array(bytes[2...]), limit: expected, exact: false)
            else { throw Failure.corrupt("un extent zlib illisible.") }
            return inflated
        case 2:
            throw Failure.unsupported("la compression LZO")
        case 3:
            return try Zstd.decompress(bytes, paddedWithZeros: true)
        default:
            throw Failure.unsupported("une compression inconnue (\(compression))")
        }
    }
}

private func le16(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func le32(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
}

private func le64(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
}
