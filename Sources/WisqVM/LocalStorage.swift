import Foundation

/// What the local Linux feature occupies on the phone, and how to get it back.
///
/// There is no virtual disk in this machine and there is not going to be one:
/// the rv32 nommu kernels it runs have no block driver, and a snapshot of the
/// whole machine does the job a disk would have done. So "storage" here is not
/// a size to give a guest — it is the space **kernels and saved machines**
/// take in the app's own storage, which is real, grows on its own, and until
/// now was invisible.
///
/// **What a saved machine costs follows what the guest touched, not what it
/// was given.** Measured on the real kernel, at the login prompt:
///
///     machine   après 5 M instr.   après 65 M (invite de connexion)
///      64 Mio        8,9 Mio                16,4 Mio
///     128 Mio        9,5 Mio                17,0 Mio
///     256 Mio       10,5 Mio                18,4 Mio
///
/// Quadrupling the machine adds two mebibytes, because Linux does not touch
/// memory it has no use for and the runs of zeros are folded. Spending ten
/// times the instructions nearly doubles it, because that is memory the guest
/// actually wrote.
///
/// That is the opposite of what this file first claimed — that a kernel set to
/// a gibibyte could leave behind a file a hundred times its own size. It
/// cannot; `ResizedSnapshotCostTests` now holds the real shape, so a change
/// that broke the zero-folding would be caught rather than quietly filling
/// someone's phone.
///
/// Seventeen mebibytes per suspended kernel is still worth showing: five
/// kernels left suspended is eighty-five, appearing without anyone asking for
/// it, and a number nobody can see is a number nobody can act on.
///
/// In `WisqVM` rather than the app layer, for the reason `SuspendedMachine`
/// gives: the app only builds on Apple platforms, and "walk two directories
/// and add up what is there" is worth testing rather than reasoning about.
public enum LocalStorage {
    /// One kernel, and everything the app keeps because of it.
    public struct Entry: Equatable, Sendable {
        /// The kernel's file name, which is what the list shows.
        public let kernel: String
        /// The image itself.
        public let kernelBytes: Int
        /// Every machine saved from it. Plural: the same name can have been
        /// several different files over time, each with its own snapshot.
        public let savedMachineBytes: Int
        /// How many such machines there are, so a gesture can say what it
        /// would remove before removing it.
        public let savedMachineCount: Int
        /// What guests wrote on this file when it served as a disk: the
        /// overlay's allocated blocks, not its apparent size. Zero for a
        /// kernel, and for a disk nobody has written to.
        public let diskWritesBytes: Int

        public var total: Int { kernelBytes + savedMachineBytes + diskWritesBytes }

        public init(
            kernel: String, kernelBytes: Int, savedMachineBytes: Int, savedMachineCount: Int,
            diskWritesBytes: Int = 0
        ) {
            self.kernel = kernel
            self.kernelBytes = kernelBytes
            self.savedMachineBytes = savedMachineBytes
            self.savedMachineCount = savedMachineCount
            self.diskWritesBytes = diskWritesBytes
        }
    }

    /// What everything adds up to.
    public struct Report: Equatable, Sendable {
        /// Largest first: what a person looking to free space wants at the top.
        public let entries: [Entry]
        /// Machines saved from a kernel that is no longer in the library.
        ///
        /// Dead weight by construction — a snapshot cannot be restored without
        /// the kernel it was taken from — and it existed because deleting a
        /// kernel used to remove the file and nothing else. It does not any
        /// more, so this only holds what earlier versions left behind; it is
        /// reported rather than swept silently, because deleting someone's
        /// files without saying so is not better for being correct.
        public let orphanedBytes: Int
        public let orphanedCount: Int

        /// Ce qu'une image d'installation a laissé déballé.
        ///
        /// Un noyau et un initramfs sortis de l'ISO au dernier démarrage. Ils
        /// ne sont sous aucune entrée, et ce n'est pas un oubli : le dossier
        /// est partagé, le démarrage suivant le refait à neuf pour une autre
        /// image, et rien dedans ne dit de laquelle il vient. L'attribuer à un
        /// noyau serait une attribution inventée.
        ///
        /// Ils étaient invisibles jusqu'ici, et une image qu'on supprimait les
        /// laissait derrière elle : des dizaines de mébioctets que le relevé
        /// ne montrait pas et qu'aucun geste ne pouvait reprendre.
        public let unpackedIsoBytes: Int

        /// Nothing at all — what a first launch has, and what a view can hold
        /// before it has looked.
        public static let empty = Report(entries: [], orphanedBytes: 0, orphanedCount: 0)

        public init(
            entries: [Entry], orphanedBytes: Int, orphanedCount: Int, unpackedIsoBytes: Int = 0
        ) {
            self.entries = entries
            self.orphanedBytes = orphanedBytes
            self.orphanedCount = orphanedCount
            self.unpackedIsoBytes = unpackedIsoBytes
        }

        /// The entry for one kernel, or nil when the library has none.
        public func entry(forKernel kernel: String) -> Entry? {
            entries.first { $0.kernel == kernel }
        }

        public var total: Int {
            entries.reduce(orphanedBytes + unpackedIsoBytes) { $0 + $1.total }
        }
        public var savedMachineBytes: Int {
            entries.reduce(orphanedBytes) { $0 + $1.savedMachineBytes }
        }
    }

