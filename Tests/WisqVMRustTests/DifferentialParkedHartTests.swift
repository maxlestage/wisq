import Foundation
import WisqVM
import WisqVMRust
import XCTest

/// The two cores, compared on a guest that parks itself — and the first
/// comparison in this target that is driven by chosen instructions rather than
/// by booting Linux.
///
/// That distinction is the reason this file exists. `DifferentialBootTests`
/// compares the interpreters exactly, but only on what a kernel happens to
/// execute on its way to a login prompt; a sweep of the decoder measured how
/// far that reaches, and it is about two thirds of the table. A guest that
/// parks with no timer armed is outside it, and the two cores each had to be
/// given the same answer by hand.
///
/// Both are bounded on the wall clock. Before the guard each core grew, this
/// guest made `run` spin for ever — so a regression here does not fail slowly,
/// it never returns, and only the waiter turns that into a red.
final class DifferentialParkedHartTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var swiftOutcome: LinuxMachine.Outcome?
        var rustOutcome: RustLinuxMachine.Outcome?
        var swiftRetired: UInt64 = 0
        var rustRetired: UInt64 = 0
        var swiftSnapshot = Data()
        var rustSnapshot = Data()
    }

    private func image(_ program: [UInt32]) -> Data {
        var data = Data()
        for word in program {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// `wfi ; beq x0, x0, 0`, with nothing armed to end the wait.
    private let parksImmediately: [UInt32] = [0x1050_0073, 0x0000_0063]

    func testBothCoresStopAParkedHartTheSameWay() throws {
        let bytes = image(parksImmediately)
        let box = Box()

        let swiftMachine = LinuxMachine { _ in }
        let rustMachine = RustLinuxMachine { _ in }
        try swiftMachine.load(kernelImage: bytes)
        try rustMachine.load(kernelImage: bytes)

        let finished = expectation(description: "les deux rendent la main")
        finished.expectedFulfillmentCount = 2
        Thread {
            box.swiftOutcome = swiftMachine.run(instructionBudget: 10_000)
            box.swiftRetired = swiftMachine.retiredInstructions
            box.swiftSnapshot = swiftMachine.snapshot()
            finished.fulfill()
        }.start()
        Thread {
            box.rustOutcome = rustMachine.run(instructionBudget: 10_000)
            box.rustRetired = rustMachine.retiredInstructions
            box.rustSnapshot = rustMachine.snapshot()
            finished.fulfill()
        }.start()

        guard XCTWaiter().wait(for: [finished], timeout: 20) == .completed else {
            swiftMachine.stop()
            rustMachine.stop()
            return XCTFail("un des deux cœurs ne rend pas la main sur un hart garé")
        }

        XCTAssertEqual(box.swiftOutcome, .stopped, "le cœur Swift s'arrête")
        XCTAssertEqual(box.rustOutcome, .stopped, "le cœur Rust aussi")
        XCTAssertEqual(
            box.swiftRetired, box.rustRetired,
            "et tous deux se sont arrêtés après le même nombre d'instructions"
        )
        XCTAssertEqual(box.swiftRetired, 1, "une seule : le WFI lui-même")
        XCTAssertEqual(
            box.swiftSnapshot, box.rustSnapshot,
            "l'état des deux machines doit être identique octet pour octet"
        )
    }
}
