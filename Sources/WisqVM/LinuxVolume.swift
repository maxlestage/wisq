/// **Un système de fichiers où un noyau Linux peut vivre**, lu en lecture
/// seule : ce que `CloudBoot` demande à une partition, qu'elle soit en ext4
/// (Debian, Ubuntu, Alpine), en btrfs (Fedora) ou en XFS (openSUSE, la
/// famille de Red Hat).
public protocol LinuxVolume: AnyObject {
    /// Le contenu du fichier au bout de `path`, liens suivis.
    func contents(of path: String) throws -> [UInt8]
    /// Les noms et les genres des entrées du répertoire au bout de `path`.
    func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)]
    /// Vrai si `path` mène à quelque chose.
    func exists(_ path: String) -> Bool
}

extension Ext4Volume: LinuxVolume {
    public func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)] {
        try list(path).map { ($0.name, $0.kind) }
    }
}

extension BtrfsVolume: LinuxVolume {
    public func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)] {
        try list(path).map { ($0.name, $0.kind) }
    }
}

extension XfsVolume: LinuxVolume {
    public func listing(_ path: String) throws -> [(name: String, kind: Ext4Volume.EntryKind)] {
        try list(path).map { ($0.name, $0.kind) }
    }
}

/// Le système de fichiers d'une partition : ext, puis btrfs, puis XFS. Aucun
/// des trois, et l'erreur est celle d'ext4 ; un XFS reconnu mais refusé — une
/// fonction inconnue — rend la sienne, qui dit pourquoi.
func linuxVolume(_ partition: PartitionTable.Partition, in image: any VirtualDiskImage) throws -> any LinuxVolume {
    do {
        return try Ext4Volume(partition, in: image)
    } catch {
        if let btrfs = try? BtrfsVolume(partition, in: image) { return btrfs }
        do {
            return try XfsVolume(partition, in: image)
        } catch XfsVolume.Failure.notXfs {
            throw error
        }
    }
}
