import Foundation

/// Un disque VDI — le format de VirtualBox —, lu sur place, sans conversion.
///
/// **Pourquoi ce type existe.** Une machine Linux qu'on a dans VirtualBox vit
/// dans un `.vdi`. Le reconnaître et demander `qemu-img convert` était
/// honnête, mais mettait un ordinateur de plus sur le chemin ; comme pour le
/// qcow2 et le VMDK, wisq lit le fichier tel qu'il est.
///
/// **Le format.** Un en-tête de 512 octets — un texte libre de 64 octets, puis
/// la marque `0xBEDA107F` en 0x40 (c'est elle qui reconnaît le format : QEMU
/// et VirtualBox n'écrivent pas le même texte) —, une table de blocs, puis les
/// blocs. Chaque entrée de la table, sur 32 bits, dit où vit un bloc du disque
/// parmi ceux du fichier, ou qu'il n'a jamais été écrit (`0xFFFFFFFF`) ou
/// qu'il a été mis à zéro (`0xFFFFFFFE`) : dans les deux cas, des zéros. Un
/// bloc du fichier porte `blockExtra` octets de données privées avant ses
/// données. Le disque « fixe » est le même format, toutes ses entrées remplies.
/// Les nombres sont petit-boutistes.
///
/// **Ce qu'il refuse, en le nommant** : une version autre que la 1.1, un
/// disque différentiel (`type 4`), qui ne contient que ce qui a changé depuis
/// son parent — wisq n'a pas le parent, et lire le différentiel seul rendrait
/// un disque troué —, et un en-tête ou une table qui ne tient pas debout.
///
/// Lecture seule, comme les autres : les écritures de l'invité vont dans la
/// couche de `FileDiskStore`, et le fichier reste celui de VirtualBox.
public final class VdiImage: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notVdi
        case unsupportedVersion(UInt32)
        /// Un disque différentiel, qui ne se lit qu'avec son parent.
        case differencing
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notVdi: return "ce fichier n'est pas un VDI."
            case .unsupportedVersion(let version):
                return "VDI version \(version >> 16).\(version & 0xFFFF) : wisq lit la version 1.1."
            case .differencing:
                return "le VDI est un disque différentiel, qui ne se lit qu'avec le disque dont il dépend."
            case .malformed(let what): return "le VDI est mal formé : \(what)."
            }
        }
    }

    /// La marque, en 0x40.
    static let signature: UInt32 = 0xBEDA_107F
    /// Les deux entrées de la table qui ne désignent aucun bloc du fichier.
    static let unallocated: UInt32 = 0xFFFF_FFFF
    static let zeroed: UInt32 = 0xFFFF_FFFE

    public let virtualSize: UInt64
    public let blockSize: Int
    private let blockExtra: UInt64
    private let dataOffset: UInt64
    private let blocks: [UInt32]
    private let fd: Int32
    private let fileSize: UInt64

    /// Le fichier commence-t-il comme un VDI ?
    static func looksLikeOne(fd: Int32) -> Bool {
        var word: UInt32 = 0
        let got = withUnsafeMutableBytes(of: &word) { pread(fd, $0.baseAddress!, 4, 0x40) }
        return got == 4 && UInt32(littleEndian: word) == signature
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    /// Ouvre `url` en lecture seule.
    public convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.malformed("le fichier n'a pas pu être ouvert") }
        do { try self.init(takingOwnershipOf: fd) } catch { close(fd); throw error }
    }

    /// Lit l'en-tête et la table de `fd`, qui appartient ensuite à l'image.
    public init(takingOwnershipOf fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let fileSize = UInt64(max(info.st_size, 0))
        var header = [UInt8](repeating: 0, count: 0x190)
        guard VirtualDiskImages.readAll(fd, into: &header, at: 0) else { throw Refusal.notVdi }
        func u32(_ at: Int) -> UInt32 {
            header[at..<(at + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ at: Int) -> UInt64 {
            header[at..<(at + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard u32(0x40) == Self.signature else { throw Refusal.notVdi }
        let version = u32(0x44)
        guard version == 0x0001_0001 else { throw Refusal.unsupportedVersion(version) }
        // 1 : dynamique ; 2 : fixe. 3, « annulation », est une copie de
        // travail que VirtualBox jette ; 4 dépend d'un parent.
        let kind = u32(0x4C)
        if kind == 4 { throw Refusal.differencing }
        guard kind == 1 || kind == 2 else { throw Refusal.malformed("type de disque \(kind)") }

        let blocksOffset = UInt64(u32(0x154))
        let dataOffset = UInt64(u32(0x158))
        let virtualSize = u64(0x170)
        let blockSize = UInt64(u32(0x178))
        let blockExtra = UInt64(u32(0x17C))
        let blockCount = UInt64(u32(0x180))
        guard virtualSize >= 512 else { throw Refusal.malformed("disque de moins d'un secteur") }
        guard blockSize >= 512, blockSize % 512 == 0, blockSize <= 1 << 30 else {
            throw Refusal.malformed("bloc de \(blockSize) octets")
        }
        // La table couvre le disque entier, ni plus court ni démesuré : la
        // borne passe avant l'allocation.
        guard blockCount == (virtualSize + blockSize - 1) / blockSize else {
            throw Refusal.malformed("\(blockCount) blocs pour \(virtualSize) octets")
        }
        guard blocksOffset >= 0x190, blocksOffset &+ blockCount * 4 <= fileSize else {
            throw Refusal.malformed("table de blocs hors du fichier")
        }
        var table = [UInt8](repeating: 0, count: Int(blockCount) * 4)
        guard VirtualDiskImages.readAll(fd, into: &table, at: off_t(blocksOffset)) else {
            throw Refusal.malformed("table de blocs illisible")
        }
        blocks = (0..<Int(blockCount)).map { index in
            table[(index * 4)..<(index * 4 + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        self.fd = fd
        self.fileSize = fileSize
        self.virtualSize = virtualSize
        self.blockSize = Int(blockSize)
        self.blockExtra = blockExtra
        self.dataOffset = dataOffset
    }

    deinit { close(fd) }

    /// Bloc par bloc : les blocs du disque ne sont pas contigus dans le
    /// fichier, et une lecture qui en traverse un bord se recoud ici.
    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        let size = UInt64(blockSize)
        var done = 0
        while done < buffer.count {
            let position = offset + UInt64(done)
            let index = Int(position / size)
            let within = position % size
            let length = min(buffer.count - done, Int(size - within))
            let entry = blocks[index]
            if entry == Self.unallocated || entry == Self.zeroed {
                buffer.withUnsafeMutableBytes { raw in
                    _ = memset(raw.baseAddress! + done, 0, length)
                }
            } else {
                let at = dataOffset + UInt64(entry) * (size + blockExtra) + blockExtra + within
                guard at + UInt64(length) <= fileSize else { return false }
                var chunk = [UInt8](repeating: 0, count: length)
                guard VirtualDiskImages.readAll(fd, into: &chunk, at: off_t(at)) else { return false }
                buffer.replaceSubrange(done..<(done + length), with: chunk)
            }
            done += length
        }
        return true
    }
}
