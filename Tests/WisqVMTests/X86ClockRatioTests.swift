import Foundation
import XCTest
@testable import WisqVM

/// **Le rapport de l'horloge appartient à la machine.** Une machine neuve
/// compte `X86LegacyDevices.instructionsPerTick` instructions par battement du
/// 8253 ; une machine reprise garde celui de son instantané, parce que son
/// noyau a étalonné son TSC contre le 8253 et que le 8253 garde ses échéances
/// en battements.
final class X86ClockRatioTests: XCTestCase {
    /// Une machine qui a tourné : son temps vaut quelques battements, et le
    /// 8253 a une échéance posée en battements.
    static func ranMachine(ratio: UInt64) throws -> X86Machine {
        let machine = try X86PacingTests.sleeper(pacing: false)
        machine.core.instructionsPerTick = ratio
        _ = machine.run(instructionBudget: 100_000)
        machine.core.devices.reloadedAt = machine.core.ticks
        return machine
    }

    /// Une machine neuve prend le rapport d'aujourd'hui, et le noyau le lit
    /// comme une fréquence : 288 × 1,193182 MHz. (C'était 72 jusqu'à ce que
    /// Chimera Linux en manque : voir `X86LegacyDevices.instructionsPerTick`.)
    func testANewMachineTakesTodaysRatio() throws {
        let machine = try X86PacingTests.sleeper(pacing: false)
        XCTAssertEqual(machine.core.instructionsPerTick, 288)
        XCTAssertEqual(machine.guestHertz, 343_636_416, accuracy: 1)
    }

    /// **Une machine reprise à soixante-douze y reste** : son noyau a étalonné
    /// son TSC à 86 MHz, et le passer à 344 ferait couler son temps quatre
    /// fois moins vite sous lui.
    func testAMachineSavedAtSeventyTwoResumesAtSeventyTwo() throws {
        let saved = try Self.ranMachine(ratio: 72)
        let resumed = try X86PacingTests.sleeper(pacing: false)
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.core.instructionsPerTick, 72)
        XCTAssertEqual(resumed.guestHertz, 85_909_104, accuracy: 1)
        XCTAssertEqual(resumed.core.ticks, saved.core.ticks)
    }

    /// Le rapport voyage dans l'instantané, et le temps de l'invité avec lui.
    func testTheRatioTravelsInTheSnapshot() throws {
        let saved = try Self.ranMachine(ratio: 50)
        let resumed = try X86PacingTests.sleeper(pacing: false)
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.core.instructionsPerTick, 50)
        XCTAssertEqual(resumed.core.ticks, (resumed.core.retired &+ resumed.core.idled) / 50,
                       "un battement vaut cinquante instructions sur cette machine-ci")
        XCTAssertEqual(resumed.core.ticks, saved.core.ticks)
        XCTAssertEqual(resumed.snapshot(), saved.snapshot())
    }

    /// **Un instantané d'avant la marque** a été écrit à trente-six : il
    /// revient à trente-six, avec le même nombre de battements, et le 8253
    /// ne voit pas son échéance partir dans le futur.
    func testASnapshotWithoutTheMarkResumesAtThirtySix() throws {
        let saved = try Self.ranMachine(ratio: 36)
        var bytes = [UInt8](saved.snapshot())
        // Sans disque, la section de l'horloge est la dernière : sa marque et
        // son rapport, seize octets. Les retirer rend l'instantané d'avant.
        let mark = withUnsafeBytes(of: Snapshot.clockSection.littleEndian, Array.init)
        XCTAssertEqual(Array(bytes[(bytes.count - 16)..<(bytes.count - 8)]), mark)
        bytes.removeLast(16)

        let resumed = try X86PacingTests.sleeper(pacing: false)
        try resumed.restore(Data(bytes))
        XCTAssertEqual(resumed.core.instructionsPerTick, X86LegacyDevices.legacyInstructionsPerTick)
        XCTAssertEqual(resumed.core.ticks, saved.core.ticks)
        XCTAssertEqual(resumed.core.devices.expirations(at: resumed.core.ticks), 0,
                       "l'échéance posée au dernier battement n'est pas encore due")
        // Et le réveil d'une machine endormie tombe dans la période, comptée
        // à trente-six : à soixante-douze, il partirait deux fois plus loin.
        XCTAssertLessThanOrEqual(resumed.core.idleStep(), UInt64(resumed.core.devices.reload) * 36)
    }

    /// Un rapport nul diviserait par zéro au premier battement : refusé, et
    /// la machine reste celle qu'elle était.
    func testANullRatioIsRefused() throws {
        let saved = try Self.ranMachine(ratio: 72)
        var bytes = [UInt8](saved.snapshot())
        bytes.replaceSubrange((bytes.count - 8)..<bytes.count, with: [UInt8](repeating: 0, count: 8))
        let resumed = try X86PacingTests.sleeper(pacing: false)
        XCTAssertThrowsError(try resumed.restore(Data(bytes)))
        XCTAssertEqual(resumed.core.instructionsPerTick, X86LegacyDevices.instructionsPerTick)
    }
}
