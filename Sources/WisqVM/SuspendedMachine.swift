import Foundation

/// Where a suspended machine waits between launches.
///
/// Named for what it holds rather than as a `Store`, because `WisqCore` already
/// has a `MachineStore` and that one keeps the list of remote machines. Two
/// types with one name, in one app, is a reading error waiting to happen.
///
/// This lives here rather than in the app layer on purpose. The app only builds
/// on Apple platforms, so anything living there cannot be tested on the runner
/// that costs nothing — and "write a file, read it back, survive a first launch
/// with nothing there" is worth testing rather than reasoning about.
public enum SuspendedMachine {
    /// What a saved machine belongs to: the kernel image itself, not its name.
    ///
    /// The name alone was the first answer and it is not enough. Kernel images
    /// arrive through Files, and `Image` is what almost every one of them is
    /// called — two different kernels a user imports a week apart share that
    /// name, and keying on it hands the second one the first one's machine.
    /// The bytes are what a snapshot was taken against, so the bytes are what
    /// it is filed under.
    ///
    /// The name is kept in front of the digest anyway. It is not load-bearing;
    /// it is so that a person looking in the directory can tell which file is
    /// which, which a wall of hex cannot.
    public static func identity(of image: Data, named name: String) -> String {
        "\(safeName(name))-\(String(digest(image), radix: 16))"
    }

    /// The form a kernel's own name takes inside an identity.
    ///
    /// Extracted because two things need it now: building an identity, and
    /// recognising every identity that came from one name — see `clearAll`.
    /// Two copies of a sanitising rule is the shortest road to a file that one
    /// half of the code can write and the other half cannot find.
    static func safeName(_ name: String) -> String {
        String(name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }.prefix(40))
    }

    /// FNV-1a, 64 bits, over every byte.
    ///
    /// Deliberately not SHA-256. The one in `WisqNet` returns empty `Data` on
    /// any platform without CryptoKit, which is the platform every test here
    /// runs on — every image would digest to the same nothing, the tests would
    /// pass, and the behaviour on a phone would be a different one nobody had
    /// checked. A hash that only works where it is not tested is worse than no
    /// hash.
    ///
    /// Nothing here needs to resist an adversary: the question is "is this the
    /// same file as last time", about a file the user picked themselves. What
    /// it does need is to notice a single changed byte anywhere in a few
    /// megabytes, which is what the tests pin down.
    ///
    /// It mixes no length. A first version did, on the theory that trailing
    /// zeros could make a long image digest like a short one — but FNV-1a
    /// already folds every byte in, zeros included, so appending one changes
    /// the result. Removing the step broke no test, which is what said it was
    /// doing nothing. A line kept because it sounds prudent is a line nobody
    /// can check.
    static func digest(_ image: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in image {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The file a machine with this identity waits in.
    public static func fileName(kernel: String) -> String {
        let safe = kernel.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return "machine-\(String(safe.prefix(80))).wisqvm"
    }

    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Wisq", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Saves a snapshot.
    ///
    /// `.atomic` is doing real work here, not decoration. The moment this runs
    /// is the moment iOS is taking the app away, so an interrupted write is the
    /// realistic case rather than the exotic one; Foundation writes to an
    /// auxiliary file and renames, which means the visible file is always a
    /// whole one — the previous machine if the new save never finished, never a
    /// torn mixture of the two.
    public static func save(
        _ snapshot: Data, kernel: String, in directory: URL? = nil
    ) throws {
        let folder = try directory ?? Self.directory()
        try snapshot.write(
            to: folder.appendingPathComponent(fileName(kernel: kernel)), options: .atomic
        )
    }

    /// The saved machine, or nil when there is none.
    ///
    /// An unreadable file is treated as no file rather than as an error: the
    /// only sensible response is a fresh boot, and making the caller handle a
    /// failure it can do nothing about only invites it to be ignored. What must
    /// not happen — a damaged file becoming a damaged machine — is refused by
    /// `LinuxMachine.restore`, which checks the bytes it is given.
    public static func load(kernel: String, in directory: URL? = nil) -> Data? {
        guard let folder = try? (directory ?? Self.directory()) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(fileName(kernel: kernel)))
    }

    public static func clear(kernel: String, in directory: URL? = nil) {
        guard let folder = try? (directory ?? Self.directory()) else { return }
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(fileName(kernel: kernel))
        )
    }

    public static func exists(kernel: String, in directory: URL? = nil) -> Bool {
        guard let folder = try? (directory ?? Self.directory()) else { return false }
        return FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(fileName(kernel: kernel)).path
        )
    }

    /// Forgets every saved machine taken from a kernel with this file name,
    /// whatever bytes that file held.
    ///
    /// Returns how many were removed, so a caller can say something true about
    /// what the gesture cost.
    ///
    /// The digest a machine is filed under is only knowable by reading the
    /// image, and the caller here — someone changing a kernel's memory in a
    /// list of names — has no reason to read a few megabytes to find out. The
    /// name is enough, and being generous is the safe direction: a snapshot
    /// taken at a different memory size **cannot** be restored anyway (both
    /// cores refuse the mismatch), so the alternative to removing it is
    /// leaving a file nothing will ever read again.
    ///
    /// The match is anchored on both sides rather than being a prefix test.
    /// `machine-Image-2-ff.wisqvm` starts with `machine-Image-`, so a prefix
    /// test asked to forget `Image` would also forget `Image-2`; requiring
    /// everything after the name to be the hexadecimal digest separates them.
    @discardableResult
    public static func clearAll(named name: String, in directory: URL? = nil) -> Int {
        guard let folder = try? (directory ?? Self.directory()) else { return 0 }
        var removed = 0
        for file in savedMachineFiles(named: name, in: directory) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            removed += 1
        }
        return removed
    }

    /// The files holding machines saved from a kernel with this file name.
    ///
    /// One matcher, used by everything that has to recognise them — forgetting
    /// them, and measuring what they occupy. Two copies of this rule would be
    /// the same mistake `safeName` was extracted to avoid.
    ///
    /// The match is anchored on both sides rather than being a prefix test.
    /// `machine-Image-2-ff.wisqvm` starts with `machine-Image-`, so a prefix
    /// test asked for `Image` would also return `Image-2`'s machines;
    /// requiring everything after the name to be the hexadecimal digest
    /// separates them.
    public static func savedMachineFiles(
        named name: String, in directory: URL? = nil
    ) -> [String] {
        guard let folder = try? (directory ?? Self.directory()),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        let prefix = "machine-\(safeName(name))-"
        let hexadecimal = Set("0123456789abcdef")
        return entries.filter { entry in
            guard entry.hasPrefix(prefix), entry.hasSuffix(".wisqvm") else { return false }
            let middle = entry.dropFirst(prefix.count).dropLast(".wisqvm".count)
            return !middle.isEmpty && middle.allSatisfy(hexadecimal.contains)
        }.sorted()
    }

    /// Every file in the directory that holds a saved machine, whatever kernel
    /// it came from. Used to find the ones no kernel claims any more.
    public static func allSavedMachineFiles(in directory: URL? = nil) -> [String] {
        guard let folder = try? (directory ?? Self.directory()),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return entries.filter { $0.hasPrefix("machine-") && $0.hasSuffix(".wisqvm") }.sorted()
    }
}
