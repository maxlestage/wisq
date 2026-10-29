import XCTest

@testable import WisqVM

/// **L'horloge du PC rend l'heure**, et plus des zéros qui faisaient croire à
/// chaque invité qu'on était le premier janvier 2000.
final class X86RealTimeClockTests: XCTestCase {
    /// Le jeudi 29 octobre 2026, 13 h 07 min 45 s UTC.
    static let instant: Int64 = 1_793_279_265

    private func core() -> X86Core {
        var core = X86Core(memory: X86Memory(size: 0x1000))
        core.devices.clock.frozenAt = Self.instant
        return core
    }

    private func register(_ core: inout X86Core, _ index: UInt8) -> UInt8 {
        core.portWrite(0x70, 1, UInt64(index))
        return UInt8(truncatingIfNeeded: core.portRead(0x71, 1))
    }

    /// Les registres de l'heure, en BCD sur 24 heures, ce que Linux lit au
    /// démarrage avec le registre B tel que le BIOS l'a laissé.
    func testTheTimeIsTheHostsInBCD() {
        var core = core()
        XCTAssertEqual(register(&core, 0x00), 0x45, "secondes")
        XCTAssertEqual(register(&core, 0x02), 0x07, "minutes")
        XCTAssertEqual(register(&core, 0x04), 0x13, "heures")
        XCTAssertEqual(register(&core, 0x06), 0x05, "jeudi : 1 pour dimanche")
        XCTAssertEqual(register(&core, 0x07), 0x29, "jour")
        XCTAssertEqual(register(&core, 0x08), 0x10, "mois")
        XCTAssertEqual(register(&core, 0x09), 0x26, "année")
        XCTAssertEqual(register(&core, 0x32), 0x20, "siècle")
    }

    /// **La pile est bonne**, et aucune mise à jour n'est en cours : sans le
    /// bit VRT du registre D, Linux tient l'heure pour invalide ; avec UIP
    /// levé, il attend.
    func testTheClockSaysItIsValidAndNotUpdating() {
        var core = core()
        XCTAssertEqual(register(&core, 0x0D) & 0x80, 0x80)
        XCTAssertEqual(register(&core, 0x0A) & 0x80, 0)
        XCTAssertEqual(register(&core, 0x0B), 0x02, "24 heures, BCD")
    }

    /// Le registre B change le format : binaire, puis 12 heures avec le bit
    /// de l'après-midi.
    func testStatusBChangesTheFormat() {
        var core = core()
        core.portWrite(0x70, 1, 0x0B)
        core.portWrite(0x71, 1, 0x06)
        XCTAssertEqual(register(&core, 0x00), 45, "binaire")
        XCTAssertEqual(register(&core, 0x04), 13)
        core.portWrite(0x70, 1, 0x0B)
        core.portWrite(0x71, 1, 0x04)
        XCTAssertEqual(register(&core, 0x04), 0x81, "1 h de l'après-midi, en binaire")
    }

    /// Le reste de la CMOS se lit comme on l'a écrit ; les registres de
    /// l'heure, eux, restent ceux de l'hôte.
    func testTheRestOfTheCMOSIsMemory() {
        var core = core()
        core.portWrite(0x70, 1, 0x40)
        core.portWrite(0x71, 1, 0xA5)
        XCTAssertEqual(register(&core, 0x40), 0xA5)
        core.portWrite(0x70, 1, 0x00)
        core.portWrite(0x71, 1, 0x00)
        XCTAssertEqual(register(&core, 0x00), 0x45, "l'heure ne s'écrit pas")
        XCTAssertEqual(register(&core, 0x80 | 0x40), 0xA5, "le bit 7 de l'index masque la NMI, il ne compte pas")
    }

    /// Le calendrier, aux dates qui font trébucher : l'origine, une année
    /// bissextile, le passage du siècle.
    func testTheCalendarHoldsAtItsEdges() {
        typealias C = X86RealTimeClock.Calendar
        XCTAssertEqual(X86RealTimeClock.calendar(at: 0),
                       C(year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0, weekday: 5))
        XCTAssertEqual(X86RealTimeClock.calendar(at: 951_782_400),
                       C(year: 2000, month: 2, day: 29, hour: 0, minute: 0, second: 0, weekday: 3))
        XCTAssertEqual(X86RealTimeClock.calendar(at: 4_102_444_799),
                       C(year: 2099, month: 12, day: 31, hour: 23, minute: 59, second: 59, weekday: 5))
    }
}
