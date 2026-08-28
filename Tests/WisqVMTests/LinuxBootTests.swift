import XCTest
@testable import WisqVM

/// Boots a real Linux kernel — the same rv32 nommu image the reference emulator
/// runs — and reads its console. There is no better test of an emulator than
/// the guest it was built for.
///
/// The image is not committed (3.4 MB of GPL binary does not belong in the
/// repo); the test looks for it at `WISQ_LINUX_IMAGE` or a well-known local
/// path and skips, loudly, when absent. CI downloads it in a dedicated step.
final class LinuxBootTests: XCTestCase {
    private static func imageURL() -> URL? {
        // The environment names where CI *tried* to put the image; when the
        // download failed the file is simply absent, and that must be a skip,
        // not a failure blaming the emulator.
        let candidates = [
            ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"],
            "/tmp/wisq-test-linux-image/Image",
        ]
        for case let path? in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func testBootsARealKernelToItsBanner() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let console = ConsoleCapture()
        let machine = LinuxMachine { console.append($0) }
        try machine.load(kernelImage: image)

        // The banner prints within the first few million instructions; the
        // budget is generous so a slow debug build still gets there, and small
        // enough that a broken emulator fails in seconds instead of hanging.
        let outcome = machine.run(instructionBudget: 60_000_000)

        let output = console.text()
        XCTAssertTrue(
            output.contains("Linux version"),
            "la bannière du noyau doit apparaître; sortie: \(output.prefix(400))"
        )
        XCTAssertTrue(
            output.contains("rv32ima") || output.contains("riscv"),
            "le noyau doit se reconnaître sur du RISC-V; sortie: \(output.prefix(400))"
        )
        XCTAssertEqual(outcome, .stopped, "le budget doit expirer, pas la machine planter")
    }

    /// The banner is the second millisecond of the boot. This is the rest of it.
    ///
    /// A sweep of the interpreter's decoder — every arm turned into a no-op, one
    /// at a time — found sixty-six of a hundred and six held by no test at all,
    /// and the cause was shared: the assertion above stops at the first line the
    /// kernel prints. Break the write to `mtvec` and the machine derails so
    /// badly the run takes fifty-one seconds instead of six — and passes,
    /// because the banner had already gone out. Everything after it — the trap
    /// vector, `MRET`, the CSRs, the atomics, the drop to user mode — happened
    /// inside a test that had stopped looking.
    ///
    /// Reaching `buildroot login:` is not a longer version of the same claim.
    /// It is init running as a user-mode process on a console the kernel handed
    /// over, which cannot happen unless the machinery above works. It is also
    /// what the guide promises the reader — *jusqu'à l'invite de connexion* —
    /// and until now nothing checked the half of that sentence that matters.
    ///
    /// The budget is the one the banner test already spent: the prompt arrives
    /// around forty-six million instructions, well inside sixty. The reach was
    /// there the whole time and only the assertion was missing.
    func testBootsAllTheWayToItsLoginPrompt() throws {
        guard let url = Self.imageURL() else {
            throw XCTSkip("image Linux absente : définir WISQ_LINUX_IMAGE pour ce test")
        }
        let image = try Data(contentsOf: url)

        let console = ConsoleCapture()
        let machine = LinuxMachine { console.append($0) }
        try machine.load(kernelImage: image)
        let outcome = machine.run(instructionBudget: 60_000_000)

        let output = console.text()
        XCTAssertTrue(
            output.contains("Run /init as init process"),
            "le noyau doit passer la main à l'espace utilisateur; fin de sortie: \(output.suffix(400))"
        )
        XCTAssertTrue(
            output.contains("buildroot login:"),
            "l'invite de connexion doit apparaître; fin de sortie: \(output.suffix(400))"
        )
        XCTAssertEqual(outcome, .stopped, "le budget doit expirer, pas la machine planter")
    }

    func testCommandLinePatchingIsBounded() {
        let machine = LinuxMachine { _ in }
        XCTAssertThrowsError(
            try machine.load(
                kernelImage: Data([0x13, 0x00, 0x00, 0x00]),
                commandLine: String(repeating: "x", count: 100)
            )
        )
        XCTAssertNoThrow(
            try machine.load(
                kernelImage: Data([0x13, 0x00, 0x00, 0x00]),
                commandLine: "console=ttyS0"
            )
        )
    }

    func testStopInterruptsARunningMachine() throws {
        let machine = LinuxMachine { _ in }
        // An infinite loop: jal x0, 0 — jumps to itself forever.
        try machine.load(kernelImage: Data([0x6F, 0x00, 0x00, 0x00]))

        let expectation = expectation(description: "run returns")
        Thread {
            let outcome = machine.run()
            XCTAssertEqual(outcome, .stopped)
            expectation.fulfill()
        }.start()

        machine.stop()
        wait(for: [expectation], timeout: 10)
    }

    private final class ConsoleCapture: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
