import Foundation

/// **Un disque vu à travers sa couche d'écriture**, lu comme une image.
///
/// Ce que l'invité écrit sur un disque ne va jamais dans le fichier : il va
/// dans la couche à côté (`FileDiskStore`). Ce qu'un installateur a posé sur
/// un disque vierge n'existe donc que là, et c'est à travers elle qu'il faut
/// le lire.
public final class DiskStoreImage: VirtualDiskImage, @unchecked Sendable {
    private let store: DiskStore

    public init(_ store: DiskStore) {
        self.store = store
    }

    public var virtualSize: UInt64 { store.sectors &* UInt64(FileDiskStore.sectorSize) }

    public func read(into buffer: inout [UInt8], at offset: UInt64) -> Bool {
        guard let bytes = store.read(at: offset, count: buffer.count), bytes.count == buffer.count
        else { return false }
        buffer = bytes
        return true
    }
}

/// **Le système qu'un installateur a écrit sur le disque d'une machine.**
///
/// Une machine installée démarrait toujours son image d'installation, le
/// disque qu'on lui avait donné en second. Une fois l'installateur passé, le
/// système était bien sur ce disque, mais rien ne le démarrait : la machine
/// revenait à l'image, comme un PC dont le CD resterait en tête de l'ordre de
/// démarrage.
///
/// Ce qui le démarre est ce qui démarre une image de cloud (`CloudBoot`) : le
/// `grub.cfg`, les entrées BLS, ou le noyau le plus récent de `/boot`, lus
/// cette fois à travers la couche d'écriture.
public enum InstalledSystem {
    /// De quoi démarrer le système installé sur `disk`, vu à travers la
    /// couche `writes` ; `nil` quand rien n'y démarre — disque jamais écrit,
    /// installateur qui n'a pas fini, ou disque sans Linux.
    ///
    /// **Une couche absente n'est pas créée.** Ouvrir un `FileDiskStore` la
    /// fabrique ; la question « y a-t-il un système ? » ne doit rien écrire,
    /// et un disque qui n'a pas de couche n'a rien reçu de l'invité.
    public static func find(disk: URL, writes: URL) -> CloudBoot? {
        let files = FileManager.default
        guard files.fileExists(atPath: writes.path), files.fileExists(atPath: writes.path + ".map"),
              let store = try? FileDiskStore(base: disk, writes: writes)
        else { return nil }
        return try? CloudBoot.find(in: DiskStoreImage(store), rootHash: nil)
    }

    /// Le même, déballé dans `folder` comme une image de cloud : noyau et
    /// initramfs sous leurs noms fixes, et la ligne de commande qui va avec.
    /// `nil` quand rien n'y démarre ; la machine démarre alors son image.
    public static func unpack(disk: URL, writes: URL, into folder: URL,
                              ceiling: UInt64 = .max) -> Result<CloudBoot.Unpacked, CloudBoot.Refusal>? {
        guard let found = find(disk: disk, writes: writes) else { return nil }
        return CloudBoot.write(found, into: folder, ceiling: ceiling)
    }
}