    /// Adds up what is on disk. Reads no file's contents — only their sizes.
    ///
    /// `writes` is where the disk overlays live; nil counts none, which is
    /// what a library with no disk has.
    public static func report(
        kernels: URL, machines: URL, writes: URL? = nil, unpackedIso: URL? = nil
    ) -> Report {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: kernels.path))?.sorted() ?? []

        var entries: [Entry] = []
        var claimed = Set<String>()
        for name in names {
            let files = SuspendedMachine.savedMachineFiles(named: name, in: machines)
            claimed.formUnion(files)
            entries.append(
                Entry(
                    kernel: name,
                    kernelBytes: size(of: kernels.appendingPathComponent(name)),
                    savedMachineBytes: files.reduce(0) {
                        $0 + size(of: machines.appendingPathComponent($1))
                    },
                    savedMachineCount: files.count,
                    diskWritesBytes: writes.map { LocalDisk.overlayBytes(for: name, inWritesDirectory: $0) } ?? 0))
        }

        let orphans = SuspendedMachine.allSavedMachineFiles(in: machines)
            .filter { !claimed.contains($0) }
        return Report(
            entries: entries.sorted {
                $0.total == $1.total ? $0.kernel < $1.kernel : $0.total > $1.total
            },
            orphanedBytes: orphans.reduce(0) { $0 + size(of: machines.appendingPathComponent($1)) },
            orphanedCount: orphans.count,
            unpackedIsoBytes: bytes(inFolder: unpackedIso))
    }

    /// Removes the machines saved from kernels the library no longer holds,
    /// and answers with how much that freed.
    @discardableResult
    public static func freeOrphanedMachines(kernels: URL, machines: URL) -> Int {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: kernels.path)) ?? []
        var claimed = Set<String>()
        for name in names {
            claimed.formUnion(SuspendedMachine.savedMachineFiles(named: name, in: machines))
        }
        var freed = 0
        for file in SuspendedMachine.allSavedMachineFiles(in: machines) where !claimed.contains(file) {
            let url = machines.appendingPathComponent(file)
            freed += size(of: url)
            try? manager.removeItem(at: url)
        }
        return freed
    }

    /// Où une image d'installation est déballée, à partir du stockage que
    /// l'application connaît.
    ///
    /// **Ici et pas dans `IsoBoot`**, bien que ce soit lui qui écrive dedans.
    /// `IsoBoot` vit dans `WisqVMRust`, que ce module-ci ne voit pas, et c'est
    /// ce relevé qui doit compter le dossier. Deux littéraux « iso » dans deux
    /// modules seraient deux vérités, et celle qui compte se serait tue le
    /// jour où celle qui écrit aurait changé : `IsoBoot.folder(in:)` appelle
    /// celle-ci.
    ///
    /// `nil` veut dire « l'endroit habituel », comme partout ailleurs ici.
    public static func unpackedIsoFolder(in storage: URL?) -> URL? {
        guard let base = storage ?? (try? SuspendedMachine.directory()) else { return nil }
        return base.appendingPathComponent("iso", isDirectory: true)
    }

    /// Jette ce qu'une image a laissé déballé, et dit ce que ça a rendu.
    ///
    /// **Rien n'est perdu.** `IsoBoot.unpack` efface ce dossier avant d'écrire,
    /// à chaque démarrage d'image : il ne porte jamais que le déballage du
    /// dernier amorçage, et le prochain le refera. Ce qui part ici aurait été
    /// réécrit de toute façon.
    @discardableResult
    public static func discardUnpackedIso(_ folder: URL?) -> Int {
        guard let folder else { return 0 }
        let freed = bytes(inFolder: folder)
        try? FileManager.default.removeItem(at: folder)
        return freed
    }

    /// Ce que porte un dossier, fichier par fichier.
    ///
    /// Les dossiers eux-mêmes ne comptent pas : un répertoire a une taille sur
    /// le disque — quatre kibioctets ici, soixante-quatre octets sur APFS — et
    /// l'additionner ferait dire au relevé deux nombres différents selon la
    /// plateforme pour les mêmes fichiers.
    static func bytes(inFolder folder: URL?) -> Int {
        guard let folder,
              let walk = FileManager.default.enumerator(atPath: folder.path)
        else { return 0 }
        var total = 0
        for case let entry as String in walk {
            let url = folder.appendingPathComponent(entry)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int
            else { continue }
            total += size
        }
        return total
    }

    /// A file's size, or zero when it has none to report.
    ///
    /// Zero rather than a failure: a directory that changed under us between
    /// the listing and the measurement is an ordinary thing, and a total that
    /// is a few kilobytes short is a better answer than no total at all.
    static func size(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int
        else { return 0 }
        return size
    }

    /// A size as someone reads it, in French, with the unit that keeps the
    /// number under a thousand.
    ///
    /// Mebibytes and not megabytes, and the abbreviation says so: the whole
    /// codebase counts memory in powers of two, and a storage figure that
    /// counted in powers of ten next to a memory figure that does not would
    /// make the two impossible to compare.
    public static func describe(bytes: Int) -> String {
        let units = ["o", "Kio", "Mio", "Gio"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // Whole bytes and kibibytes read better without a decimal; a size in
        // mebibytes is where one digit starts to mean something.
        let digits = unit >= 2 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[unit])
            .replacingOccurrences(of: ".", with: ",")
    }
}
