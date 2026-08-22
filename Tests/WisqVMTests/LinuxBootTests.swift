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
        if let path = ProcessInfo.processInfo.environment["WISQ_LINUX_IMAGE"] {
            return URL(fileURLWithPath: path)
        }
        let fallback = URL(fileURLWithPath: "/tmp/wisq-test-linux-image/Image")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
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
