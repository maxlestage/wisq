import XCTest

@testable import WisqVM

/// Les deux horloges de l'invité doivent avancer ensemble, y compris quand il
/// dort.
///
/// **Ce que la mesure a montré.** Alpine s'arrêtait sur « Mounting boot
/// media... » et n'atteignait jamais le « failed. » que QEMU imprime douze
/// secondes plus tard. Le rapport du contrôleur disait pourtant que tout
/// passait : horloge armée, interruptions permises, ligne zéro démasquée,
/// base de vecteur `0x30` — et cent millions de tours d'attente. Les
/// interruptions **étaient** livrées : entre deux mesures à cent et quatre
/// cents millions de tours, le noyau avait retiré deux millions et demi
/// d'instructions de plus, soit les gestionnaires de sept cents battements.
///
/// Ce qui n'avançait pas, c'était le **temps**. Le noyau avait choisi le TSC
/// comme source (`Switched to clocksource tsc`), et `RDTSC` rendait le compteur
/// d'instructions *retirées* — qui ne bouge pas pendant un `HLT`. Le 8253,
/// lui, compte aussi les tours d'attente. Chaque battement réveillait le
/// noyau, qui lisait l'heure, la trouvait inchangée, et se rendormait : une
/// temporisation de douze secondes ne peut pas expirer sur une horloge figée.
///
/// La règle : **`RDTSC` et le 8253 lisent le même temps**, celui de
/// `X86Core.ticks` — le noyau a étalonné l'un contre l'autre au démarrage
/// (« Detected 14.318 MHz », douze fois le 8253), et ils n'ont pas le droit de
/// diverger ensuite.
final class X86GuestClockTests: XCTestCase {
    /// `rdtsc ; hlt ; rdtsc`. Sans IDT, rien ne réveille le `hlt` : le second
    /// `rdtsc` ne s'exécute que quand on relève la machine à la main, après
    /// une attente dont la longueur est connue.
    static func clockReader() throws -> X86Core {
        let memory = X86Memory(size: 0x1000, base: 0)
        try memory.load([0x0F, 0x31, 0xF4, 0x0F, 0x31], at: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: 0, memory: memory)
        core.flags |= X86Core.Flag.interrupt
        core.devices.reload = 0xFFFF
        return core
    }

    static func timeStamp(_ core: X86Core) -> UInt64 {
        (core.registers[2] << 32) | (core.registers[0] & 0xFFFF_FFFF)
    }

    /// Le défaut mesuré : dormir cinq cents tours, et lire une heure qui n'a
    /// avancé que d'une instruction.
    func testTheTimeStampCounterAdvancesWhileTheMachineSleeps() throws {
        var core = try Self.clockReader()
        _ = try core.run(budget: 10, waiting: 500)
        XCTAssertTrue(core.outOfPatience, "la machine a dormi tout son temps")
        XCTAssertEqual(core.idled, 500)
        let before = Self.timeStamp(core)

        core.halted = false
        _ = try core.run(budget: 1)
        let after = Self.timeStamp(core)
        XCTAssertGreaterThanOrEqual(after &- before, 500,
                                    "cinq cents tours d'attente valent au moins cinq cents cycles")
    }

    /// Et ce n'est pas *un* temps qui avance, c'est **le même** que celui du
    /// 8253 : `RDTSC` lit exactement ce que `ticks` compte, avant division.
    func testTheTimeStampCounterAndTheTimerReadTheSameTime() throws {
        var core = try Self.clockReader()
        _ = try core.run(budget: 10, waiting: 300)
        core.halted = false
        _ = try core.run(budget: 1)
        // Le `rdtsc` lit l'heure **avant** de se retirer lui-même : d'où le
        // un de moins.
        let read = Self.timeStamp(core)
        XCTAssertEqual(read, core.retired &+ core.idled &- 1)
        XCTAssertEqual(core.ticks, (read &+ 1) / X86LegacyDevices.instructionsPerTick,
                       "le 8253 bat une fois par douze cycles du TSC, comme le noyau l'a étalonné")
    }
}
