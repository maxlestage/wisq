import XCTest
@testable import WisqVM

/// Le temps passé hors de la machine RISC-V : voir
/// `LinuxMachine.elapse(seconds:)`. L'invité réel est dans
/// `DifferentialElapseTests`.
final class LinuxMachineElapseTests: XCTestCase {
    private func mtime(_ machine: LinuxMachine) -> UInt64 {
        UInt64(machine.mmioLoad(0x1100_BFFC)) << 32 | UInt64(machine.mmioLoad(0x1100_BFF8))
    }

    /// **Trois jours dehors, trois jours de plus à `mtime`**, en
    /// microsecondes, payés en 864 pas de cinq minutes, retenue du mot haut
    /// comprise.
    func testThreeDaysOutsideArePaidInSteps() {
        let machine = LinuxMachine(ramSize: 16 << 20, onOutput: { _ in })
        let before = mtime(machine)
        machine.elapse(seconds: 3 * 86_400)
        XCTAssertEqual(mtime(machine), before, "rien avant le premier sommeil")
        machine.takeElapseStep()
        XCTAssertEqual(mtime(machine) - before, 300_000_000)
        var steps = 1
        while machine.pendingElapse > 0 {
            machine.takeElapseStep()
            steps += 1
        }
        XCTAssertEqual(steps, 864)
        XCTAssertEqual(mtime(machine) - before, 259_200_000_000)
        XCTAssertGreaterThan(machine.mmioLoad(0x1100_BFFC), 0, "le mot haut a reçu la retenue")
    }

    /// Ni recul, ni écart absurde, ni débordement.
    func testNeverBackNorOverflowing() {
        let machine = LinuxMachine(ramSize: 16 << 20, onOutput: { _ in })
        machine.elapse(seconds: -1)
        machine.elapse(seconds: .nan)
        machine.elapse(seconds: .infinity)
        XCTAssertEqual(machine.pendingElapse, 0)
        machine.elapse(seconds: 1e15)
        XCTAssertEqual(machine.pendingElapse, UInt64(GuestClock.longestElapse * 1_000_000))
    }

    /// **Par le protocole, depuis l'instantané** : ce que l'application
    /// appelle, quelle que soit la machine.
    func testThroughTheProtocol() {
        let machine = LinuxMachine(ramSize: 16 << 20, onOutput: { _ in })
        let guest: GuestMachine = machine
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        guest.elapse(since: nil, now: now)
        XCTAssertEqual(machine.pendingElapse, 0)
        guest.elapse(since: now.addingTimeInterval(-90), now: now)
        XCTAssertEqual(machine.pendingElapse, 90_000_000)
    }
}
