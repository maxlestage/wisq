import Foundation

/// Un disque dans le format d'un autre hyperviseur, lu sur place : ce que
/// `FileDiskStore` met sous sa couche d'écriture quand la base n'est pas une
/// image brute.
///
/// Lecture seule, et c'est le contrat : les écritures de l'invité vont dans
/// la couche, jamais dans le fichier téléchargé.
public protocol VirtualDiskImage: AnyObject, Sendable {
    /// La taille du disque que voit l'invité — pas celle du fichier.
    var virtualSize: UInt64 { get }
    /// Remplit `buffer` avec les octets du disque à partir de `offset`. Faux
    /// si la lecture déborde du disque ou si le fichier ne rend pas ce que
    /// ses tables promettent.
    func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool
}

/// Les formats que wisq lit, et le choix entre eux.
public enum VirtualDiskImages {
    /// Le fichier commence-t-il comme un des formats lus ici ? Sans rien
    /// valider d'autre : c'est la question qui décide qu'une base n'est pas
    /// une image brute.
    public static func recognizes(fd: Int32) -> Bool {
        Qcow2Image.looksLikeOne(fd: fd) || VmdkImage.looksLikeOne(fd: fd)
            || OvaArchive.looksLikeOne(fd: fd) || VdiImage.looksLikeOne(fd: fd)
            || VhdImage.looksLikeOne(fd: fd) || VhdxImage.looksLikeOne(fd: fd)
            || VmdkDescriptorDisk.looksLikeOne(fd: fd)
    }

    /// Le même, pour un fichier qu'on n'a pas encore ouvert.
    public static func recognizes(fileAt url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return recognizes(fd: fd)
    }

    /// L'image que porte `fd`, qui lui appartient ensuite ; `nil` si le
    /// fichier n'est dans aucun des formats lus ici — c'est alors une image
    /// brute, et `fd` reste à l'appelant. Une image reconnue mais refusée
    /// lève le refus de son format, qui en dit la raison.
    ///
    /// `url` est le chemin de `fd`. Seul le VMDK à descripteur en a besoin :
    /// ses octets sont dans des fichiers à côté de lui, qu'il nomme.
    public static func image(takingOwnershipOf fd: Int32, at url: URL? = nil) throws -> (any VirtualDiskImage)? {
        if VmdkDescriptorDisk.looksLikeOne(fd: fd) {
            guard let url else {
                throw VmdkDescriptorDisk.Refusal.malformed("descripteur ouvert sans son chemin")
            }
            let disk = try VmdkDescriptorDisk(contentsOf: url)
            close(fd)
            return disk
        }
        if Qcow2Image.looksLikeOne(fd: fd) { return try Qcow2Image(takingOwnershipOf: fd) }
        if VmdkImage.looksLikeOne(fd: fd) { return try VmdkImage(takingOwnershipOf: fd) }
        if VdiImage.looksLikeOne(fd: fd) { return try VdiImage(takingOwnershipOf: fd) }
        if VhdImage.looksLikeOne(fd: fd) { return try VhdImage(takingOwnershipOf: fd) }
        if VhdxImage.looksLikeOne(fd: fd) { return try VhdxImage(takingOwnershipOf: fd) }
        if OvaArchive.looksLikeOne(fd: fd) {
            let disk = try OvaArchive.disk(in: fd)
            return try VmdkImage(takingOwnershipOf: fd, member: (disk.offset, disk.length))
        }
        return nil
    }

    /// Combien de blocs de `size` octets couvrent `total` octets — sans
    /// l'addition de l'arrondi habituel, `(total + size - 1) / size`, qui
    /// déborde, et fait tomber l'application, quand un en-tête hostile
    /// annonce une taille proche de 2⁶⁴.
    static func blocks(covering total: UInt64, of size: UInt64) -> UInt64 {
        total / size + (total % size == 0 ? 0 : 1)
    }

    /// `pread` jusqu'au bout : faux si le fichier finit avant.
    static func readAll(_ fd: Int32, into buffer: inout [UInt8], at offset: off_t) -> Bool {
        let wanted = buffer.count
        var done = 0
        return buffer.withUnsafeMutableBytes { raw in
            while done < wanted {
                let got = pread(fd, raw.baseAddress! + done, wanted - done, offset + off_t(done))
                if got <= 0 { return false }
                done += got
            }
            return true
        }
    }
}

/// Une image brute, octet pour octet : le disque est le fichier. Ce que
/// `FileDiskStore` lit sans intermédiaire ; ici pour qui veut lire un disque
/// sans savoir d'avance s'il est brut ou non (`VirtualDiskImages.disk`).
public final class RawDiskImage: VirtualDiskImage, @unchecked Sendable {
    private let fd: Int32
    public let virtualSize: UInt64

    /// `fd` appartient ensuite à l'image, qui le ferme.
    public init(takingOwnershipOf fd: Int32) {
        self.fd = fd
        var status = stat()
        virtualSize = fstat(fd, &status) == 0 ? UInt64(max(status.st_size, 0)) : 0
    }

    deinit { close(fd) }

    /// Faux au-delà de la fin : `readAll` le dit déjà, puisque `pread` n'y
    /// rend plus rien — un sabotage a montré qu'une garde de plus ici ne
    /// tenait rien.
    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard offset <= UInt64(off_t.max) else { return false }
        return VirtualDiskImages.readAll(fd, into: &buffer, at: off_t(offset))
    }
}

extension VirtualDiskImages {
    /// Le disque d'un fichier, quel que soit son format : un des formats lus
    /// ici, sinon l'image brute. `nil` seulement si le fichier ne s'ouvre pas.
    public static func disk(fileAt url: URL) throws -> (any VirtualDiskImage)? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        do {
            if let image = try image(takingOwnershipOf: fd, at: url) { return image }
        } catch {
            close(fd)
            throw error
        }
        return RawDiskImage(takingOwnershipOf: fd)
    }
}
