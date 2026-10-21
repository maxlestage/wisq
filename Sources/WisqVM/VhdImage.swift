import Foundation

/// Un VHD **dynamique** — Virtual PC, les anciens Hyper-V, Azure —, lu sur
/// place, sans conversion.
///
/// Le VHD *fixe* n'a pas besoin de ce type : c'est un disque brut suivi d'un
/// pied de 512 octets, et il se branche déjà tel quel. Le dynamique, lui,
/// range le disque par blocs.
///
/// **Le format**, relevé sur de vrais fichiers de `qemu-img` : un pied de
/// 512 octets en tête (`conectix`, recopié à la fin du fichier), qui donne la
/// taille du disque et l'adresse de l'en-tête dynamique (`cxsparse`) ; celui-ci
/// donne la table des blocs et leur taille (2 Mio d'ordinaire). Chaque entrée
/// de la table, sur 32 bits, est le **secteur** où commence le bloc dans le
/// fichier, ou `0xFFFFFFFF` s'il n'a jamais été écrit. Un bloc commence par la
/// carte de ses secteurs — un bit par secteur, le premier dans le bit fort —,
/// puis ses données. Un secteur dont le bit est à zéro se lit en zéros : c'est
/// la règle du format, même si `qemu-img` met tous les bits à un. Les nombres
/// sont gros-boutistes, et le pied comme l'en-tête portent une somme de
/// contrôle, vérifiée ici.
///
/// **Ce qu'il refuse, en le nommant** : le disque différentiel (`type 4`), qui
/// ne contient que ce qui a changé depuis son parent ; une somme de contrôle
/// fausse ; un en-tête ou une table qui ne tient pas debout.
///
/// Lecture seule : les écritures de l'invité vont dans la couche de
/// `FileDiskStore`, et le fichier reste celui qui a été apporté.
public final class VhdImage: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notVhd
        /// Un disque différentiel, qui ne se lit qu'avec son parent.
        case differencing
        /// La somme de contrôle du pied ou de l'en-tête dynamique.
        case badChecksum(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notVhd: return "ce fichier n'est pas un VHD dynamique."
            case .differencing:
                return "le VHD est un disque différentiel, qui ne se lit qu'avec le disque dont il dépend."
            case .badChecksum(let what): return "la somme de contrôle \(what) du VHD est fausse."
            case .malformed(let what): return "le VHD est mal formé : \(what)."
            }
        }
    }

    static let footerMark = Array("conectix".utf8)
    static let headerMark = Array("cxsparse".utf8)
    static let unallocated: UInt32 = 0xFFFF_FFFF

    public let virtualSize: UInt64
    public let blockSize: Int
    /// La carte des secteurs en tête de chaque bloc, arrondie au secteur.
    private let bitmapSize: Int
    private let blocks: [UInt32]
    private let fd: Int32
    private let fileSize: UInt64

    /// Le fichier commence-t-il comme un VHD dynamique ? Le fixe, qui ne
    /// porte son pied qu'à la fin, n'en est pas un ici.
    static func looksLikeOne(fd: Int32) -> Bool {
        var head = [UInt8](repeating: 0, count: 8)
        let got = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 8, 0) }
        return got == 8 && head == footerMark
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    /// La somme du format : le complément à un de la somme des octets, le
    /// champ de la somme lui-même compté à zéro.
    static func checksum(_ bytes: [UInt8], skipping field: Int) -> UInt32 {
        var sum: UInt32 = 0
        for (index, byte) in bytes.enumerated() where !(field..<(field + 4)).contains(index) {
            sum &+= UInt32(byte)
        }
        return ~sum
    }

    /// Ouvre `url` en lecture seule.
    public convenience init(contentsOf url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.malformed("le fichier n'a pas pu être ouvert") }
        do { try self.init(takingOwnershipOf: fd) } catch { close(fd); throw error }
    }

    /// Lit le pied, l'en-tête dynamique et la table de `fd`, qui appartient
    /// ensuite à l'image.
    public init(takingOwnershipOf fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let fileSize = UInt64(max(info.st_size, 0))
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
            bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }

        var footer = [UInt8](repeating: 0, count: 512)
        guard VirtualDiskImages.readAll(fd, into: &footer, at: 0),
              Array(footer[0..<8]) == Self.footerMark else { throw Refusal.notVhd }
        guard u32(footer, 64) == Self.checksum(footer, skipping: 64) else {
            throw Refusal.badChecksum("du pied")
        }
        // 2 : fixe — il n'a pas de pied en tête et ne vient pas ici ; 3 :
        // dynamique ; 4 : différentiel.
        let kind = u32(footer, 60)
        if kind == 4 { throw Refusal.differencing }
        guard kind == 3 else { throw Refusal.malformed("type de disque \(kind)") }
        let virtualSize = u64(footer, 48)
        guard virtualSize >= 512 else { throw Refusal.malformed("disque de moins d'un secteur") }

        let headerOffset = u64(footer, 16)
        guard headerOffset >= 512, headerOffset &+ 1024 <= fileSize else {
            throw Refusal.malformed("en-tête dynamique hors du fichier")
        }
        var header = [UInt8](repeating: 0, count: 1024)
        guard VirtualDiskImages.readAll(fd, into: &header, at: off_t(headerOffset)),
              Array(header[0..<8]) == Self.headerMark else {
            throw Refusal.malformed("en-tête dynamique absent")
        }
        guard u32(header, 36) == Self.checksum(header, skipping: 36) else {
            throw Refusal.badChecksum("de l'en-tête dynamique")
        }
        let tableOffset = u64(header, 16)
        let entries = UInt64(u32(header, 28))
        let blockSize = UInt64(u32(header, 32))
        guard blockSize >= 512, blockSize % 512 == 0, blockSize <= 1 << 30 else {
            throw Refusal.malformed("bloc de \(blockSize) octets")
        }
        // La table couvre au moins le disque, et la borne passe avant
        // l'allocation.
        guard entries >= (virtualSize + blockSize - 1) / blockSize, entries <= 1 << 24 else {
            throw Refusal.malformed("\(entries) blocs pour \(virtualSize) octets")
        }
        guard tableOffset >= 512, tableOffset &+ entries * 4 <= fileSize else {
            throw Refusal.malformed("table de blocs hors du fichier")
        }
        var table = [UInt8](repeating: 0, count: Int(entries) * 4)
        guard VirtualDiskImages.readAll(fd, into: &table, at: off_t(tableOffset)) else {
            throw Refusal.malformed("table de blocs illisible")
        }
        blocks = (0..<Int(entries)).map { u32(table, $0 * 4) }
        // Un bit par secteur, arrondi au secteur entier.
        let sectors = Int(blockSize / 512)
        bitmapSize = ((sectors + 7) / 8 + 511) / 512 * 512
        self.fd = fd
        self.fileSize = fileSize
        self.virtualSize = virtualSize
        self.blockSize = Int(blockSize)
    }

    deinit { close(fd) }

    /// Bloc par bloc, et dans chaque bloc, les secteurs que sa carte dit
    /// écrits : les autres restent à zéro.
    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        let size = UInt64(blockSize)
        var done = 0
        while done < buffer.count {
            let position = offset + UInt64(done)
            let index = Int(position / size)
            let within = Int(position % size)
            let length = min(buffer.count - done, blockSize - within)
            let entry = blocks[index]
            if entry == Self.unallocated {
                buffer.withUnsafeMutableBytes { raw in
                    _ = memset(raw.baseAddress! + done, 0, length)
                }
            } else {
                let start = UInt64(entry) * 512
                guard start + UInt64(bitmapSize) + size <= fileSize else { return false }
                var bitmap = [UInt8](repeating: 0, count: bitmapSize)
                var chunk = [UInt8](repeating: 0, count: length)
                guard VirtualDiskImages.readAll(fd, into: &bitmap, at: off_t(start)),
                      VirtualDiskImages.readAll(fd, into: &chunk,
                                                at: off_t(start + UInt64(bitmapSize) + UInt64(within)))
                else { return false }
                // Les secteurs que la carte dit jamais écrits : des zéros,
                // quoi que le fichier porte à leur place.
                var sector = within / 512
                while sector * 512 < within + length {
                    if bitmap[sector / 8] & (0x80 >> UInt8(sector % 8)) == 0 {
                        let from = max(sector * 512, within) - within
                        let to = min((sector + 1) * 512, within + length) - within
                        for byte in from..<to { chunk[byte] = 0 }
                    }
                    sector += 1
                }
                buffer.replaceSubrange(done..<(done + length), with: chunk)
            }
            done += length
        }
        return true
    }
}
