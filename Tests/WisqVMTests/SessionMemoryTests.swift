import Foundation
import XCTest
@testable import WisqVM

/// **Une session reprise garde sa mémoire.** Voir `SessionMemory` : une
/// machine construite à la taille réglée refusait l'instantané d'une autre
/// taille, et l'application démarrait à neuf par-dessus la session.
final class SessionMemoryTests: XCTestCase {
    static let gibibyte = 1 << 30

    /// Une machine PC sauvée dit sa taille, sans être reprise.
    func testAPCSnapshotNamesItsMemory() throws {
        let machine = try X86PacingTests.sleeper(pacing: false)
        _ = machine.run(instructionBudget: 10_000)
        let saved = machine.snapshot()
        XCTAssertEqual(SessionMemory.savedRAMSize(saved, core: .x86_64), X86Machine.minimumRAMSize)

        let bigger = X86Machine(ramSize: 192 << 20, onOutput: { _ in })
        XCTAssertEqual(SessionMemory.savedRAMSize(bigger.snapshot(), core: .x86_64), 192 << 20)
    }

    /// La machine RISC-V aussi : sa mémoire suit les mots du cœur.
    func testARISCVSnapshotNamesItsMemory() {
        let machine = LinuxMachine(ramSize: 32 << 20, onOutput: { _ in })
        XCTAssertEqual(SessionMemory.savedRAMSize(machine.snapshot(), core: .riscv32), 32 << 20)
    }

    /// Ce qui n'est pas un instantané n'a pas de taille : c'est un démarrage
    /// à neuf, comme avant.
    func testWhatIsNotASnapshotHasNoSize() throws {
        let machine = try X86PacingTests.sleeper(pacing: false)
        let saved = machine.snapshot()
        XCTAssertNil(SessionMemory.savedRAMSize(Data("pas un instantané".utf8), core: .x86_64))
        XCTAssertNil(SessionMemory.savedRAMSize(saved.prefix(64), core: .x86_64))
        XCTAssertNil(SessionMemory.savedRAMSize(Data(), core: .riscv32))
        XCTAssertEqual(SessionMemory.choose(fresh: 512 << 20, saved: nil, room: Self.gibibyte), .boot(512 << 20))
    }

    /// **La session l'emporte sur le réglage**, plus grande comme plus
    /// petite, dès qu'elle tient dans ce qui est libre.
    func testASessionThatFitsImposesItsSize() {
        let room = 4 * Self.gibibyte
        XCTAssertEqual(SessionMemory.choose(fresh: 512 << 20, saved: 2 * Self.gibibyte, room: room),
                       .resume(2 * Self.gibibyte))
        XCTAssertEqual(SessionMemory.choose(fresh: 2 * Self.gibibyte, saved: 512 << 20, room: room),
                       .resume(512 << 20))
        XCTAssertEqual(SessionMemory.choose(fresh: 512 << 20, saved: room, room: room), .resume(room))
    }

    /// Une session qui ne tient plus est refusée, et nommée avec ses deux
    /// nombres : jamais remplacée par un démarrage à neuf.
    func testASessionThatNoLongerFitsIsRefusedNotReplaced() {
        let room = 3 * Self.gibibyte
        let choice = SessionMemory.choose(fresh: 2 * Self.gibibyte, saved: 4 * Self.gibibyte, room: room)
        XCTAssertEqual(choice, .tooLittleRoom(saved: 4 * Self.gibibyte, room: room))
        let text = SessionMemory.explanation(saved: 4 * Self.gibibyte, room: room, name: "fedora.qcow2")
        XCTAssertTrue(text.contains("4096 Mo"), text)
        XCTAssertTrue(text.contains("3072 Mo"), text)
        XCTAssertTrue(text.contains("fedora.qcow2"), text)
        XCTAssertTrue(text.contains("gardée"), text)
    }

    /// **Le bout à bout.** La taille réglée refuse l'instantané ; la taille
    /// que `SessionMemory` choisit le reprend.
    func testTheChosenSizeIsOneTheSnapshotAccepts() throws {
        let saved = X86Machine(ramSize: 192 << 20, onOutput: { _ in }).snapshot()
        let setting = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertThrowsError(try setting.restore(saved), "à la taille réglée, la session est refusée")

        let choice = SessionMemory.choose(
            fresh: X86Machine.minimumRAMSize,
            saved: SessionMemory.savedRAMSize(saved, core: .x86_64), room: Self.gibibyte)
        guard case .resume(let size) = choice else { return XCTFail("\(choice)") }
        let resumed = X86Machine(ramSize: size, onOutput: { _ in })
        XCTAssertNoThrow(try resumed.restore(saved))
        XCTAssertEqual(resumed.snapshot(), saved)
    }
}
