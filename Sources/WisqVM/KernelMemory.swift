import Foundation

/// How much memory a given kernel's machine gets, remembered between launches.
///
/// This lives in `WisqVM` rather than in the app layer for the reason
/// `SuspendedMachine` gives: the app only builds on Apple platforms, so
/// anything living there cannot be tested on the runner that costs nothing —
/// and "write a choice, read it back, survive a first launch with nothing
/// there" is worth testing rather than reasoning about.
///
/// **Filed under the kernel's file name, not its bytes.** That is the opposite
/// of `SuspendedMachine`, which keys on a digest because two kernels a user
/// imports a week apart are both called `Image` and handing the second one the
/// first one's *snapshot* would restore a machine that never existed. A size is
/// not state: at worst a replaced file inherits a preference the user can
/// change in one tap, and reading it needs no bytes — which matters, because
/// the boot path has to know how big the machine is **before** it reads the
/// image, and the digest is only available after.
public enum KernelMemory {
    /// The reference machine, and what a kernel with no choice recorded gets.
    public static let defaultSize = LinuxMachine.defaultRAMSize

    /// The sizes offered, smallest first.
    ///
    /// Powers of two from a quarter of the reference machine to a gibibyte.
    /// 16 MB is below the reference and deliberately kept: the kernels this
    /// emulator was built for are a few megabytes, and someone measuring how
    /// little a guest needs is doing something legitimate. The list is filtered
    /// by `ceiling(physicalMemory:)` before it is shown.
    public static let choices: [UInt32] = [
        16 << 20, 32 << 20, 64 << 20, 128 << 20, 256 << 20, 512 << 20, 1024 << 20,
    ]

    /// The largest machine this device may be asked for.
    ///
    /// A **policy**, not a measurement, and it is worth being plain about that:
    /// iOS does not publish the limit at which it kills an app. The number that
    /// matters — jetsam — is well under physical memory, varies with what else
    /// is running, and is roughly a third of the device's memory on the phones
    /// this app runs on (iOS 17, so 2 GB and up).
    ///
    /// So the rule is **an eighth** of physical memory, capped at one gibibyte
    /// and never below the reference machine. An eighth and not a third: the
    /// guest's RAM is one mapping the interpreter touches at will, so it all
    /// becomes resident, and the app needs room next to it for the console,
    /// the framebuffers of a remote session, and the image it read to boot.
    /// A quarter — the first draft — puts a 2 GB phone at 512 MB of guest RAM,
    /// which is close enough to jetsam that the setting would ship a crash.
    ///
    /// Conservative on purpose. Memory pressure is exactly what made the app
    /// vanish on a distribution image, and a setting that let someone ask for
    /// two gigabytes on a phone that has three would be a crash dressed as a
    /// choice.
    public static func ceiling(physicalMemory: UInt64) -> UInt32 {
        let share = physicalMemory / 8
        let capped = min(share, 1024 << 20)
        return UInt32(max(capped, UInt64(defaultSize)))
    }

    /// The same, from what this device says about itself.
    public static var ceiling: UInt32 {
        ceiling(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// The sizes worth offering on this device: the choices up to the ceiling.
    public static func offered(ceiling limit: UInt32) -> [UInt32] {
        choices.filter { $0 <= limit }
    }

    /// The largest kernel image worth keeping on this device.
    ///
    /// Judged against the **largest machine the device allows**, not against
    /// the kernel's own setting, because at import time there is no setting
    /// yet: the file has just arrived and the size is chosen afterwards.
    /// Refusing it against the default would refuse a file someone imported
    /// precisely in order to run it in a bigger machine.
    ///
    /// The boot path asks a different and stricter question — does this image
    /// fit in the machine this kernel is set to run — and both are right for
    /// their moment.
    public static func maximumImportableImageBytes(ceiling limit: UInt32 = ceiling) -> Int {
        LinuxMachine.maximumKernelImageBytes(forRAMSize: limit)
    }

    /// What a kernel is set to run with. `defaultSize` when nothing is
    /// recorded, which is every kernel until someone moves the setting.
    ///
    /// A recorded size above the device's ceiling is **clamped rather than
    /// honoured**: a phone can be replaced by a smaller one, and an app that
    /// dies on launch because a file remembers a choice the hardware cannot
    /// meet is worse than one that quietly runs smaller.
    public static func size(forKernel kernel: String, in directory: URL? = nil,
                            ceiling limit: UInt32 = ceiling) -> UInt32 {
        guard let recorded = recorded(in: directory)[kernel] else { return defaultSize }
        guard choices.contains(recorded) else { return defaultSize }
        return min(recorded, limit)
    }

    /// Records a choice. Returns silently when the size is not one we offer:
    /// the caller is a picker built from `offered`, and a value from anywhere
    /// else is a bug rather than something to encode.
    public static func setSize(_ size: UInt32, forKernel kernel: String,
                               in directory: URL? = nil) {
        guard choices.contains(size) else { return }
        var all = recorded(in: directory)
        if size == defaultSize {
            // The default is the absence of a choice, so going back to it
            // removes the entry rather than writing the number down. A file
            // that only holds departures from the default stays readable.
            all.removeValue(forKey: kernel)
        } else {
            all[kernel] = size
        }
        write(all, in: directory)
    }

    /// Forgets a kernel's choice — for a kernel the user deleted.
    public static func forget(kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        guard all.removeValue(forKey: kernel) != nil else { return }
        write(all, in: directory)
    }

    // MARK: - Where the choices live

    static let fileName = "kernel-memory.json"

    /// Next to the suspended machines: the same Application Support directory,
    /// so one place holds everything the local VM remembers, and a test can
    /// hand both its own directory.
    public static func directory() throws -> URL {
        try SuspendedMachine.directory()
    }

    private static func url(in directory: URL?) -> URL? {
        let base = directory ?? (try? Self.directory())
        return base?.appendingPathComponent(fileName)
    }

    /// What is on disk. An unreadable or nonsensical file reads as "no choices
    /// recorded" rather than as a failure: the worst outcome is that every
    /// kernel runs at the reference size, which is what it did before this
    /// setting existed.
    private static func recorded(in directory: URL?) -> [String: UInt32] {
        guard let url = url(in: directory),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: UInt32].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ all: [String: UInt32], in directory: URL?) {
        guard let url = url(in: directory) else { return }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
