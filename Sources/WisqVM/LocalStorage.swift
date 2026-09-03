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
/// It grew a great deal more interesting the moment memory became adjustable:
/// a saved machine is at most as large as the RAM it was taken from, so a
/// kernel set to a gibibyte can leave behind a file a hundred times the size
/// of the kernel itself. Zeros are folded, so an idle guest costs far less
/// than that — but nothing said how much, and a number nobody can see is a
/// number nobody can act on.
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

        public var total: Int { kernelBytes + savedMachineBytes }

        public init(
            kernel: String, kernelBytes: Int, savedMachineBytes: Int, savedMachineCount: Int
        ) {
            self.kernel = kernel
            self.kernelBytes = kernelBytes
            self.savedMachineBytes = savedMachineBytes
            self.savedMachineCount = savedMachineCount
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

        /// Nothing at all — what a first launch has, and what a view can hold
        /// before it has looked.
        public static let empty = Report(entries: [], orphanedBytes: 0, orphanedCount: 0)

        public init(entries: [Entry], orphanedBytes: Int, orphanedCount: Int) {
            self.entries = entries
            self.orphanedBytes = orphanedBytes
            self.orphanedCount = orphanedCount
        }

        /// The entry for one kernel, or nil when the library has none.
        public func entry(forKernel kernel: String) -> Entry? {
            entries.first { $0.kernel == kernel }
        }

        public var total: Int { entries.reduce(orphanedBytes) { $0 + $1.total } }
        public var savedMachineBytes: Int {
            entries.reduce(orphanedBytes) { $0 + $1.savedMachineBytes }
        }
    }

    /// Adds up what is on disk. Reads no file's contents — only their sizes.
    public static func report(kernels: URL, machines: URL) -> Report {
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
                    savedMachineCount: files.count))
        }

        let orphans = SuspendedMachine.allSavedMachineFiles(in: machines)
            .filter { !claimed.contains($0) }
        return Report(
            entries: entries.sorted {
                $0.total == $1.total ? $0.kernel < $1.kernel : $0.total > $1.total
            },
            orphanedBytes: orphans.reduce(0) { $0 + size(of: machines.appendingPathComponent($1)) },
            orphanedCount: orphans.count)
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
