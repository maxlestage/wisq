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
    public static func image(takingOwnershipOf fd: Int32) throws -> (any VirtualDiskImage)? {
        if Qcow2Image.looksLikeOne(fd: fd) { return try Qcow2Image(takingOwnershipOf: fd) }
        if VmdkImage.looksLikeOne(fd: fd) { return try VmdkImage(takingOwnershipOf: fd) }
        return nil
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
