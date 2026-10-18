import Foundation

/// Un système de fichiers ext2, ext3 ou ext4, lu sans rien écrire.
///
/// **Ce qu'il sert à faire.** Trouver dans une image de cloud le noyau et
/// l'initramfs que son `grub.cfg` désigne, et les lire. Il ne monte rien et
/// ne cherche pas à tout comprendre : il sait suivre un chemin (liens
/// symboliques compris), lister un répertoire et lire un fichier. Le reste
/// d'ext4 (le journal, les attributs étendus, les quotas) ne change rien à
/// ce qu'on lit et n'est pas regardé.
///
/// **Ce qu'il refuse, en le disant.** Un système dont le journal n'a pas été
/// rejoué : les octets en place pourraient être plus vieux que ce que la
/// machine a écrit en dernier. Les fonctions qu'il ne sait pas lire (un
/// journal sur un autre disque, `meta_bg`, la compression, les répertoires
/// en ligne) sont refusées par leur nom plutôt que lues de travers.
///
/// **Les sommes de `metadata_csum` ne sont pas vérifiées.** Elles protègent
/// contre une écriture interrompue, et ce lecteur n'écrit pas ; un fichier
/// abîmé se verra à la somme de l'image entière que la distribution publie.
public final class Ext4Volume: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notExt
        case unsupported(String)
        case corrupt(String)
        case notFound(String)
        case notADirectory(String)
        case notAFile(String)
        case tooManyLinks(String)
        case tooLarge(String, UInt64)

        public var errorDescription: String? {
            switch self {
            case .notExt: return "la partition n'est pas un système de fichiers ext2, ext3 ou ext4."
            case .unsupported(let what): return "ce système de fichiers utilise \(what), que wisq ne lit pas."
            case .corrupt(let why): return "le système de fichiers est abîmé : \(why)"
            case .notFound(let path): return "« \(path) » n'existe pas."
            case .notADirectory(let path): return "« \(path) » n'est pas un répertoire."
            case .notAFile(let path): return "« \(path) » n'est pas un fichier."
            case .tooManyLinks(let path): return "« \(path) » passe par trop de liens symboliques."
            case .tooLarge(let path, let size): return "« \(path) » fait \(size) octets, plus que wisq n'en lit."
            }
        }
    }

    /// Ce qu'une entrée de répertoire désigne.
    public enum EntryKind: Equatable, Sendable {
        case file
        case directory
        case symlink
        case other
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let inode: UInt32
        public let kind: EntryKind
    }

    public let blockSize: Int
    /// L'UUID du système de fichiers, en minuscules comme l'écrit `blkid` :
    /// c'est ce que vise un `root=UUID=…`.
    public let uuid: String
    public let label: String

    private let read: (UInt64, Int) -> [UInt8]?
    private let size: UInt64
    private let inodesPerGroup: UInt32
    private let inodeCount: UInt32
    private let inodeSize: Int
    private let descriptorSize: Int
    private let descriptorTable: UInt64
    private let groupCount: UInt32
    private let hasFileType: Bool

    static let rootInode: UInt32 = 2
    /// Ce qu'on accepte de lire d'un coup. Un initramfs de Debian fait une
    /// quarantaine de mégaoctets ; au-delà de 512 Mio, ce n'est plus un
    /// fichier de démarrage.
    public static let readLimit: UInt64 = 512 << 20

    // Les fonctions incompatibles : celles qu'il faut comprendre pour lire.
    static let incompatFileType: UInt32 = 0x0002
    static let incompatRecover: UInt32 = 0x0004
    static let incompatJournalDevice: UInt32 = 0x0008
    static let incompatMetaBG: UInt32 = 0x0010
    static let incompatExtents: UInt32 = 0x0040
    static let incompat64Bit: UInt32 = 0x0080
    static let known: UInt32 = 0x0002 | 0x0040 | 0x0080 | 0x0100 | 0x0200 | 0x0400 | 0x2000 | 0x4000
        | 0x8000 | 0x10000 | 0x20000
    static let named: [(UInt32, String)] = [
        (0x0001, "la compression"),
        (0x0004, "un journal qui n'a pas été rejoué (la machine ne s'est pas arrêtée proprement)"),
        (0x0008, "un journal sur un autre disque"),
        (0x0010, "meta_bg"),
        (0x1000, "dirdata"),
    ]

    /// Ouvre le système de fichiers d'une partition de `size` octets ;
    /// `read(offset, count)` lit dans la partition, pas dans le disque.
    public init(size: UInt64, _ read: @escaping (UInt64, Int) -> [UInt8]?) throws {
        guard size >= 2048, let superblock = read(1024, 1024), le16(superblock, 56) == 0xEF53 else {
            throw Failure.notExt
        }
        let incompat = le32(superblock, 96)
        for (bit, name) in Self.named where incompat & bit != 0 { throw Failure.unsupported(name) }
        let unknown = incompat & ~Self.known
        guard unknown == 0 else {
            throw Failure.unsupported("une fonction inconnue (0x\(String(unknown, radix: 16)))")
        }
        let logBlock = le32(superblock, 24)
        guard logBlock <= 6 else { throw Failure.corrupt("la taille de bloc annoncée est absurde.") }
        blockSize = 1024 << Int(logBlock)
        inodeCount = le32(superblock, 0)
        inodesPerGroup = le32(superblock, 40)
        let revision = le32(superblock, 76)
        inodeSize = revision == 0 ? 128 : Int(le16(superblock, 88))
        let is64 = incompat & Self.incompat64Bit != 0
        descriptorSize = is64 ? Int(le16(superblock, 0xFE)) : 32
        guard inodesPerGroup > 0, inodeSize >= 128, inodeSize <= blockSize,
              descriptorSize >= 32, descriptorSize <= 1024
        else { throw Failure.corrupt("son superbloc donne des tailles impossibles.") }
        let blocks = UInt64(le32(superblock, 4)) | (is64 ? UInt64(le32(superblock, 0x150)) << 32 : 0)
        let blocksPerGroup = le32(superblock, 32)
        guard blocksPerGroup > 0, blocks * UInt64(blockSize) <= size else {
            throw Failure.corrupt("il annonce plus de blocs que la partition n'en a.")
        }
        let firstData = UInt64(le32(superblock, 20))
        groupCount = UInt32((blocks - firstData + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup))
        descriptorTable = (firstData + 1) * UInt64(blockSize)
        hasFileType = incompat & Self.incompatFileType != 0
        uuid = Self.uuidString(Array(superblock[104..<120]))
        label = String(decoding: superblock[120..<136].prefix { $0 != 0 }, as: UTF8.self)
        self.read = read
        self.size = size
    }

    /// Le système de fichiers d'une partition d'un disque virtuel.
    public convenience init(_ partition: PartitionTable.Partition, in image: any VirtualDiskImage) throws {
        try self.init(size: partition.length) { offset, count in
            guard offset + UInt64(count) <= partition.length else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            return image.read(into: &buffer, at: partition.start + offset) ? buffer : nil
        }
    }

    // MARK: - Chemins

    /// Le contenu du fichier au bout de `path`, liens suivis.
    public func contents(of path: String) throws -> [UInt8] {
        let number = try resolve(path)
        let inode = try self.inode(number)
        guard inode.kind == .file else { throw Failure.notAFile(path) }
        guard inode.size <= Self.readLimit else { throw Failure.tooLarge(path, inode.size) }
        return try data(of: inode)
    }

    /// Les entrées du répertoire au bout de `path`, sans `.` ni `..`.
    public func list(_ path: String) throws -> [Entry] {
        let number = try resolve(path)
        let inode = try self.inode(number)
        guard inode.kind == .directory else { throw Failure.notADirectory(path) }
        return try entries(of: inode).filter { $0.name != "." && $0.name != ".." }
    }

    /// Vrai si `path` mène à quelque chose.
    public func exists(_ path: String) -> Bool { (try? resolve(path)) != nil }

    /// L'inode au bout de `path`. Un chemin relatif part de la racine : il
    /// n'y a pas de répertoire courant. Les liens symboliques sont suivis,
    /// quarante au plus, comme Linux.
    func resolve(_ path: String) throws -> UInt32 {
        var budget = 40
        return try walk(Self.components(path), from: Self.rootInode, parents: [], path: path,
                        budget: &budget).inode
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Descend `parts` depuis `start`. `parents` est la pile des répertoires
    /// traversés jusqu'à `start` : c'est elle que `..` remonte, et c'est la
    /// base d'un lien relatif. Rend l'inode atteint et sa propre pile, pour
    /// qu'un `..` qui suit un lien remonte depuis la cible du lien, comme
    /// dans Linux, et pas depuis le lien.
    private func walk(_ parts: [String], from start: UInt32, parents: [UInt32], path: String,
                      budget: inout Int) throws -> (inode: UInt32, parents: [UInt32]) {
        var current = start
        var stack = parents
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                current = stack.popLast() ?? Self.rootInode
                continue
            }
            let directory = try inode(current)
            guard directory.kind == .directory else { throw Failure.notADirectory(path) }
            guard let entry = try entries(of: directory).first(where: { $0.name == part }) else {
                throw Failure.notFound(path)
            }
            let target = try inode(entry.inode)
            guard target.kind == .symlink else {
                stack.append(current)
                current = entry.inode
                continue
            }
            budget -= 1
            guard budget >= 0 else { throw Failure.tooManyLinks(path) }
            let link = String(decoding: try linkTarget(target), as: UTF8.self)
            let absolute = link.hasPrefix("/")
            (current, stack) = try walk(Self.components(link), from: absolute ? Self.rootInode : current,
                                        parents: absolute ? [] : stack, path: path, budget: &budget)
        }
        return (current, stack)
    }

    // MARK: - Inodes

    struct Inode {
        let number: UInt32
        let mode: UInt16
        let flags: UInt32
        let size: UInt64
        let block: [UInt8]

        var kind: EntryKind {
            switch mode & 0xF000 {
            case 0x8000: return .file
            case 0x4000: return .directory
            case 0xA000: return .symlink
            default: return .other
            }
        }

        var usesExtents: Bool { flags & 0x0008_0000 != 0 }
        var inline: Bool { flags & 0x1000_0000 != 0 }
    }

    func inode(_ number: UInt32) throws -> Inode {
        guard number >= 1, number <= inodeCount else { throw Failure.corrupt("l'inode \(number) n'existe pas.") }
        let group = (number - 1) / inodesPerGroup
        let index = (number - 1) % inodesPerGroup
        guard group < groupCount,
              let descriptor = read(descriptorTable + UInt64(group) * UInt64(descriptorSize), descriptorSize)
        else { throw Failure.corrupt("le groupe de l'inode \(number) est illisible.") }
        var table = UInt64(le32(descriptor, 8))
        if descriptorSize >= 64 { table |= UInt64(le32(descriptor, 0x28)) << 32 }
        let offset = table * UInt64(blockSize) + UInt64(index) * UInt64(inodeSize)
        guard let bytes = read(offset, 128) else { throw Failure.corrupt("l'inode \(number) est illisible.") }
        let size = UInt64(le32(bytes, 4)) | UInt64(le32(bytes, 0x6C)) << 32
        return Inode(number: number, mode: le16(bytes, 0), flags: le32(bytes, 0x20), size: size,
                     block: Array(bytes[0x28..<0x64]))
    }

    /// La cible d'un lien. Courte (moins de 60 octets), elle tient dans
    /// l'inode lui-même ; sinon, c'est le contenu d'un fichier.
    private func linkTarget(_ inode: Inode) throws -> [UInt8] {
        guard inode.size <= 4096 else { throw Failure.corrupt("un lien de \(inode.size) octets.") }
        if inode.size < 60 && !inode.usesExtents || inode.inline {
            return Array(inode.block.prefix(Int(inode.size)))
        }
        return try data(of: inode)
    }

    // MARK: - Données

    /// Une plage du fichier : `count` blocs logiques à partir de `logical`,
    /// rangés à partir du bloc physique `physical` ; `nil` pour un trou ou
    /// un extent non écrit, qui se lisent comme des zéros.
    struct Run {
        let logical: UInt64
        let count: UInt64
        let physical: UInt64?
    }

    func data(of inode: Inode) throws -> [UInt8] {
        if inode.inline {
            guard inode.kind == .file, inode.size <= 60 else {
                throw Failure.unsupported("les données en ligne au-delà de l'inode")
            }
            return Array(inode.block.prefix(Int(inode.size)))
        }
        let block = UInt64(blockSize)
        let blocksNeeded = (inode.size + block - 1) / block
        var out = [UInt8](repeating: 0, count: Int(inode.size))
        for run in try runs(of: inode, upTo: blocksNeeded) {
            guard let physical = run.physical, run.logical < blocksNeeded else { continue }
            let count = min(run.count, blocksNeeded - run.logical)
            let start = run.logical * block
            let length = min(count * block, inode.size - start)
            guard physical + count <= size / block,
                  let bytes = read(physical * block, Int(length))
            else { throw Failure.corrupt("un bloc de l'inode \(inode.number) sort de la partition.") }
            out.replaceSubrange(Int(start)..<Int(start + length), with: bytes)
        }
        return out
    }

    func runs(of inode: Inode, upTo blocks: UInt64) throws -> [Run] {
        if inode.usesExtents {
            var runs: [Run] = []
            try extents(inode.block, depth: nil, into: &runs, inode: inode.number, visits: 0)
            return runs
        }
        return try mappedRuns(inode.block, upTo: blocks, inode: inode.number)
    }

    /// L'arbre des extents. Chaque nœud commence par un en-tête (0xF30A) ; à
    /// la profondeur zéro il porte des extents, au-dessus des index vers un
    /// bloc fils. La profondeur décroît d'un à chaque niveau, ce qui borne la
    /// descente même dans un arbre abîmé.
    private func extents(_ node: [UInt8], depth expected: Int?, into runs: inout [Run],
                         inode: UInt32, visits: Int) throws {
        guard node.count >= 12, le16(node, 0) == 0xF30A else {
            throw Failure.corrupt("l'arbre des extents de l'inode \(inode) est illisible.")
        }
        let entries = Int(le16(node, 2))
        let depth = Int(le16(node, 6))
        guard depth <= 5, expected == nil || depth == expected, 12 + 12 * entries <= node.count else {
            throw Failure.corrupt("l'arbre des extents de l'inode \(inode) est incohérent.")
        }
        for index in 0..<entries {
            let base = 12 + 12 * index
            if depth == 0 {
                let logical = UInt64(le32(node, base))
                var length = UInt64(le16(node, base + 4))
                // Au-delà de 32 768, l'extent est réservé mais pas écrit :
                // il se lit comme des zéros.
                let written = length <= 32768
                if !written { length -= 32768 }
                let physical = UInt64(le16(node, base + 6)) << 32 | UInt64(le32(node, base + 8))
                runs.append(Run(logical: logical, count: length, physical: written ? physical : nil))
            } else {
                let child = UInt64(le16(node, base + 8)) << 32 | UInt64(le32(node, base + 4))
                guard visits < 4096, child < size / UInt64(blockSize),
                      let bytes = read(child * UInt64(blockSize), blockSize)
                else { throw Failure.corrupt("un bloc d'index de l'inode \(inode) est illisible.") }
                try extents(bytes, depth: depth - 1, into: &runs, inode: inode, visits: visits + 1)
            }
        }
    }

    /// Les blocs à l'ancienne d'ext2 et ext3 : douze directs, puis un bloc
    /// d'adresses, puis un bloc de blocs d'adresses, puis trois niveaux. Un
    /// zéro est un trou.
    private func mappedRuns(_ block: [UInt8], upTo blocks: UInt64, inode: UInt32) throws -> [Run] {
        var runs: [Run] = []
        var logical: UInt64 = 0
        let perBlock = UInt64(blockSize / 4)
        func add(_ physical: UInt32) {
            if physical != 0 { runs.append(Run(logical: logical, count: 1, physical: UInt64(physical))) }
            logical += 1
        }
        func indirect(_ physical: UInt32, level: Int) throws {
            let span = (0..<level).reduce(UInt64(1)) { value, _ in value * perBlock }
            guard physical != 0 else {
                logical += span
                return
            }
            guard UInt64(physical) < size / UInt64(blockSize),
                  let bytes = read(UInt64(physical) * UInt64(blockSize), blockSize)
            else { throw Failure.corrupt("un bloc d'adresses de l'inode \(inode) sort de la partition.") }
            for index in 0..<Int(perBlock) where logical < blocks {
                let next = le32(bytes, 4 * index)
                if level == 1 { add(next) } else { try indirect(next, level: level - 1) }
            }
        }
        for index in 0..<12 where logical < blocks { add(le32(block, 4 * index)) }
        for level in 1...3 where logical < blocks { try indirect(le32(block, 48 + 4 * (level - 1)), level: level) }
        return runs
    }

    // MARK: - Répertoires

    /// Les entrées d'un répertoire, lues bloc par bloc. Un répertoire indexé
    /// (htree) se lit de la même façon : ses blocs d'index se présentent comme
    /// une entrée vide qui couvre le bloc entier, et sont ainsi sautés.
    private func entries(of directory: Inode) throws -> [Entry] {
        guard !directory.inline else { throw Failure.unsupported("les répertoires en ligne") }
        guard directory.size <= 64 << 20 else { throw Failure.corrupt("un répertoire de \(directory.size) octets.") }
        let bytes = try data(of: directory)
        var entries: [Entry] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let number = le32(bytes, offset)
            let length = Int(le16(bytes, offset + 4))
            let nameLength = hasFileType ? Int(bytes[offset + 6]) : Int(le16(bytes, offset + 6))
            guard length >= 8, length % 4 == 0, offset + length <= bytes.count, 8 + nameLength <= length else {
                throw Failure.corrupt("une entrée du répertoire \(directory.number) est incohérente.")
            }
            if number != 0 {
                let name = String(decoding: bytes[(offset + 8)..<(offset + 8 + nameLength)], as: UTF8.self)
                let kind: EntryKind
                switch hasFileType ? bytes[offset + 7] : 0 {
                case 1: kind = .file
                case 2: kind = .directory
                case 7: kind = .symlink
                case 0: kind = (try? inode(number).kind) ?? .other
                default: kind = .other
                }
                entries.append(Entry(name: name, inode: number, kind: kind))
            }
            offset += length
        }
        return entries
    }

    // MARK: - Octets

    static func uuidString(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex,
                                                                                    offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}

private func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
}
