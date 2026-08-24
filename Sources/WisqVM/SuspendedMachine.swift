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
    /// One saved machine per kernel, and the kernel is in the file name.
    ///
    /// A snapshot only means anything against the image it was taken from:
    /// restoring a machine booted from one kernel into a session the user
    /// opened with another would resurrect the wrong thing. Putting the kernel
    /// in the name makes a mismatch simply mean "nothing saved", which needs no
    /// consistency rule at all — the alternative, a marker file beside the
    /// snapshot, has a window where the two disagree.
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
}
