import XCTest
@testable import WisqVM

/// L'horloge du PC : voir `X86CMOSClock`. Lue comme la lit Linux
/// (`mc146818_get_time`) : l'index sur 0x70, la donnée sur 0x71.
final class X86CMOSClockTests: XCTestCase {
    /// Le 30 octobre 2026, 17 h 05 min 09 s UTC, un vendredi.
    static let moment: Date = {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 10, 30, 17, 5, 9)
        return X86CMOSClock.utc.date(from: parts) ?? Date()
    }()

    static func clock() -> X86CMOSClock {
        var clock = X86CMOSClock()
        clock.fixedHostTime = moment
        return clock
    }

    static func read(_ clock: inout X86CMOSClock, _ register: UInt8) -> UInt8 {
        clock.select(register)
        return clock.read()
    }

    /// **La date de l'hôte, en BCD**, telle qu'un BIOS la laisse : l'invité
    /// démarre au bon jour, et sa pile est bonne.
    func testTheGuestReadsTheHostDateInBCD() {
        var clock = Self.clock()
        XCTAssertEqual(Self.read(&clock, 0x00), 0x09)
        XCTAssertEqual(Self.read(&clock, 0x02), 0x05)
        XCTAssertEqual(Self.read(&clock, 0x04), 0x17)
        XCTAssertEqual(Self.read(&clock, 0x06), 0x06, "vendredi : le dimanche vaut un")
        XCTAssertEqual(Self.read(&clock, 0x07), 0x30)
        XCTAssertEqual(Self.read(&clock, 0x08), 0x10)
        XCTAssertEqual(Self.read(&clock, 0x09), 0x26)
        XCTAssertEqual(Self.read(&clock, 0x32), 0x20)
        XCTAssertEqual(Self.read(&clock, 0x0A) & 0x80, 0, "jamais « mise à jour en cours »")
        XCTAssertEqual(Self.read(&clock, 0x0B), 0x02, "24 heures, BCD")
        XCTAssertEqual(Self.read(&clock, 0x0D), 0x80, "l'heure est valide")
        XCTAssertEqual(Self.read(&clock, 0x0C), 0)
        // Le bit 7 de l'index coupe les NMI ; il ne change pas le registre.
        clock.select(0x80 | 0x09)
        XCTAssertEqual(clock.read(), 0x26)
    }

    /// **Le binaire, et les douze heures**, quand le registre B les demande.
    func testBinaryAndTwelveHourModes() {
        var clock = Self.clock()
        clock.select(0x0B)
        clock.write(X86CMOSClock.binary)
        XCTAssertEqual(Self.read(&clock, 0x04), 5 | 0x80, "5 h de l'après-midi")
        XCTAssertEqual(Self.read(&clock, 0x09), 26)
        clock.select(0x0B)
        clock.write(X86CMOSClock.binary | X86CMOSClock.twentyFourHours)
        XCTAssertEqual(Self.read(&clock, 0x04), 17)
        XCTAssertEqual(clock.encoded(0, register: 0x04), 0)
        clock.statusB = 0
        XCTAssertEqual(clock.encoded(0, register: 0x04), 0x12, "minuit s'écrit 12 du matin")
        XCTAssertEqual(clock.decoded(0x12, register: 0x04), 0)
        XCTAssertEqual(clock.decoded(0x92, register: 0x04), 12, "midi")
    }

    /// **Régler l'horloge** (`hwclock --systohc`) : SET, les registres, SET
    /// retiré. L'heure de l'invité suit, et l'hôte n'est pas touché ; pendant
    /// le réglage, la lecture rend ce qui a été écrit.
    func testTheGuestSetsTheClock() {
        var clock = Self.clock()
        clock.select(0x0B)
        clock.write(0x02 | X86CMOSClock.set)
        for (register, value) in [(UInt8(0x00), UInt8(0x00)), (0x02, 0x30), (0x04, 0x08),
                                  (0x07, 0x01), (0x08, 0x01), (0x09, 0x27)] {
            clock.select(register)
            clock.write(value)
        }
        XCTAssertEqual(Self.read(&clock, 0x09), 0x27, "relu tel qu'écrit pendant le réglage")
        clock.select(0x0B)
        clock.write(0x02)
        var expected = DateComponents()
        (expected.year, expected.month, expected.day, expected.hour, expected.minute) = (2027, 1, 1, 8, 30)
        let wanted = X86CMOSClock.utc.date(from: expected) ?? Date()
        XCTAssertEqual(clock.guestTime.timeIntervalSince(wanted), 0, accuracy: 0.001)
        XCTAssertEqual(Self.read(&clock, 0x09), 0x27)
        XCTAssertEqual(Self.read(&clock, 0x04), 0x08)
        // Une heure écrite sans SET prend effet tout de suite, le reste gardé.
        clock.select(0x04)
        clock.write(0x10)
        XCTAssertEqual(Self.read(&clock, 0x04), 0x10)
        XCTAssertEqual(Self.read(&clock, 0x09), 0x27)
    }

    /// Le reste de la mémoire CMOS se relit tel qu'écrit.
    func testTheRestOfTheMemoryIsKept() {
        var clock = Self.clock()
        clock.select(0x0F)
        clock.write(0xA5)
        XCTAssertEqual(Self.read(&clock, 0x0F), 0xA5)
        clock.select(0x0D)
        clock.write(0)
        XCTAssertEqual(Self.read(&clock, 0x0D), 0x80, "le registre D ne s'écrit pas")
    }

    /// **Par les ports de la machine**, comme le noyau y accède.
    func testThroughThePorts() {
        let machine = X86Machine(ramSize: 16 << 20, onOutput: { _ in })
        machine.core.cmos.fixedHostTime = Self.moment
        machine.core.portWrite(0x70, 1, 0x09)
        XCTAssertEqual(machine.core.portRead(0x71, 1), 0x26)
        machine.core.portWrite(0x70, 1, 0x08)
        XCTAssertEqual(machine.core.portRead(0x71, 1), 0x10)
        machine.core.portWrite(0x70, 1, 0x0F)
        machine.core.portWrite(0x71, 1, 0x5A)
        XCTAssertEqual(machine.core.portRead(0x71, 1), 0x5A)
    }
}
