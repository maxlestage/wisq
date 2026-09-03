import Foundation

#if os(iOS)
import os
#endif

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
    /// Powers of two from a quarter of the reference machine to the largest
    /// machine the architecture allows. 16 MB is below the reference and
    /// deliberately kept: the kernels this emulator was built for are a few
    /// megabytes, and someone measuring how little a guest needs is doing
    /// something legitimate. The list is filtered by `ceiling(physicalMemory:)`
    /// before it is shown.
    ///
    /// The top of the list is `LinuxMachine.maximumRAMSize`, which is not a
    /// taste: guest RAM starts at `0x8000_0000` and the hart addresses memory
    /// with thirty-two bits, so two gibibytes is the last byte it can own.
    /// Verified against the real kernel — 2 GiB boots to its login prompt, in
    /// about 120 million instructions instead of 46.
    public static let choices: [UInt32] = [
        16 << 20, 32 << 20, 64 << 20, 128 << 20, 256 << 20, 512 << 20,
        1024 << 20, LinuxMachine.maximumRAMSize,
    ]

    /// What the app must keep for itself, next to the guest's RAM.
    ///
    /// The guest's memory is one mapping the interpreter touches at will, so
    /// it all becomes resident. Everything else the app is doing lives beside
    /// it: the console's text and its grid, the framebuffers of a remote
    /// session, the kernel image being read from disk, and the decoding
    /// buffers of whatever protocol is open.
    ///
    /// A named number rather than a fraction, because it does not scale with
    /// the guest — a bigger machine does not make the console bigger. It is a
    /// judgement, and it is generous on purpose: the failure it prevents is
    /// the app disappearing without a word, which is the exact thing that
    /// happened here once already.
    public static let roomForTheAppItself: UInt64 = 256 << 20

    /// What the machine leaves to the device, whatever the moment allows.
    ///
    /// Maxime's rule, in his words: « je veux pouvoir la gérer en étant deux
    /// giga plus petit que l'iPhone 17 Pro n'a de ram ». Two gibibytes below
    /// the device's own memory — a bound that scales with the phone and does
    /// not move, unlike what the system reports.
    ///
    /// It sits **next to** the system's answer rather than replacing it,
    /// because the two say different things. This one says how much of a
    /// device wisq is willing to be; `os_proc_available_memory()` says how
    /// much is free right now. A phone with twelve gibibytes allows ten by
    /// this rule and rather less by the other, and the smaller of the two is
    /// the only one that is safe to offer.
    public static let leftToTheDevice: UInt64 = 2 << 30

    /// The largest machine this device may be asked for.
    ///
    /// **Measured, not guessed.** iOS publishes exactly this number:
    /// `os_proc_available_memory()` returns how many bytes the app may still
    /// allocate before the system kills it. Asking it is strictly better than
    /// the fraction of physical memory this used to use — that fraction was an
    /// invention, it ignored what the rest of the device was doing, and it
    /// gave the same answer on a phone at rest and a phone under pressure.
    ///
    /// So: what the system says is left, minus what the app needs beside the
    /// guest, never below the reference machine and never above what the
    /// architecture allows.
    ///
    /// `availableBytes` is a parameter rather than a call so this rule can be
    /// tested on a runner that has no iOS to ask. `physicalMemory` is the
    /// fallback for the platforms that do not publish the first number —
    /// macOS and Linux — where an eighth of physical memory remains the best
    /// available guess.
    public static func ceiling(availableBytes: UInt64?, physicalMemory: UInt64) -> UInt32 {
        // What the moment allows: the system's own answer, less the room the
        // app needs beside the guest. Where nothing answers, the fraction.
        let now = availableBytes.map { $0 > roomForTheAppItself ? $0 - roomForTheAppItself : 0 }
            ?? (physicalMemory / 8)
        // What the device allows, whatever the moment: two gibibytes below its
        // own memory. Subtracted with a floor, because a device smaller than
        // the margin would otherwise wrap.
        let device = physicalMemory > leftToTheDevice ? physicalMemory - leftToTheDevice : 0
        // And what the architecture allows, which is not negotiable.
        let capped = min(min(now, device), UInt64(LinuxMachine.maximumRAMSize))
        return UInt32(max(capped, UInt64(defaultSize)))
    }

    /// The same, from what this device says about itself right now.
    ///
    /// Read each time it is asked, not once: the answer on a phone with three
    /// other apps in memory is not the answer on a phone that just launched,
    /// and a setting that offered yesterday's number would be offering a
    /// crash.
    public static var ceiling: UInt32 {
        ceiling(
            availableBytes: systemAvailableMemory,
            physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// How many bytes the system says this app may still allocate, or nil
    /// where nothing says.
    ///
    /// iOS 13 and up answer with `os_proc_available_memory()`. macOS does not
    /// implement it — it has no per-app allocation limit to report — and
    /// neither does Linux, so both fall back to the fraction.
    public static var systemAvailableMemory: UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        // Zero is documented as "not available", not as "no memory left".
        // Treating it as the latter would offer a 64 MB machine on a phone
        // that is perfectly healthy.
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
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

    /// Why a machine cannot start right now, in the terms of the phone.
    ///
    /// The setting is remembered; how much memory the device has free is not a
    /// property of the setting. A phone that could give a gibibyte this
    /// morning may not this afternoon, and the honest answer is a sentence
    /// rather than a machine that starts and takes the app down with it.
    ///
    /// It says both numbers and what to do about them, because "pas assez de
    /// mémoire" without a figure is a dead end — the reader cannot tell
    /// whether to close one app or change the setting.
    public static func notEnoughRoomExplanation(
        requested: UInt32, ceiling limit: UInt32, name: String
    ) -> String {
        """
        \(name) est réglé sur \(describe(requested)) de mémoire, et ce \
        téléphone n'en a que \(describe(limit)) de libre en ce moment.

        Fermez une application, ou baissez le curseur de mémoire de ce noyau. \
        Démarrer quand même reviendrait à faire tuer wisq par iOS au milieu du \
        démarrage, ce qui ressemble à un plantage sans en expliquer la cause.
        """
    }

    /// A size as someone reads it: mebibytes until a gibibyte, then gibibytes.
    ///
    /// « 1024 Mo » was what the largest choice used to read, which is exactly
    /// how a setting that reaches a gibibyte gets mistaken for one that stops
    /// at megabytes. Powers of two, and the abbreviation says so, because the
    /// rest of wisq counts memory that way.
    public static func describe(_ bytes: UInt32) -> String {
        guard bytes >= 1024 << 20 else { return "\(bytes >> 20) Mo" }
        let gibibytes = Double(bytes) / Double(1024 << 20)
        let format = gibibytes == gibibytes.rounded() ? "%.0f Gio" : "%.1f Gio"
        return String(format: format, gibibytes).replacingOccurrences(of: ".", with: ",")
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
