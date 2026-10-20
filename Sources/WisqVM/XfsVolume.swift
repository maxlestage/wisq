import Foundation

/// Un système de fichiers XFS, lu sans rien écrire.
///
/// **Ce qu'il sert à faire.** La même chose qu'`Ext4Volume` et
/// `BtrfsVolume`, pour les images de cloud dont la racine est un XFS :
/// openSUSE Tumbleweed (« Minimal-VM »), et la famille de Red Hat — Rocky,
/// AlmaLinux, CentOS Stream. Leur noyau et leur initramfs vivent dans
/// `/boot`, sur ce XFS ; la partition EFI ne porte que GRUB. Sans ce
/// lecteur, `CloudBoot` répondait « aucune partition Linux » à une image
/// parfaitement démarrable.
///
/// **Comment on y lit.** Tout est en gros-boutiste. Le superbloc, au début
/// de la partition, donne la taille des blocs et des inodes, et le numéro de
/// l'inode racine ; un numéro d'inode porte lui-même sa place (groupe, bloc,
/// rang dans le bloc). Un inode a une « fourche de données » de trois
/// formes : **en ligne** (petit répertoire, lien court), **extents** (une
/// liste de plages), **arbre B** (des extents trop nombreux pour l'inode).
/// Un répertoire en blocs se lit bloc de données par bloc de données — les
/// blocs de feuilles et de nœuds, au-delà de 32 Gio de décalage logique,
/// ne servent qu'à chercher vite et sont ignorés : on parcourt.
///
/// **Ce qu'il refuse, en le disant** : un volume temps réel, les fonctions
/// incompatibles qu'il ne connaît pas, et la version 4 — celle d'avant les
/// sommes de contrôle, que Linux 6.18 ne monte plus et qu'aucune image de
/// cloud encore suivie n'utilise. Les
/// sommes de contrôle ne sont pas vérifiées, pour la raison d'`Ext4Volume` :
/// ce lecteur n'écrit pas, et l'image entière a sa somme publiée.
public final class XfsVolume: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case notXfs
        case unsupported(String)
        case corrupt(String)
        case notFound(String)
        case notADirectory(String)
        case notAFile(String)
        case tooManyLinks(String)
        case tooLarge(String, UInt64)

        public var errorDescription: String? {
            switch self {
            case .notXfs: return "la partition n'est pas un système de fichiers XFS."
            case .unsupported(let what): return "ce XFS utilise \(what), que wisq ne lit pas."
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

    public let uuid: String
    public let label: String
    public let blockSize: Int
    public static let readLimit = Ext4Volume.readLimit

    let inodeSize: Int
    let agBlocks: UInt64
    let agBlockLog: Int
    let inodesPerBlockLog: Int
    let directoryBlockSize: Int
    /// Les entrées de répertoire portent un octet de type.
    let fileTypes: Bool
    let rootInode: UInt64
    private let read: (UInt64, Int) -> [UInt8]?

    static let magic: [UInt8] = Array("XFSB".utf8)
    /// Les blocs de données d'un répertoire vivent sous ce décalage ; au-delà,
    /// ce sont les feuilles et les nœuds d'index.
    static let leafOffset: UInt64 = 32 << 30

    /// Les fonctions incompatibles qu'il sait lire : le type dans les
    /// entrées, les inodes clairsemés, l'identifiant de métadonnées à part,
    /// les dates étendues, les compteurs d'extents sur 64 bits, l'échange
    /// d'extents, et les pointeurs vers le parent — qu'openSUSE active, et
    /// qui vivent dans les attributs étendus, qu'on ne lit pas. Rien de tout
    /// ça ne change la façon de lire un fichier, sauf les compteurs sur
    /// 64 bits, que `inode` traite.
    static let readableIncompat: UInt32 = 0x1 | 0x2 | 0x4 | 0x8 | 0x20 | 0x40 | 0x80

    /// Ouvre le XFS d'une partition de `size` octets ; `read(offset, count)`
    /// lit dans la partition.
    public init(size: UInt64, _ read: @escaping (UInt64, Int) -> [UInt8]?) throws {
        guard size >= 512, let sb = read(0, 512), Array(sb[0..<4]) == Self.magic else { throw Failure.notXfs }
        self.read = read
        let s = sb[...]
        blockSize = Int(be32(s, 4))
        rootInode = be64(s, 56)
        agBlocks = UInt64(be32(s, 84))
        let version = be16(s, 100) & 0x0F
        inodeSize = Int(be16(s, 104))
        agBlockLog = Int(sb[124])
        inodesPerBlockLog = Int(sb[123])
        directoryBlockSize = blockSize << Int(sb[192])
        uuid = Ext4Volume.uuidString(Array(sb[32..<48]))
        label = String(decoding: sb[108..<120].prefix { $0 != 0 }, as: UTF8.self)
        guard blockSize >= 512, blockSize <= 65536, blockSize & (blockSize - 1) == 0,
              inodeSize >= 256, inodeSize <= 2048, agBlocks > 0, agBlockLog > 0, agBlockLog < 32,
              directoryBlockSize <= 65536
        else { throw Failure.corrupt("son superbloc donne des tailles impossibles.") }
        guard version == 5 else { throw Failure.unsupported("la version \(version)") }
        guard be64(s, 16) == 0 else { throw Failure.unsupported("un volume temps réel") }
        let incompat = be32(s, 216)
        let unknown = incompat & ~Self.readableIncompat
        guard unknown == 0 else {
            throw Failure.unsupported("une fonction inconnue (0x\(String(unknown, radix: 16)))")
        }
        fileTypes = incompat & 0x1 != 0
    }

    /// Le XFS d'une partition d'un disque virtuel.
    public convenience init(_ partition: PartitionTable.Partition, in image: any VirtualDiskImage) throws {
        try self.init(size: partition.length) { offset, count in
            guard offset + UInt64(count) <= partition.length else { return nil }
            var buffer = [UInt8](repeating: 0, count: count)
            return image.read(into: &buffer, at: partition.start + offset) ? buffer : nil
        }
    }

    // MARK: - Adresses

    /// Un numéro de bloc du système de fichiers — groupe en haut, bloc dans
    /// le groupe en bas — en octet de la partition.
    func byteOffset(ofBlock block: UInt64) -> UInt64 {
        let group = block >> UInt64(agBlockLog)
        let inGroup = block & ((1 << UInt64(agBlockLog)) - 1)
        return (group * agBlocks + inGroup) * UInt64(blockSize)
    }

    func readBlocks(_ block: UInt64, count: Int) throws -> [UInt8] {
        guard let bytes = read(byteOffset(ofBlock: block), count * blockSize) else {
            throw Failure.corrupt("un bloc hors de la partition.")
        }
        return bytes
    }

    // MARK: - Inodes

    struct Extent {
        let logical: UInt64
        let block: UInt64
        let count: UInt64
        /// Réservé, jamais écrit : se lit en zéros, comme un trou.
        let unwritten: Bool
    }

    struct Inode {
        let number: UInt64
        let mode: UInt16
        let size: UInt64
        let format: UInt8
        /// La fourche de données, telle qu'elle est dans l'inode.
        let fork: ArraySlice<UInt8>
        let extentCount: UInt64

        var kind: EntryKind {
            switch mode & 0o170000 {
            case 0o100000: return .file
            case 0o040000: return .directory
            case 0o120000: return .symlink
            default: return .other
            }
        }
    }

    func inode(_ number: UInt64) throws -> Inode {
        let perBlock = UInt64(inodesPerBlockLog)
        let group = number >> (UInt64(agBlockLog) + perBlock)
        let block = (number >> perBlock) & ((1 << UInt64(agBlockLog)) - 1)
        let index = number & ((1 << perBlock) - 1)
        let offset = (group * agBlocks + block) * UInt64(blockSize) + index * UInt64(inodeSize)
        guard let raw = read(offset, inodeSize), raw.count == inodeSize else {
            throw Failure.corrupt("l'inode \(number) est hors de la partition.")
        }
        let bytes = raw[...]
        guard be16(bytes, 0) == 0x494E else { throw Failure.corrupt("l'inode \(number) n'en est pas un.") }
        let core = 176
        let forkOffset = Int(raw[82]) * 8
        let forkEnd = forkOffset > 0 ? core + forkOffset : inodeSize
        guard forkEnd <= inodeSize, core <= forkEnd else { throw Failure.corrupt("l'inode \(number) déborde.") }
        // Compteurs d'extents sur 64 bits (`NREXT64`) : un drapeau de l'inode
        // les déplace dans l'ancien remplissage.
        let wide = be64(bytes, 120) & (1 << 4) != 0
        let extents = wide ? be64(bytes, 24) : UInt64(be32(bytes, 76))
        return Inode(number: number, mode: be16(bytes, 2), size: be64(bytes, 56), format: raw[5],
                     fork: bytes[core..<forkEnd], extentCount: extents)
    }

    /// Les extents d'un inode, triés par décalage logique.
    func extents(of inode: Inode) throws -> [Extent] {
        switch inode.format {
        case 2:
            guard inode.extentCount * 16 <= UInt64(inode.fork.count) else {
                throw Failure.corrupt("l'inode \(inode.number) annonce trop d'extents.")
            }
            return (0..<Int(inode.extentCount)).map { Self.extent(inode.fork, inode.fork.startIndex + $0 * 16) }
        case 3:
            var found: [Extent] = []
            let fork = inode.fork
            let level = be16(fork, fork.startIndex)
            let records = Int(be16(fork, fork.startIndex + 2))
            let capacity = (fork.count - 4) / 16
            guard level > 0, records <= capacity else { throw Failure.corrupt("la racine d'un arbre d'extents.") }
            for index in 0..<records {
                let pointer = be64(fork, fork.startIndex + 4 + capacity * 8 + index * 8)
                try collect(pointer, level: Int(level) - 1, into: &found, depth: 0)
            }
            return found.sorted { $0.logical < $1.logical }
        default:
            return []
        }
    }

    /// Un enregistrement d'extent : 128 bits, du drapeau « non écrit » au
    /// nombre de blocs.
    static func extent(_ bytes: ArraySlice<UInt8>, _ at: Int) -> Extent {
        let high = be64(bytes, at), low = be64(bytes, at + 8)
        return Extent(logical: (high >> 9) & ((1 << 54) - 1),
                      block: ((high & 0x1FF) << 43) | (low >> 21),
                      count: low & ((1 << 21) - 1), unwritten: high >> 63 != 0)
    }

    private func collect(_ block: UInt64, level: Int, into found: inout [Extent], depth: Int) throws {
        guard depth < 8 else { throw Failure.corrupt("un arbre d'extents trop profond.") }
        let bytes = try readBlocks(block, count: 1)[...]
        let header = 72
        guard bytes.count >= header else { throw Failure.corrupt("un bloc d'arbre trop court.") }
        let records = Int(be16(bytes, 6))
        if level == 0 {
            guard header + records * 16 <= bytes.count else { throw Failure.corrupt("une feuille d'extents déborde.") }
            for index in 0..<records { found.append(Self.extent(bytes, header + index * 16)) }
        } else {
            let capacity = (bytes.count - header) / 16
            guard records <= capacity else { throw Failure.corrupt("un nœud d'extents déborde.") }
            for index in 0..<records {
                try collect(be64(bytes, header + capacity * 8 + index * 8), level: level - 1,
                            into: &found, depth: depth + 1)
            }
        }
    }

    /// `length` octets à partir du décalage `offset` d'un inode ; les trous
    /// se lisent en zéros.
    func data(of inode: Inode, from offset: UInt64 = 0, length: UInt64) throws -> [UInt8] {
        if inode.format == 1 {
            let end = min(Int(length), inode.fork.count)
            return Array(inode.fork.prefix(end))
        }
        var out = [UInt8](repeating: 0, count: Int(length))
        let size = UInt64(blockSize)
        for extent in try extents(of: inode) where !extent.unwritten {
            let start = extent.logical * size, end = start + extent.count * size
            guard end > offset, start < offset + length else { continue }
            let from = max(start, offset), to = min(end, offset + length)
            let firstBlock = (from - start) / size
            let blocks = Int((to - start + size - 1) / size - firstBlock)
            let bytes = try readBlocks(extent.block + firstBlock, count: blocks)
            let skip = Int(from - (start + firstBlock * size))
            let count = Int(to - from)
            out.replaceSubrange(Int(from - offset)..<Int(to - offset), with: bytes[skip..<(skip + count)])
        }
        return out
    }

    // MARK: - Répertoires

    func entries(of directory: Inode) throws -> [(name: String, inode: UInt64)] {
        directory.format == 1 ? try shortForm(directory) : try blockForm(directory)
    }

    /// Un répertoire en ligne : un en-tête (nombre, numéros longs ou non,
    /// parent), puis les entrées serrées.
    private func shortForm(_ directory: Inode) throws -> [(name: String, inode: UInt64)] {
        let fork = directory.fork
        guard fork.count >= 6 else { throw Failure.corrupt("un petit répertoire trop court.") }
        let count = Int(fork[fork.startIndex])
        let wide = fork[fork.startIndex + 1] > 0
        let numberSize = wide ? 8 : 4
        func number(at index: Int) -> UInt64 { wide ? be64(fork, index) : UInt64(be32(fork, index)) }
        var entries: [(name: String, inode: UInt64)] = [(".", directory.number),
                                                       ("..", number(at: fork.startIndex + 2))]
        var position = fork.startIndex + 2 + numberSize
        for _ in 0..<count {
            guard position < fork.endIndex else { throw Failure.corrupt("un petit répertoire déborde.") }
            let length = Int(fork[position])
            let nameStart = position + 3
            let after = nameStart + length + (fileTypes ? 1 : 0)
            guard after + numberSize <= fork.endIndex else { throw Failure.corrupt("un petit répertoire déborde.") }
            entries.append((String(decoding: fork[nameStart..<(nameStart + length)], as: UTF8.self),
                            number(at: after)))
            position = after + numberSize
        }
        return entries
    }

    /// Un répertoire en blocs : chaque bloc de données, en dessous de 32 Gio,
    /// est une suite d'entrées et de trous. Le format « bloc » unique finit
    /// par ses feuilles et une queue, qu'il faut sauter.
    private func blockForm(_ directory: Inode) throws -> [(name: String, inode: UInt64)] {
        var entries: [(name: String, inode: UInt64)] = []
        let blocksPerDirectoryBlock = UInt64(directoryBlockSize / blockSize)
        let limit = Self.leafOffset / UInt64(blockSize)
        for extent in try extents(of: directory) {
            // Un bloc de répertoire commence toujours sur un multiple de sa
            // taille, et un extent aussi : aucun n'est lu deux fois.
            var logical = extent.logical
            while logical < min(extent.logical + extent.count, limit) {
                defer { logical += blocksPerDirectoryBlock }
                let bytes = try data(of: directory, from: logical * UInt64(blockSize),
                                     length: UInt64(directoryBlockSize))
                try parseDataBlock(bytes, into: &entries)
            }
        }
        return entries
    }

    private func parseDataBlock(_ bytes: [UInt8], into entries: inout [(name: String, inode: UInt64)]) throws {
        let block = bytes[...]
        let magic = Array(bytes[0..<4])
        let header = 64
        var end = bytes.count
        switch String(decoding: magic, as: UTF8.self) {
        case "XDB3":
            // Le format bloc : la queue (nombre de feuilles, feuilles mortes),
            // et les feuilles de huit octets juste devant.
            let leaves = Int(be32(block, bytes.count - 8))
            end = bytes.count - 8 - leaves * 8
            guard end >= header else { throw Failure.corrupt("un bloc de répertoire déborde.") }
        case "XDD3":
            break
        default:
            throw Failure.corrupt("un bloc de répertoire sans signature.")
        }
        var position = header
        while position + 8 <= end {
            if be16(block, position) == 0xFFFF {
                let length = Int(be16(block, position + 2))
                guard length >= 8, length % 8 == 0 else { throw Failure.corrupt("un trou de répertoire.") }
                position += length
                continue
            }
            let number = be64(block, position)
            let length = Int(bytes[position + 8])
            let nameStart = position + 9
            guard length > 0, nameStart + length <= end else { throw Failure.corrupt("une entrée de répertoire.") }
            entries.append((String(decoding: bytes[nameStart..<(nameStart + length)], as: UTF8.self), number))
            let raw = 8 + 1 + length + (fileTypes ? 1 : 0) + 2
            position += (raw + 7) & ~7
        }
    }

    // MARK: - Chemins

    func resolve(_ path: String) throws -> Inode {
        var links = 0
        return try walk(Self.components(path), from: inode(rootInode), path: path, links: &links)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    /// Les entrées `..` du disque suffisent ici, à la différence de btrfs :
    /// un XFS n'a pas de sous-volumes, chaque répertoire connaît son parent.
    private func walk(_ parts: [String], from start: Inode, path: String, links: inout Int) throws -> Inode {
        var current = start
        for (index, part) in parts.enumerated() {
            guard current.kind == .directory else { throw Failure.notADirectory(path) }
            guard let entry = try entries(of: current).first(where: { $0.name == part }) else {
                throw Failure.notFound(path)
            }
            let next = try inode(entry.inode)
            if next.kind == .symlink {
                links += 1
                guard links <= 8 else { throw Failure.tooManyLinks(path) }
                let destination = String(decoding: try linkTarget(next), as: UTF8.self)
                let rest = Array(parts[(index + 1)...])
                let base = destination.hasPrefix("/") ? try inode(rootInode) : current
                return try walk(Self.components(destination) + rest, from: base, path: path, links: &links)
            }
            current = next
        }
        return current
    }

    /// Le texte d'un lien : en ligne, ou dans des blocs qui commencent
    /// chacun par un en-tête de 56 octets.
    func linkTarget(_ link: Inode) throws -> [UInt8] {
        guard link.size <= 4096 else { throw Failure.corrupt("un lien de \(link.size) octets.") }
        if link.format == 1 { return Array(link.fork.prefix(Int(link.size))) }
        var out: [UInt8] = []
        let header = 56
        for extent in try extents(of: link) {
            for block in 0..<extent.count {
                let bytes = try readBlocks(extent.block + block, count: 1)
                guard String(decoding: bytes[0..<4], as: UTF8.self) == "XSLM" else {
                    throw Failure.corrupt("un bloc de lien sans signature.")
                }
                let count = Int(be32(bytes[...], 8))
                guard header + count <= bytes.count else { throw Failure.corrupt("un bloc de lien déborde.") }
                out += bytes[header..<(header + count)]
            }
        }
        return Array(out.prefix(Int(link.size)))
    }

    // MARK: - Ce qu'on lit

    public func contents(of path: String) throws -> [UInt8] {
        let found = try resolve(path)
        guard found.kind == .file else { throw Failure.notAFile(path) }
        guard found.size <= Self.readLimit else { throw Failure.tooLarge(path, found.size) }
        return try data(of: found, length: found.size)
    }

    public func list(_ path: String) throws -> [Entry] {
        let found = try resolve(path)
        guard found.kind == .directory else { throw Failure.notADirectory(path) }
        return try entries(of: found).filter { $0.name != "." && $0.name != ".." }.map {
            Entry(name: $0.name, kind: try inode($0.inode).kind)
        }
    }

    public func exists(_ path: String) -> Bool { (try? resolve(path)) != nil }
}

// Gros-boutiste, sur une tranche dont l'indice de départ peut ne pas être zéro.
private func be16(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt16 {
    UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
}

private func be32(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[at + $1]) }
}

private func be64(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + $1]) }
}
