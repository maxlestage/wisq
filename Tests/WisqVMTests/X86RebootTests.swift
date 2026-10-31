import Foundation
import XCTest
@testable import WisqVM

/// **Redémarrer une machine PC** : voir `X86PS2Controller.resetRequested`.
///
/// Sur le téléphone, Chimera Linux arrêté devant « boot failure? », on a
/// tapé `r`. Le noyau a écrit « reboot: Restarting system », puis la machine
/// s'est arrêtée sur « le groupe 5 /5 » : sans ACPI ni 8042 qui réponde, il
/// était passé au saut long vers le BIOS.
final class X86RebootTests: XCTestCase {
    /// **L'impulsion de Linux** : `0xFE` sur le port de commande du 8042.
    func testThePulseLinuxSendsResetsTheProcessor() {
        var controller = X86PS2Controller()
        controller.writeCommand(0xFE)
        XCTAssertTrue(controller.resetRequested)
    }

    /// Les autres commandes ne tirent pas la ligne : `0xFF` n'envoie aucune
    /// impulsion, les autres de la plage n'en envoient pas sur le bit zéro,
    /// et l'autotest du contrôleur ou l'écriture de la configuration ne
    /// touchent pas le port de sortie.
    func testOtherCommandsLeaveTheLineAlone() {
        for command: UInt8 in [0xFF, 0xF1, 0xFD, 0xAA, 0x20, 0x60, 0xA7, 0xAD, 0xD0] {
            var controller = X86PS2Controller()
            controller.writeCommand(command)
            XCTAssertFalse(controller.resetRequested, String(command, radix: 16))
        }
    }

    /// **Le port de sortie écrit d'un coup** (`0xD1`) : le bit zéro à zéro
    /// remet à zéro, à un il laisse tourner — c'est ce que Linux écrit au
    /// démarrage pour ouvrir la porte A20, `0xDF`.
    func testWritingTheOutputPortResetsOnlyWithBitZeroLow() {
        var running = X86PS2Controller()
        running.writeCommand(0xD1)
        running.writeData(0xDF)
        XCTAssertFalse(running.resetRequested)
        var reset = X86PS2Controller()
        reset.writeCommand(0xD1)
        reset.writeData(0xDE)
        XCTAssertTrue(reset.resetRequested)
    }

    /// **Le cœur s'arrête sur l'impulsion même** : ce qui la suit ne tourne
    /// pas, même avec un budget immense. Arrêté en fin de tranche, le noyau
    /// avait le temps de passer au BIOS.
    func testTheCoreStopsOnThePulse() throws {
        let memory = X86Memory(size: 0x2000, base: 0)
        try memory.load([0xB0, 0xFE, 0xE6, 0x64, 0xB0, 0x01, 0xEB, 0xFE], at: 0x1000)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x1000, memory: memory)
        XCTAssertThrowsError(try core.run(budget: 1_000_000)) { error in
            XCTAssertEqual(error as? X86Core.Reset, X86Core.Reset())
        }
        XCTAssertEqual(core.registers[0] & 0xFF, 0xFE, "le `mov $1, %al` qui suit n'a pas tourné")
    }

    /// **La machine rend `.reboot`**, et la machine locale de l'application
    /// aussi : `mov $0xfe, %al ; out %al, $0x64 ; jmp .`. Sans l'impulsion,
    /// la même boucle tourne jusqu'au bout du budget.
    func testTheMachineAsksToRestart() throws {
        let rebooting = X86Machine(onOutput: { _ in })
        try rebooting.load(kernelImage: X86LocalMachineTests.kernel([0xB0, 0xFE, 0xE6, 0x64, 0xEB, 0xFE]))
        XCTAssertEqual(rebooting.run(instructionBudget: 1_000_000), .reboot)

        let guest = X86Machine(onOutput: { _ in })
        try guest.load(kernelImage: X86LocalMachineTests.kernel([0xB0, 0xFE, 0xE6, 0x64, 0xEB, 0xFE]))
        XCTAssertEqual(guest.runGuest(instructionBudget: 1_000_000), .reboot)

        let looping = X86Machine(onOutput: { _ in })
        try looping.load(kernelImage: X86LocalMachineTests.kernel([0xB0, 0xFF, 0xE6, 0x64, 0xEB, 0xFE]))
        XCTAssertEqual(looping.run(instructionBudget: 1_000_000), .stopped)
    }
}
