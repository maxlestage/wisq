import Foundation
import XCTest
@testable import WisqVM

/// **Dormir quand l'invité dort.** Une machine devant une personne laisse
/// l'appareil se reposer quand l'invité est arrêté sur `HLT`, au rythme de
/// l'horloge murale ; voir `X86Machine.pacesIdleToWallClock`.
final class X86PacingTests: XCTestCase {
    /// Un invité qui s'endort pour toujours : `sti ; hlt`, l'horloge armée et
    /// le 8259 tout masqué, donc rien ne le réveille et il attend tout son
    /// budget.
    static func sleeper(pacing: Bool) throws -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try (machine as GuestMachine).load(kernelImage: X86LocalMachineTests.kernel([0xFB, 0xF4]),
                                           commandLine: nil, initialRamdisk: nil)
        machine.core.devices.reload = 0xFFFF
        machine.pacesIdleToWallClock = pacing
        return machine
    }

    /// **Au rythme de l'horloge murale, et pas plus vite.** Trois dixièmes de
    /// seconde de sommeil de l'invité prennent au moins un quart de seconde à
    /// l'hôte quand la machine dort au rythme du mur, et quelques
    /// millisecondes sans.
    func testASleepingGuestSleepsAtTheWallClockPace() throws {
        let budget = UInt64(0.3 * X86Machine.guestHertz)
        let fast = try Self.sleeper(pacing: false)
        var start = Date()
        XCTAssertEqual(fast.run(instructionBudget: budget), .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15, "sans le réglage, rien n'attend")

        let paced = try Self.sleeper(pacing: true)
        start = Date()
        XCTAssertEqual(paced.run(instructionBudget: budget), .stopped)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.25, "le sommeil se dort")
        XCTAssertEqual(paced.core.idled, fast.core.idled, "et c'est la même machine")
    }

    /// **Un arrêt demandé réveille tout de suite**, sans attendre la fin du
    /// sommeil : la machine qui dort ne retient pas l'application qui ferme.
    func testStoppingWakesASleepingMachineAtOnce() throws {
        let machine = try Self.sleeper(pacing: true)
        let done = DispatchSemaphore(value: 0)
        let finished = Atomic(false)
        Thread.detachNewThread {
            _ = machine.run()
            finished.set(true)
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(finished.get(), "elle dort encore")
        let asked = Date()
        machine.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.2, "réveillée par l'arrêt, pas par la fin d'une tranche")
    }
}

/// Un booléen partagé entre deux fils, pour le test d'arrêt.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
}
