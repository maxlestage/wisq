import Foundation
import XCTest
@testable import WisqVM

/// **L'écran revient avec la machine** : voir la section `screenSection` de
/// `X86Machine.snapshot`.
///
/// Une capture du téléphone : une machine reprise, la console qui répond, et
/// l'écran noir, hormis le curseur que la console du noyau repeint en
/// clignotant. Les pixels vivent hors de la RAM, et l'instantané ne les
/// portait pas.
final class X86ScreenSnapshotTests: XCTestCase {
    static func machine(screen: (width: Int, height: Int)?) throws -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        if let screen { try machine.attachDisplay(width: screen.width, height: screen.height) }
        return machine
    }

    /// Un écran peint de quelques pixels, à des endroits reconnaissables.
    static func painted() throws -> X86Machine {
        let machine = try Self.machine(screen: (64, 48))
        let display = try XCTUnwrap(machine.display)
        display.write(0, 4, 0x00AA_BBCC)
        display.write(display.byteCount / 2, 4, 0x0011_2233)
        display.write(display.byteCount - 4, 4, 0x00FF_FFFF)
        return machine
    }

    /// **L'image revient telle quelle**, et la révision avance : la vue qui
    /// regardait l'écran repeint.
    func testTheScreenComesBack() throws {
        let saved = try Self.painted()
        let resumed = try Self.machine(screen: (64, 48))
        let before = try XCTUnwrap(resumed.display).revision
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.display?.snapshot(), saved.display?.snapshot())
        XCTAssertNotEqual(resumed.display?.revision, before, "la vue doit repeindre")
        XCTAssertEqual(resumed.snapshot(), saved.snapshot(), "et l'instantané se refait à l'identique")
    }

    /// **Un écran d'une autre taille ne se reprend pas** : la machine garde le
    /// sien, et la reprise aboutit quand même.
    func testAScreenOfAnotherSizeIsLeftAlone() throws {
        let saved = try Self.painted()
        let resumed = try Self.machine(screen: (32, 24))
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.display?.snapshot(), [UInt8](repeating: 0, count: 32 * 24 * 4))
    }

    /// Une machine sans écran passe par-dessus la section, et retrouve tout
    /// le reste.
    func testAMachineWithoutAScreenSkipsIt() throws {
        let saved = try Self.painted()
        let resumed = try Self.machine(screen: nil)
        try resumed.restore(saved.snapshot())
        XCTAssertNil(resumed.display)
        XCTAssertEqual(resumed.core.instructionsPerTick, saved.core.instructionsPerTick)
    }

    /// **Un instantané d'avant l'écran** se reprend encore, sur une machine
    /// qui en a un : l'écran reste noir, comme avant.
    func testASnapshotWithoutTheScreenStillResumes() throws {
        let saved = try Self.machine(screen: nil)
        let resumed = try Self.machine(screen: (64, 48))
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.display?.snapshot(), [UInt8](repeating: 0, count: 64 * 48 * 4))
    }
}
