import Foundation
import XCTest

@testable import WisqVM

/// A guest that parks itself with nothing to wait for.
///
/// `WFI` puts the hart to sleep until an interrupt arrives, and on this machine
/// the timer is the only interrupt there is — a parked hart executes nothing,
/// so it cannot poll the UART either. Run `WFI` without arming `mtimecmp` and
/// nothing will ever wake it.
///
/// The budget cannot end that wait. It counts instructions the guest *retired*,
/// deliberately, so an idle guest cannot spend a budget by doing nothing — and
/// a parked hart retires nothing at all. Before the fix beside this file, a
/// two-instruction guest retired one instruction and then spun at full speed
/// for ever: on a phone, a pinned core and a hot battery for a guest that had
/// stopped asking for anything. The app calls `run()` once with no budget, so
/// "for ever" meant until the user left the screen.
///
/// The sweep that found it was measuring something else entirely — which of the
/// interpreter's decoder arms the two cores' differential comparison notices.
/// Two arms did not make it fail; they made it *hang*, and that was the thread
/// worth pulling.
final class ParkedHartTests: XCTestCase {
    /// ```
    /// wfi                # park, with no timer armed
    /// beq  x0, x0, 0     # and if anything ever wakes us, spin
    /// ```
    static let parksImmediately: [UInt32] = [0x1050_0073, 0x0000_0063]

    /// ```
    /// lui  x1, 0x11004   # the CLINT's mtimecmp
    /// addi x2, x0, 2047
    /// sw   x2, 0(x1)     # arm it
    /// wfi                # park, with something coming
    /// beq  x0, x0, 0
    /// ```
    static let armsATimerThenParks: [UInt32] = [
        0x1100_40B7, 0x7FF0_0113, 0x0020_A023, 0x1050_0073, 0x0000_0063,
    ]

    static func image(_ program: [UInt32]) -> Data {
        var data = Data()
        for word in program {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Bounded on the wall clock, not on the machine: a regression here does
    /// not make this test fail slowly, it makes it never return. The waiter is
    /// what turns "hangs" into "red".
    private func outcome(
        of machine: LinuxMachine, budget: UInt64, within seconds: TimeInterval = 10
    ) -> LinuxMachine.Outcome? {
        let finished = expectation(description: "run rend la main")
        let box = OutcomeBox()
        Thread {
            box.value = machine.run(instructionBudget: budget)
            finished.fulfill()
        }.start()

        guard XCTWaiter().wait(for: [finished], timeout: seconds) == .completed else {
            machine.stop()          // do not leave a spinning thread behind
            return nil
        }
        return box.value
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: LinuxMachine.Outcome?
    }

    func testAHartParkedWithNoTimerArmedStopsInsteadOfSpinning() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Self.image(Self.parksImmediately))

        let result = outcome(of: machine, budget: 10_000)
        XCTAssertEqual(result, .stopped, "la machine doit rendre la main, pas tourner en rond")
        XCTAssertEqual(
            machine.retiredInstructions, 1,
            "une seule instruction retirée : le WFI lui-même"
        )
    }

    /// The same guest run with no budget at all — which is how the app runs it.
    /// A budget of `.max` is what made the old behaviour unbounded rather than
    /// merely slow.
    func testTheSameHartStopsEvenWithNoBudgetToExhaust() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Self.image(Self.parksImmediately))

        XCTAssertEqual(outcome(of: machine, budget: .max), .stopped)
    }

    /// **The half that must not change.** A hart parked with a timer armed is
    /// waiting for something that will arrive, and must go on waiting: the
    /// clock is jumped to the moment already written in `mtimecmp`, the
    /// interrupt fires, and the guest carries on. A fix that returned on every
    /// `WFI` would turn every idle Linux guest into a stopped one.
    func testAHartParkedWithATimerArmedKeepsGoing() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Self.image(Self.armsATimerThenParks))

        let result = outcome(of: machine, budget: 4096)
        XCTAssertEqual(result, .stopped, "le budget doit s'épuiser normalement")
        XCTAssertGreaterThanOrEqual(
            machine.retiredInstructions, 4096,
            "le minuteur a réveillé le hart, qui a dépensé tout son budget"
        )
    }
}
