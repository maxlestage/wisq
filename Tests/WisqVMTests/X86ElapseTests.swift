import XCTest
@testable import WisqVM

/// Le temps passé hors de la machine : voir `X86Machine.elapse(seconds:)`.
final class X86ElapseTests: XCTestCase {
    private func machine() -> X86Machine {
        X86Machine(ramSize: 16 << 20, onOutput: { _ in })
    }

    private func clock(_ machine: X86Machine) -> UInt64 { machine.core.retired &+ machine.core.idled }

    /// **Une heure dehors, une heure de plus au compteur** de l'invité — au
    /// rythme où son noyau l'a étalonné, le compteur d'horodatage et le 8253
    /// ensemble.
    func testAnHourOutsideIsAnHourInside() {
        let pc = machine()
        let before = clock(pc)
        let ticks = pc.core.ticks
        pc.elapse(seconds: 3600)
        XCTAssertEqual(clock(pc) - before, UInt64(3600 * pc.guestHertz))
        XCTAssertEqual(pc.core.ticks - ticks, 3600 * 1_193_182, "le 8253 avance d'autant")
    }

    /// Le temps de l'invité ne recule pas, et un écart absurde ne déborde
    /// pas.
    func testTimeNeverGoesBackNorOverflows() {
        let pc = machine()
        let before = clock(pc)
        pc.elapse(seconds: -600)
        pc.elapse(seconds: .nan)
        pc.elapse(seconds: .infinity)
        XCTAssertEqual(clock(pc), before)
        pc.elapse(seconds: 1e15)
        XCTAssertEqual(clock(pc) - before, UInt64(X86Machine.longestElapse * pc.guestHertz))
    }

    /// **Depuis l'heure de l'instantané** ; sans heure, rien.
    func testSinceTheSnapshot() {
        let pc = machine()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let before = clock(pc)
        pc.elapse(since: nil, now: now)
        XCTAssertEqual(clock(pc), before)
        pc.elapse(since: now.addingTimeInterval(-90), now: now)
        XCTAssertEqual(clock(pc) - before, UInt64(90 * pc.guestHertz))
        pc.elapse(since: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(clock(pc) - before, UInt64(90 * pc.guestHertz), "un instantané « du futur » ne fait rien")
    }

    /// **Les échéances manquées se fondent en une** : trois jours d'horloge à
    /// 250 Hz ne font pas soixante-cinq mille interruptions à livrer, mais
    /// une, et l'invité lit l'heure au compteur.
    func testMissedTicksBecomeOne() throws {
        let pc = machine()
        pc.core.devices.reload = 4773
        pc.core.devices.reloadedAt = pc.core.ticks
        try pc.core.serviceInterrupts()
        pc.core.devices.primary.request = 0
        pc.elapse(seconds: 3 * 86_400)
        try pc.core.serviceInterrupts()
        XCTAssertEqual(pc.core.devices.primary.request & 1, 1, "l'horloge sonne")
        XCTAssertEqual(pc.core.devices.raised, pc.core.devices.expirations(at: pc.core.ticks))
        pc.core.devices.primary.request = 0
        try pc.core.serviceInterrupts()
        XCTAssertEqual(pc.core.devices.primary.request & 1, 0, "et une seule fois")
    }

    /// L'avance passe dans l'instantané : une machine reprise puis
    /// resauvée ne la perd pas.
    func testTheAdvanceIsSaved() throws {
        let pc = machine()
        pc.elapse(seconds: 86_400)
        let resumed = machine()
        try resumed.restore(pc.snapshot())
        XCTAssertEqual(clock(resumed), clock(pc))
    }
}
