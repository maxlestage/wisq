import Foundation
@testable import WisqVM
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
        try rustMachine.loadOnTheSameBoard(kernelImage: image, commandLine: "console=ttyS0")

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
        try rustMachine.loadOnTheSameBoard(kernelImage: image)

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

        XCTAssertThrowsError(try swiftMachine.load(kernelImage: Data()))
        XCTAssertThrowsError(try rustMachine.loadOnTheSameBoard(kernelImage: Data()))
    }

    /// **Et ni l'un ni l'autre ne refuse plus une longue ligne de commande.**
    ///
    /// Les deux la refusaient au-delà de cinquante-quatre caractères, et ce
    /// n'était pas une règle de la machine : c'était la place que le blob de
    /// référence se trouvait avoir entre deux propriétés. L'arbre est
    /// construit depuis, la ligne est une propriété comme une autre, et le
    /// plafond n'a plus de raison d'exister — la mesure ici est que les deux
    /// cœurs l'acceptent **et** qu'ils démarrent sur la même carte.
    func testNeitherCoreCapsTheCommandLineAnyMore() throws {
        let long = String(repeating: "console=ttyS0 ", count: 40)
        XCTAssertGreaterThan(long.count, 54, "plus long que ce que le blob permettait")
        let image = Data([0x13, 0, 0, 0])

        let swiftMachine = LinuxMachine { _ in }
        let rustMachine = RustLinuxMachine { _ in }
        XCTAssertNoThrow(try swiftMachine.load(kernelImage: image, commandLine: long))
        XCTAssertNoThrow(
            try rustMachine.loadOnTheSameBoard(kernelImage: image, commandLine: long))

        // Et l'invité la lit vraiment : le cœur Swift laisse relire l'arbre
        // qu'il a posé, et `bootargs` y est en entier.
        let tree = try DeviceTree.read(swiftMachine.deviceTreeHandedToTheGuest)
        XCTAssertEqual(tree.root.child("chosen")?.property("bootargs"), .string(long))
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
        try rustMachine.loadOnTheSameBoard(kernelImage: image, commandLine: "console=ttyS0")
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

    /// Advances `machine` in slices until it writes something, and reports the
    /// instructions that cost. Nil if it stayed silent, or parked, first.
    ///
    /// A budget picked by hand is a property of one kernel image rather than
    /// of the code: this one is silent for stretches of tens of millions of
    /// instructions, and a window that lands in one compares two empty
    /// strings. Finding the point instead keeps the comparison's teeth when
    /// the image changes. The Rust suite learned this and said so; this file
    /// had not.
    private func runUntilItSpeaks(
        _ machine: LinuxMachine, console: Console, past was: Int, cap: UInt64
    ) -> UInt64? {
        let slice: UInt64 = 2_000_000
        let start = machine.retiredInstructions
        while machine.retiredInstructions - start < cap {
            let before = machine.retiredInstructions
            machine.run(instructionBudget: slice)
            // A parked hart retires nothing and never will: spinning here
            // would turn a silent guest into a hanging test.
            if machine.retiredInstructions == before { return nil }
            if console.snapshot.count > was { return machine.retiredInstructions - start }
        }
        return nil
    }

    /// A restored machine has to *continue* the one that was saved, and the
    /// only proof of that is what it says next.
    ///
    /// This test used to assert the retired count alone, over a fixed budget of
    /// six million instructions taken after the snapshot. Both halves of that
    /// were blind:
    ///
    ///   - **The count is the same number** for a machine that works and one
    ///     that does not. A guest whose return address was lost derails, and a
    ///     derailed guest is a busy one — it retires every instruction the
    ///     budget allows. Measured, not supposed: with `restore` dropping `x1`,
    ///     the count matched and this test passed.
    ///   - **The window was silent.** Measured too, by asserting otherwise and
    ///     watching it fail: in those six million instructions this kernel
    ///     writes nothing at all. Even an assertion on the console would have
    ///     compared one empty string to another.
    ///
    /// So the console is the assertion now, the count is kept beside it, and
    /// the window is found rather than guessed: the reference is carried on
    /// until it actually writes, and each restored core is given exactly the
    /// instructions that took.
    ///
    /// **What that bought, exactly, and what it did not.** It is worth being
    /// precise, because the obvious reading is too generous. Dropping the
    /// restore of RAM is now caught here by the console alone — the retired
    /// count matches — so the count really was the weaker half. But the
    /// thirty-five fields this test could not see before, it still cannot see:
    /// re-measured field by field after the change, all thirty-five survive.
    /// A boot cannot hold an individual register, because whether that
    /// register is live at the instant the snapshot is taken is an accident of
    /// where the boot had got to. `SnapshotFieldWitnessTests` holds them, and
    /// holds them by construction rather than by luck.
    func testEachCoreResumesFromTheOthersSnapshot() throws {
        guard let url = imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)
        let budget: UInt64 = 30_000_000

        // One machine runs, saves, and keeps going: that continuation is the
        // reference both restored machines have to reproduce.
        let referenceConsole = Console()
        let reference = LinuxMachine { referenceConsole.append($0) }
        try reference.load(kernelImage: image, commandLine: "console=ttyS0")
        reference.run(instructionBudget: budget)
        let saved = reference.snapshot()
        let atSnapshot = referenceConsole.snapshot.count
        XCTAssertGreaterThan(
            atSnapshot, 0, "l'instantané doit être pris sur une machine qui a réellement démarré"
        )

        let after = try XCTUnwrap(
            runUntilItSpeaks(reference, console: referenceConsole, past: atSnapshot, cap: 90_000_000),
            "l'invité doit réécrire après l'instantané, sans quoi la comparaison ne compare rien"
        )
        let expected = reference.retiredInstructions
        let continuation = Data(referenceConsole.snapshot.dropFirst(atSnapshot))

        let swiftConsole = Console()
        let intoSwift = LinuxMachine { swiftConsole.append($0) }
        try intoSwift.restore(saved)
        intoSwift.run(instructionBudget: after)
        XCTAssertEqual(
            swiftConsole.snapshot, continuation,
            "le cœur Swift doit écrire la suite de la machine sauvée, octet pour octet"
        )
        XCTAssertEqual(
            intoSwift.retiredInstructions, expected,
            "le cœur Swift doit reprendre l'instantané à l'identique"
        )

        let rustConsole = Console()
        let intoRust = RustLinuxMachine { rustConsole.append($0) }
        try intoRust.restore(saved)
        intoRust.run(instructionBudget: after)
        XCTAssertEqual(
            rustConsole.snapshot, continuation,
            "le cœur Rust doit écrire la suite d'un instantané écrit par le cœur Swift"
        )
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
