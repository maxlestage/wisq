import Foundation

/// Un disque qcow2, lu sur place, sans conversion.
///
/// **Pourquoi ce type existe.** Les distributions livrent leurs images de cloud
/// en qcow2, et c'est la forme qu'elles recommandent pour une machine prête en
/// une minute. Reconnaître le format et demander `qemu-img convert` était
/// honnête, mais mettait un ordinateur de plus sur le chemin ; ce type lit le
/// fichier tel qu'il a été téléchargé.
///
/// **Ce qu'il lit.** L'en-tête, la table L1, les tables L2 qu'elle désigne, les
/// clusters ordinaires, les clusters marqués « zéro », et les clusters
/// **compressés** — deflate brut, que presque toutes les images de cloud
/// emploient, décodé par `Inflate`, le même sur toutes les plateformes. Lecture seule : les écritures de l'invité ne passent jamais par
/// ici, elles vont dans la couche de `FileDiskStore`, et le fichier téléchargé
/// reste octet pour octet celui qui a été téléchargé.
///
/// **Ce qu'il refuse, en le nommant** : une image chiffrée, une image qui
/// s'appuie sur un fichier de base (`backing_file`), une image à fichier de
/// données externe, une image marquée corrompue, la compression zstd, les L2
/// étendues, et tout bit de fonctionnalité incompatible qu'il ne connaît pas.
/// Lire une de celles-là « à peu près » rendrait à l'invité un disque faux sans
/// le dire ; le refus dit au moins pourquoi.
///
/// Les nombres sont gros-boutistes, toute la spécification l'est
/// (`docs/interop/qcow2.txt` de QEMU).
public final class Qcow2Image: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notQcow2
        case unsupportedVersion(UInt32)
        case encrypted
        case backingFile
        case externalDataFile
        case markedCorrupt
        case zstdCompression
        case extendedL2
        case unknownFeatures(UInt64)
        /// Un champ de l'en-tête ou une table qui ne tient pas debout.
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notQcow2: return "ce fichier n'est pas un qcow2."
            case .unsupportedVersion(let version):
                return "qcow2 version \(version) : wisq lit les versions 2 et 3."
            case .encrypted: return "l'image qcow2 est chiffrée."
            case .backingFile:
                return "l'image qcow2 s'appuie sur un fichier de base, que wisq n'a pas."
            case .externalDataFile:
                return "l'image qcow2 range ses données dans un fichier externe."
            case .markedCorrupt: return "l'image qcow2 est marquée corrompue."
            case .zstdCompression:
                return "l'image qcow2 est compressée en zstd ; wisq lit le deflate."
            case .extendedL2: return "l'image qcow2 emploie des tables L2 étendues."
            case .unknownFeatures(let bits):
                return "l'image qcow2 demande des fonctionnalités inconnues (0x\(String(bits, radix: 16)))."
            case .malformed(let what): return "l'image qcow2 est mal formée : \(what)."
            }
        }
    }

    /// La taille du disque que voit l'invité — pas celle du fichier.
    public let virtualSize: UInt64
    public let clusterSize: Int
    private let clusterBits: Int
    private let l2Bits: Int
    private let l1: [UInt64]
    private let fd: Int32
    private let fileSize: UInt64

    /// Les tables L2 déjà lues, par décalage dans le fichier. Une table fait
    /// un cluster (64 Kio par défaut) et couvre 512 Mio de disque : une
    /// poignée suffit à tout ce qu'un démarrage touche.
    private var l2Cache: [UInt64: [UInt64]] = [:]
    private var l2Order: [UInt64] = []
    private static let l2CacheLimit = 64
    /// Le dernier cluster décompressé : l'invité lit souvent un cluster de
    /// 64 Kio par blocs de 4 Kio, et le décompresser seize fois serait seize
    /// fois trop.
    private var lastCompressed: (entry: UInt64, bytes: [UInt8])?
    private let lock = NSLock()

    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62
    private static let zeroFlag: UInt64 = 1

    /// Ouvre `url` en lecture seule.
    public convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.malformed("le fichier n'a pas pu être ouvert") }
        do { try self.init(takingOwnershipOf: fd) } catch { close(fd); throw error }
    }

    /// Lit l'en-tête de `fd`, qui appartient ensuite à l'image.
    public init(takingOwnershipOf fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let fileSize = UInt64(info.st_size)
        var header = [UInt8](repeating: 0, count: 112)
        let got = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 112, 0) }
        guard got >= 72 else { throw Refusal.notQcow2 }
        func u32(_ at: Int) -> UInt32 {
            header[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ at: Int) -> UInt64 {
            header[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard Array(header[0..<4]) == [0x51, 0x46, 0x49, 0xFB] else { throw Refusal.notQcow2 }
        let version = u32(4)
        guard version == 2 || version == 3 else { throw Refusal.unsupportedVersion(version) }
        guard u64(8) == 0 else { throw Refusal.backingFile }
        guard u32(32) == 0 else { throw Refusal.encrypted }

        if version == 3 {
            guard got >= 104 else { throw Refusal.malformed("en-tête v3 tronqué") }
            let incompatible = u64(72)
            // Bit 0, « sale » : seuls les compteurs de références peuvent être
            // faux, et une lecture ne s'en sert pas. Les autres changent ce que
            // les octets veulent dire.
            if incompatible & (1 << 1) != 0 { throw Refusal.markedCorrupt }
            if incompatible & (1 << 2) != 0 { throw Refusal.externalDataFile }
            if incompatible & (1 << 4) != 0 { throw Refusal.extendedL2 }
            if incompatible & (1 << 3) != 0 {
                let headerLength = u32(100)
                guard headerLength > 104, got > 104 else {
                    throw Refusal.malformed("type de compression annoncé mais absent")
                }
                if header[104] != 0 { throw Refusal.zstdCompression }
            }
            let known: UInt64 = 0b1_1111
            if incompatible & ~known != 0 { throw Refusal.unknownFeatures(incompatible & ~known) }
        }

        let clusterBits = Int(u32(20))
        guard (9...21).contains(clusterBits) else {
            throw Refusal.malformed("taille de cluster de 2^\(clusterBits) octets")
        }
        let virtualSize = u64(24)
        guard virtualSize >= 512 else { throw Refusal.malformed("disque de moins d'un secteur") }
        let l2Bits = clusterBits - 3
        let l1Size = Int(u32(36))
        let l1Offset = u64(40)
        let perL1 = UInt64(1) << UInt64(clusterBits + l2Bits)
        let needed = (virtualSize + perL1 - 1) / perL1
        guard UInt64(l1Size) >= needed else {
            throw Refusal.malformed("table L1 trop courte pour la taille annoncée")
        }
        // Une table L1 plus grande que le fichier ne peut pas exister : la
        // borne protège l'allocation qui suit d'un en-tête hostile.
        guard UInt64(l1Size) * 8 <= fileSize, l1Offset <= fileSize - UInt64(l1Size) * 8 else {
            throw Refusal.malformed("table L1 hors du fichier")
        }
        var raw = [UInt8](repeating: 0, count: l1Size * 8)
        if l1Size > 0 {
            guard VirtualDiskImages.readAll(fd, into: &raw, at: off_t(l1Offset)) else {
                throw Refusal.malformed("table L1 illisible")
            }
        }
        var l1 = [UInt64](repeating: 0, count: l1Size)
        for index in 0..<l1Size {
            l1[index] = raw[(index * 8)..<(index * 8 + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }

        self.fd = fd
        self.fileSize = fileSize
        self.virtualSize = virtualSize
        self.clusterBits = clusterBits
        self.clusterSize = 1 << clusterBits
        self.l2Bits = l2Bits
        self.l1 = l1
    }

    deinit { close(fd) }

    /// Remplit `buffer` avec les octets du disque à partir de `offset`. Faux si
    /// la lecture déborde du disque ou si le fichier ne rend pas ce que ses
    /// tables promettent.
    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        lock.lock()
        defer { lock.unlock() }
        var done = 0
        var at = offset
        while done < buffer.count {
            let within = Int(at & UInt64(clusterSize - 1))
            let take = min(buffer.count - done, clusterSize - within)
            guard let entry = l2Entry(for: at) else { return false }
            if entry & Self.compressedFlag != 0 {
                guard let cluster = decompressed(entry) else { return false }
                buffer.replaceSubrange(done..<(done + take), with: cluster[within..<(within + take)])
            } else {
                let host = entry & Self.offsetMask
                if host == 0 || entry & Self.zeroFlag != 0 {
                    // Non alloué, ou marqué zéro : sans fichier de base, les
                    // deux se lisent comme des zéros.
                    for index in done..<(done + take) { buffer[index] = 0 }
                } else {
                    var piece = [UInt8](repeating: 0, count: take)
                    let from = off_t(host) + off_t(within)
                    guard VirtualDiskImages.readAll(fd, into: &piece, at: from) else { return false }
                    buffer.replaceSubrange(done..<(done + take), with: piece)
                }
            }
            done += take
            at += UInt64(take)
        }
        return true
    }

    /// L'entrée L2 du cluster qui contient `offset` ; `0` quand rien n'est
    /// alloué, `nil` quand une table est illisible.
    private func l2Entry(for offset: UInt64) -> UInt64? {
        let clusterIndex = offset >> UInt64(clusterBits)
        let l1Index = Int(clusterIndex >> UInt64(l2Bits))
        let l2Index = Int(clusterIndex & ((1 << UInt64(l2Bits)) - 1))
        guard l1Index < l1.count else { return nil }
        let tableOffset = l1[l1Index] & Self.offsetMask
        if tableOffset == 0 { return 0 }
        if let table = l2Cache[tableOffset] { return table[l2Index] }
        var raw = [UInt8](repeating: 0, count: clusterSize)
        guard VirtualDiskImages.readAll(fd, into: &raw, at: off_t(tableOffset)) else { return nil }
        var table = [UInt64](repeating: 0, count: clusterSize / 8)
        for index in 0..<table.count {
            table[index] = raw[(index * 8)..<(index * 8 + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        l2Cache[tableOffset] = table
        l2Order.append(tableOffset)
        if l2Order.count > Self.l2CacheLimit { l2Cache[l2Order.removeFirst()] = nil }
        return table[l2Index]
    }

    /// Le cluster que décrit une entrée compressée, décompressé.
    ///
    /// L'entrée porte, sous le bit 62, le décalage des données compressées et
    /// le nombre de secteurs de 512 octets qu'elles touchent, moins un ; la
    /// frontière entre les deux champs dépend de la taille de cluster.
    private func decompressed(_ entry: UInt64) -> [UInt8]? {
        if let last = lastCompressed, last.entry == entry { return last.bytes }
        let split = UInt64(62 - (clusterBits - 8))
        let host = entry & ((1 << split) - 1)
        let sectors = ((entry >> split) & ((1 << UInt64(clusterBits - 8)) - 1)) + 1
        // Le nombre de secteurs est compté depuis le début du secteur où les
        // données commencent : c'est une borne supérieure, pas une longueur.
        let upperBound = sectors * 512 - (host & 511)
        guard host < fileSize else { return nil }
        let length = Int(min(upperBound, fileSize - host))
        var input = [UInt8](repeating: 0, count: length)
        guard VirtualDiskImages.readAll(fd, into: &input, at: off_t(host)) else { return nil }
        guard let bytes = Self.inflateRaw(input, expected: clusterSize) else { return nil }
        lastCompressed = (entry, bytes)
        return bytes
    }

    /// Deflate brut, sans en-tête zlib : c'est ce qu'écrit QEMU. La sortie doit
    /// faire exactement un cluster ; les octets de bourrage après la fin du
    /// flux sont ignorés, ce que la borne supérieure ci-dessus rend inévitable.
    static func inflateRaw(_ input: [UInt8], expected: Int) -> [UInt8]? {
        Inflate.raw(input, limit: expected, exact: true)
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    /// Le fichier commence-t-il comme un qcow2 ? Sans rien valider d'autre :
    /// c'est la question que pose `FileDiskStore` pour choisir son lecteur.
    public static func looksLikeOne(fd: Int32) -> Bool {
        var magic = [UInt8](repeating: 0, count: 4)
        let got = magic.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 4, 0) }
        return got == 4 && magic == [0x51, 0x46, 0x49, 0xFB]
    }
}
