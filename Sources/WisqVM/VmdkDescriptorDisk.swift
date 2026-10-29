import Foundation

/// Un disque VMDK décrit par un **descripteur à part** : un petit fichier de
/// texte qui nomme les fichiers où sont les octets, et ces fichiers à côté.
///
/// **Pourquoi ce type existe.** C'est la forme que prennent la plupart des
/// disques de VMware qui ne sont pas des appliances. ESXi range chaque disque
/// en deux fichiers, `disque.vmdk` et `disque-flat.vmdk` (`vmfs`) ;
/// Workstation et Fusion découpent par défaut un disque en morceaux de 2 Gio
/// (`twoGbMaxExtentSparse`), et `qemu-img` écrit les mêmes formes. Le
/// descripteur seul n'est pas un disque — c'est pourquoi `VmdkImage` le
/// refuse —, mais avec ses fichiers, il en est un, et se lit sur place.
///
/// **Ce qu'il lit.** Les lignes d'étendue du descripteur, dans l'ordre, mises
/// bout à bout : `FLAT` et `VMFS` (des octets bruts, à partir d'un décalage
/// dans leur fichier), `SPARSE` (un fichier « sparse » sans descripteur, lu
/// par `VmdkImage`), et `ZERO` (des zéros, sans fichier).
///
/// **Ce qu'il refuse, en le nommant** : un disque différentiel (`parentCID`),
/// une étendue d'un type qu'il ne lit pas — l'instantané d'ESXi
/// (`VMFSSPARSE`, `SESPARSE`), un disque physique (`VMFSRDM`, `VMFSRAW`) —,
/// une étendue inaccessible (`NOACCESS`), un fichier qui manque ou qui est
/// plus court que ce que le descripteur en dit, et un nom de fichier qui
/// sortirait du dossier du descripteur. Les fichiers nommés sont cherchés à
/// côté de lui, et nulle part ailleurs : un descripteur téléchargé ne doit
/// pas pouvoir faire lire `/etc/passwd` à l'invité.
public final class VmdkDescriptorDisk: VirtualDiskImage, @unchecked Sendable {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notADescriptor
        case parentDisk
        /// Une étendue d'un type que wisq ne lit pas, nommé.
        case unsupportedExtent(String)
        /// Le fichier qu'une étendue nomme n'est pas à côté du descripteur.
        case missingFile(String)
        /// Un nom qui désigne un fichier ailleurs que dans le dossier.
        case fileOutsideFolder(String)
        /// Le descripteur, ou une étendue, ne tient pas debout.
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notADescriptor: return "ce fichier n'est pas un descripteur VMDK."
            case .parentDisk:
                return "ce VMDK est un disque différentiel qui s'appuie sur un parent, que wisq n'a pas."
            case .unsupportedExtent(let kind):
                return "ce VMDK a une étendue \(kind), que wisq ne lit pas ; il lit FLAT, VMFS, SPARSE et ZERO."
            case .missingFile(let name):
                return "il manque \(name) à côté du descripteur : un VMDK de ce type est fait de plusieurs fichiers."
            case .fileOutsideFolder(let name):
                return "le descripteur nomme \(name), hors de son dossier ; wisq ne lit que les fichiers à côté de lui."
            case .malformed(let what): return "le descripteur VMDK est mal formé : \(what)."
            }
        }
    }

    /// Une ligne d'étendue : `RW 4192256 SPARSE "disque-s001.vmdk"`.
    public struct Extent: Equatable, Sendable {
        public let access: String
        public let sectors: UInt64
        public let kind: String
        public let file: String?
        /// Le décalage dans le fichier, en secteurs : seules les étendues
        /// brutes en ont un.
        public let offset: UInt64
    }

    /// Les étendues, dans l'ordre du descripteur, et le premier octet du
    /// disque que chacune porte.
    private let pieces: [(start: UInt64, extent: Extent, image: (any VirtualDiskImage)?)]
    public let virtualSize: UInt64
    public let extents: [Extent]

    /// Le texte du descripteur ne dépasse jamais quelques kibioctets ; au-delà,
    /// ce n'en est pas un.
    static let largestDescriptor = 1 << 16
    static let signature = Array("# Disk DescriptorFile".utf8)

    /// Ouvre le descripteur `url` et les fichiers qu'il nomme, à côté de lui.
    public init(contentsOf url: URL) throws {
        guard let text = Self.descriptorText(at: url) else { throw Refusal.notADescriptor }
        let fields = VmdkImage.descriptorFields(Array(text.utf8))
        if let parent = fields["parentCID"], parent.lowercased() != "ffffffff" {
            throw Refusal.parentDisk
        }
        let extents = try Self.extents(text)
        guard !extents.isEmpty else { throw Refusal.malformed("aucune étendue") }
        let folder = url.deletingLastPathComponent()
        var pieces: [(start: UInt64, extent: Extent, image: (any VirtualDiskImage)?)] = []
        var start: UInt64 = 0
        for extent in extents {
            pieces.append((start, extent, try Self.openExtent(extent, in: folder)))
            guard extent.sectors <= (UInt64.max - start) / 512 else {
                throw Refusal.malformed("taille hors de portée")
            }
            start += extent.sectors * 512
        }
        self.pieces = pieces
        self.extents = extents
        virtualSize = start
    }

    /// L'image qui porte les octets d'une étendue ; `nil` pour `ZERO`.
    private static func openExtent(_ extent: Extent, in folder: URL) throws -> (any VirtualDiskImage)? {
        if extent.access == "NOACCESS" { throw Refusal.unsupportedExtent("NOACCESS") }
        switch extent.kind {
        case "ZERO": return nil
        case "FLAT", "VMFS", "SPARSE": break
        default: throw Refusal.unsupportedExtent(extent.kind)
        }
        guard let name = extent.file, !name.isEmpty else {
            throw Refusal.malformed("étendue \(extent.kind) sans fichier")
        }
        // **À côté, et nulle part ailleurs** : ni chemin, ni `..`.
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw Refusal.fileOutsideFolder(name)
        }
        let url = folder.appendingPathComponent(name)
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Refusal.missingFile(name) }
        if extent.kind == "SPARSE" {
            let image: VmdkImage
            do {
                image = try VmdkImage(takingOwnershipOf: fd, extent: true)
            } catch {
                close(fd)
                throw error
            }
            // Un morceau qui ne porte pas ce que le descripteur annonce
            // décalerait tout le disque qui le suit.
            guard image.virtualSize == extent.sectors * 512 else {
                throw Refusal.malformed("\(name) porte \(image.virtualSize / 512) secteurs, "
                    + "le descripteur en annonce \(extent.sectors)")
            }
            return image
        }
        let raw = RawDiskImage(takingOwnershipOf: fd)
        guard extent.offset <= raw.virtualSize / 512,
              extent.sectors <= raw.virtualSize / 512 - extent.offset
        else {
            throw Refusal.malformed("\(name) est plus court que l'étendue qu'il porte")
        }
        return OffsetDiskImage(raw, offset: extent.offset * 512, size: extent.sectors * 512)
    }

    /// Le texte du descripteur, s'il en est un : la signature en tête, et
    /// rien qui ne soit du texte avant la fin — `qemu-img` complète d'espaces,
    /// d'autres de zéros.
    static func descriptorText(at url: URL) -> String? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return descriptorText(fd: fd)
    }

    static func descriptorText(fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= off_t(signature.count),
              info.st_size <= off_t(largestDescriptor)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard VirtualDiskImages.readAll(fd, into: &bytes, at: 0),
              Array(bytes[0..<signature.count]) == signature
        else { return nil }
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(bytes: bytes[0..<end], encoding: .utf8)
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func looksLikeOne(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return looksLikeOne(fd: fd)
    }

    /// Le fichier commence-t-il comme un descripteur VMDK ? Sans rien valider
    /// d'autre.
    public static func looksLikeOne(fd: Int32) -> Bool {
        var bytes = [UInt8](repeating: 0, count: signature.count)
        let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, signature.count, 0) }
        return got == signature.count && bytes == signature
    }

    /// Les lignes d'étendue du descripteur, dans l'ordre.
    ///
    /// Une ligne d'étendue commence par son accès — `RW`, `RDONLY` ou
    /// `NOACCESS` —, et c'est ce qui la distingue des autres : les champs
    /// `clé=valeur` et la base de données (`ddb.…`) n'en commencent jamais
    /// par un.
    static func extents(_ text: String) throws -> [Extent] {
        var extents: [Extent] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let words = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard let access = words.first, ["RW", "RDONLY", "NOACCESS"].contains(String(access)) else {
                continue
            }
            guard words.count >= 3, let sectors = UInt64(words[1]), sectors > 0 else {
                throw Refusal.malformed("étendue illisible : « \(trimmed) »")
            }
            let kind = String(words[2])
            var file: String?
            var offset: UInt64 = 0
            if words.count == 4 {
                // Le nom est entre guillemets, et peut porter des espaces ;
                // le décalage, quand il y en a un, suit le second guillemet.
                let rest = words[3]
                guard rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") else {
                    throw Refusal.malformed("nom d'étendue sans guillemets : « \(trimmed) »")
                }
                file = String(rest[rest.index(after: rest.startIndex)..<close])
                let tail = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty {
                    guard let value = UInt64(tail) else {
                        throw Refusal.malformed("décalage illisible : « \(trimmed) »")
                    }
                    offset = value
                }
            }
            extents.append(Extent(access: String(access), sectors: sectors, kind: kind,
                                  file: file, offset: offset))
        }
        return extents
    }

    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        var done = 0
        var at = offset
        // La première étendue concernée : la dernière qui commence avant
        // `offset`. Elles sont rangées par début, et peu nombreuses.
        var index = pieces.lastIndex { $0.start <= at } ?? 0
        while done < buffer.count {
            let piece = pieces[index]
            let within = at - piece.start
            let length = piece.extent.sectors * 512
            let take = Int(min(UInt64(buffer.count - done), length - within))
            if let image = piece.image {
                var part = [UInt8](repeating: 0, count: take)
                guard image.read(into: &part, at: within) else { return false }
                buffer.replaceSubrange(done..<(done + take), with: part)
            } else {
                for byte in done..<(done + take) { buffer[byte] = 0 }
            }
            done += take
            at += UInt64(take)
            index += 1
        }
        return true
    }
}

/// Une partie d'une autre image : `size` octets à partir de `offset`. Ce
/// qu'est une étendue brute dans son fichier.
final class OffsetDiskImage: VirtualDiskImage, @unchecked Sendable {
    private let base: any VirtualDiskImage
    private let offset: UInt64
    let virtualSize: UInt64

    init(_ base: any VirtualDiskImage, offset: UInt64, size: UInt64) {
        self.base = base
        self.offset = offset
        virtualSize = size
    }

    func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= virtualSize, UInt64(buffer.count) <= virtualSize - offset else { return false }
        return base.read(into: &buffer, at: self.offset + offset)
    }
}
