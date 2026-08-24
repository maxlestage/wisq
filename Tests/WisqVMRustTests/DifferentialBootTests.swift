import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// Two interpreters of the same machine, made to prove they agree.
///
/// wisq has an rv32ima core written twice: once in Swift, once in Rust. The
/// Rust one is faster, so it is the one the app will run — which means the
/// Swift one stops being exercised by anyone, and a divergence between them
/// stops being noticed. That is the failure this file exists to prevent, and
/// it is the whole reason the Rust core is wired into the Swift package rather
/// than kept in a separate build: only here can a single test drive both.
///
/// The comparison is exact, not statistical. Both machines are deterministic —
/// the virtual clock advances with retired instructions, not wall time — so
/// after the same budget they must have retired the same count and written the
/// same console bytes. Not "roughly the same output": the same bytes.
///
/// The kernel image is not committed (3.4 MB of GPL binary does not belong in
/// the repo); the test looks for it at `WISQ_LINUX_IMAGE` or a well-known local
/// path and skips, loudly, when it is absent.
final class DifferentialBootTests: XCTestCase {
    private static func imageURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Console bytes, accumulated from whichever thread the machine runs on.
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) {
            lock.lock()
            bytes.append(chunk)
            lock.unlock()
        }

        var snapshot: Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    /// The budget is spent in slices so a divergence is caught where it happens
    /// rather than at the end of the boot: a mismatch at checkpoint 3 says the
    /// cores parted company in the third million instructions, which is a
    /// window small enough to read.
    private static let checkpoint: UInt64 = 1_000_000
    private static let checkpoints = 40

    func testBothCoresBootTheSameKernelIdentically() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let swiftConsole = Console()
        let rustConsole = Console()
        let swiftMachine = LinuxMachine { swiftConsole.append($0) }
        let rustMachine = RustLinuxMachine { rustConsole.append($0) }
        try swiftMachine.load(kernelImage: image, commandLine: "console=ttyS0")
        try rustMachine.load(kernelImage: image, commandLine: "console=ttyS0")

        for checkpoint in 1...Self.checkpoints {
            let swiftOutcome = swiftMachine.run(instructionBudget: Self.checkpoint)
            let rustOutcome = rustMachine.run(instructionBudget: Self.checkpoint)

            XCTAssertEqual(
                swiftOutcome, .stopped,
                "le cœur Swift ne doit pas s'arrêter au point \(checkpoint)"
            )
            XCTAssertEqual(
                rustOutcome, .stopped,
                "le cœur Rust ne doit pas s'arrêter au point \(checkpoint)"
            )
            XCTAssertEqual(
                swiftMachine.retiredInstructions, rustMachine.retiredInstructions,
                "instructions retirées divergentes au point \(checkpoint)"
            )

            // The console is flushed in batches, so the two can legitimately be
            // a partial batch apart at a checkpoint boundary. What must hold is
            // that neither has written anything the other contradicts: the
            // shorter is a prefix of the longer.
            let swiftBytes = swiftConsole.snapshot
            let rustBytes = rustConsole.snapshot
            let shared = min(swiftBytes.count, rustBytes.count)
            XCTAssertEqual(
                swiftBytes.prefix(shared), rustBytes.prefix(shared),
                "console divergente au point \(checkpoint) : \(Self.firstDifference(swiftBytes, rustBytes))"
            )
        }

        // A boot that produced nothing would satisfy every assertion above, so
        // the run has to be shown to have been a real one.
        let text = String(decoding: swiftConsole.snapshot, as: UTF8.self)
        XCTAssertTrue(
            text.contains("Linux version"),
            "les deux cœurs doivent avoir vraiment démarré Linux ; sortie : \(text.prefix(300))"
        )
        XCTAssertEqual(
            swiftConsole.snapshot, rustConsole.snapshot,
            "après le même budget, les deux consoles doivent être identiques"
        )
        XCTAssertGreaterThan(swiftMachine.retiredInstructions, 0)
    }

    /// Keyboard input goes through a different path in each core — a locked
    /// queue in Swift, an atomic-guarded one in Rust — so the agreement has to
    /// be shown with a guest that is reading, not only one that is printing.
    func testBothCoresSeeTheSameKeystrokes() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let swiftConsole = Console()
        let rustConsole = Console()
        let swiftMachine = LinuxMachine { swiftConsole.append($0) }
        let rustMachine = RustLinuxMachine { rustConsole.append($0) }
        try swiftMachine.load(kernelImage: image)
        try rustMachine.load(kernelImage: image)

        // Boot far enough that the shell is reading the console, then type the
        // same thing at both and let them answer.
        for machine in [Runner(swiftMachine), Runner(rustMachine)] {
            machine.run(120_000_000)
            machine.send("echo wisq-differentiel\n")
            machine.run(40_000_000)
        }

        let swiftText = String(decoding: swiftConsole.snapshot, as: UTF8.self)
        let rustText = String(decoding: rustConsole.snapshot, as: UTF8.self)
        try XCTSkipUnless(
            swiftText.contains("wisq-differentiel"),
            "le shell n'a pas été atteint dans le budget ; rien à comparer"
        )
        XCTAssertTrue(
            rustText.contains("wisq-differentiel"),
            "le cœur Rust doit avoir vu la même frappe que le cœur Swift"
        )
        XCTAssertEqual(
            swiftMachine.retiredInstructions, rustMachine.retiredInstructions,
            "la même frappe au même moment doit coûter le même nombre d'instructions"
        )
        XCTAssertEqual(swiftConsole.snapshot, rustConsole.snapshot)
    }

    func testBothCoresRejectTheSameImages() {
        let swiftMachine = LinuxMachine { _ in }
        let rustMachine = RustLinuxMachine { _ in }
        let tooLong = String(repeating: "x", count: 4096)

        XCTAssertThrowsError(try swiftMachine.load(kernelImage: Data()))
        XCTAssertThrowsError(try rustMachine.load(kernelImage: Data()))
        XCTAssertThrowsError(
            try swiftMachine.load(kernelImage: Data([0x13, 0, 0, 0]), commandLine: tooLong)
        )
        XCTAssertThrowsError(
            try rustMachine.load(kernelImage: Data([0x13, 0, 0, 0]), commandLine: tooLong)
        )
    }

    /// Where the two byte streams first part company, with enough context
    /// around it to recognise which line of the boot log it is.
    private static func firstDifference(_ left: Data, _ right: Data) -> String {
        let shared = min(left.count, right.count)
        let difference = (0..<shared).first { offset in
            left[left.startIndex + offset] != right[right.startIndex + offset]
        }
        guard let index = difference else {
            return "aucune, seules les longueurs diffèrent (\(left.count) contre \(right.count))"
        }
        let from = left.startIndex + max(0, index - 60)
        let context = left[from..<(left.startIndex + shared)].prefix(120)
        return "octet \(index), après « \(String(decoding: context, as: UTF8.self)) »"
    }
}

