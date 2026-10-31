import XCTest
@testable import WisqVM

/// Le temps passé hors de la machine : voir `X86Machine.elapse(seconds:)`.
final class X86ElapseTests: XCTestCase {
    private func machine() -> X86Machine {
        X86Machine(ramSize: 16 << 20, onOutput: { _ in })
    }

    private func clock(_ machine: X86Machine) -> UInt64 { machine.core.retired &+ machine.core.idled }

    /// Paie tout le temps dû, et dit en combien de pas.
    private func drain(_ pc: X86Machine) -> Int {
        var steps = 0
        while pc.pendingElapse > 0 {
            _ = pc.takeElapseStep()
            steps += 1
        }
        return steps
    }

    /// **Une heure dehors, une heure de plus au compteur** de l'invité, au
    /// rythme où son noyau l'a étalonné — le compteur d'horodatage et le 8253
    /// ensemble —, payée en trois cent soixante pas de dix secondes.
    func testAnHourOutsideIsAnHourInsideInSteps() {
        let pc = machine()
        let before = clock(pc)
        let ticks = pc.core.ticks
        pc.elapse(seconds: 3600)
        XCTAssertEqual(clock(pc), before, "rien avant le premier sommeil")
        XCTAssertEqual(pc.takeElapseStep(), UInt64(10 * pc.guestHertz), "un pas de dix secondes")
        XCTAssertEqual(drain(pc), 359)
        XCTAssertEqual(clock(pc) - before, UInt64(3600 * pc.guestHertz))
        XCTAssertEqual(pc.core.ticks - ticks, 3600 * 1_193_182, "le 8253 avance d'autant")
    }

    /// Le temps de l'invité ne recule pas, et un écart absurde ne déborde
    /// pas.
    func testTimeNeverGoesBackNorOverflows() {
        let pc = machine()
        pc.elapse(seconds: -600)
        pc.elapse(seconds: .nan)
        pc.elapse(seconds: .infinity)
        XCTAssertEqual(pc.pendingElapse, 0)
        pc.elapse(seconds: 1e15)
        XCTAssertEqual(pc.pendingElapse, UInt64(GuestClock.longestElapse * pc.guestHertz))
    }

    /// **Depuis l'instantané** ; sans heure, rien.
    func testSinceTheSnapshot() {
        let pc = machine()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        pc.elapse(since: nil, now: now)
        XCTAssertEqual(pc.pendingElapse, 0)
        pc.elapse(since: now.addingTimeInterval(-90), now: now)
        XCTAssertEqual(pc.pendingElapse, UInt64(90 * pc.guestHertz))
        pc.elapse(since: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(pc.pendingElapse, UInt64(90 * pc.guestHertz), "un instantané « du futur » ne fait rien")
    }

    /// **Les échéances manquées d'un pas se fondent en une** : dix secondes
    /// d'horloge à 250 Hz ne font pas deux mille cinq cents interruptions,
    /// mais une, et l'invité lit l'heure au compteur.
    func testMissedTicksBecomeOne() throws {
        let pc = machine()
        pc.core.devices.reload = 4773
        pc.core.devices.reloadedAt = pc.core.ticks
        try pc.core.serviceInterrupts()
        pc.core.devices.primary.request = 0
        pc.elapse(seconds: 10)
        _ = pc.takeElapseStep()
        try pc.core.serviceInterrupts()
        XCTAssertEqual(pc.core.devices.primary.request & 1, 1, "l'horloge sonne")
        XCTAssertEqual(pc.core.devices.raised, pc.core.devices.expirations(at: pc.core.ticks))
        pc.core.devices.primary.request = 0
        try pc.core.serviceInterrupts()
        XCTAssertEqual(pc.core.devices.primary.request & 1, 0, "et une seule fois")
    }

    /// **Un invité qui dort paie tout pendant `run`**, un pas par tranche, et
    /// sans que la cadence murale lui fasse dormir l'heure : le temps du
    /// dehors n'est ni du budget ni une avance sur le mur. Une heure, trois
    /// cent soixante pas, et moins de quatre cents tranches de budget.
    func testASleepingGuestCatchesUpDuringRun() throws {
        let pc = try X86PacingTests.sleeper(pacing: true)
        let before = clock(pc)
        pc.elapse(seconds: 3600)
        let started = Date()
        XCTAssertEqual(pc.run(instructionBudget: 400 * 200_000), .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "une heure ne se dort pas")
        XCTAssertEqual(pc.pendingElapse, 0, "tout est payé")
        XCTAssertGreaterThanOrEqual(clock(pc) - before, UInt64(3600 * pc.guestHertz))
    }

    /// L'avance payée passe dans l'instantané.
    func testTheAdvanceIsSaved() throws {
        let pc = machine()
        pc.elapse(seconds: 86_400)
        _ = drain(pc)
        let resumed = machine()
        try resumed.restore(pc.snapshot())
        XCTAssertEqual(clock(resumed), clock(pc))
    }
}