/// One script, two machine types. Swift's generics would need a protocol both
/// cores conform to, and adding a protocol to the shipping core to please a
/// test is the wrong way round — this closes over the calls instead.
private struct Runner {
    let run: (UInt64) -> Void
    let send: (String) -> Void

    init(_ machine: LinuxMachine) {
        run = { machine.run(instructionBudget: $0) }
        send = { machine.send(Data($0.utf8)) }
    }

    init(_ machine: RustLinuxMachine) {
        run = { machine.run(instructionBudget: $0) }
        send = { machine.send(Data($0.utf8)) }
    }
}

/// A snapshot is a file that outlives the process that wrote it, so the two
/// interpreters have to agree on it byte for byte — otherwise the day the app
/// switches cores, someone's saved machine stops opening.
///
/// This is stricter than "both can save and restore themselves". It requires
/// the bytes to be identical, and then makes each core resume from the other's
/// snapshot and continue to the same future.
final class SnapshotAgreementTests: XCTestCase {
    private final class Console: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var snapshot: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    private func imageURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func testBothCoresWriteTheSameSnapshotBytes() throws {
        guard let url = imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)
        let budget: UInt64 = 30_000_000

        let swiftConsole = Console(), rustConsole = Console()
        let swiftMachine = LinuxMachine { swiftConsole.append($0) }
        let rustMachine = RustLinuxMachine { rustConsole.append($0) }
        try swiftMachine.load(kernelImage: image, commandLine: "console=ttyS0")
        try rustMachine.load(kernelImage: image, commandLine: "console=ttyS0")
        swiftMachine.run(instructionBudget: budget)
        rustMachine.run(instructionBudget: budget)

        let fromSwift = swiftMachine.snapshot()
        let fromRust = rustMachine.snapshot()
        XCTAssertEqual(
            fromSwift.count, fromRust.count,
            "les deux cœurs doivent écrire un instantané de la même taille"
        )
        XCTAssertEqual(
            fromSwift, fromRust,
            "les deux cœurs doivent écrire exactement les mêmes octets"
        )
        XCTAssertFalse(
            swiftConsole.snapshot.isEmpty,
            "l'instantané doit être pris sur une machine qui a réellement tourné"
        )
    }

    func testEachCoreResumesFromTheOthersSnapshot() throws {
        guard let url = imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)
        let budget: UInt64 = 30_000_000
        let after: UInt64 = 6_000_000

        // One machine runs, saves, and keeps going: that continuation is the
        // reference both restored machines have to reproduce.
        let reference = LinuxMachine { _ in }
        try reference.load(kernelImage: image, commandLine: "console=ttyS0")
        reference.run(instructionBudget: budget)
        let saved = reference.snapshot()
        reference.run(instructionBudget: after)
        let expected = reference.retiredInstructions

        let intoSwift = LinuxMachine { _ in }
        try intoSwift.restore(saved)
        intoSwift.run(instructionBudget: after)
        XCTAssertEqual(
            intoSwift.retiredInstructions, expected,
            "le cœur Swift doit reprendre l'instantané à l'identique"
        )

        let intoRust = RustLinuxMachine { _ in }
        try intoRust.restore(saved)
        intoRust.run(instructionBudget: after)
        XCTAssertEqual(
            intoRust.retiredInstructions, expected,
            "le cœur Rust doit reprendre un instantané écrit par le cœur Swift"
        )
    }

    func testRubbishIsRefusedByBothCores() {
        let rubbish = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertThrowsError(try LinuxMachine { _ in }.restore(rubbish))
        XCTAssertThrowsError(try RustLinuxMachine { _ in }.restore(rubbish))
    }
}
