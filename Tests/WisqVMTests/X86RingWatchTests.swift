import XCTest

@testable import WisqVM

/// La pile d'un programme traverse-t-elle un passage d'anneau sans bouger ?
///
/// **Pourquoi ce témoin existe.** La pile d'ombre a rendu un chiffre
/// systématique : le `ret` qui envoie `/init` dans des données dépile un mot
/// situé **exactement huit octets** sous celui que l'appel avait posé — quatre
/// fois sur quatre, dans trois processus différents.
///
/// Le `ret` fautif est le dernier de `_Fork`, et la fonction est équilibrée.
/// Entre son entrée et sa sortie il y a deux appels, un `syscall`, et rien qui
/// puisse laisser un mot de trop. Reste un seul endroit où la pile d'un
/// programme peut bouger sans que le programme y soit pour quelque chose : le
/// **passage en anneau zéro et le retour**.
///
/// Le témoin ne juge pas. Un noyau a le droit de rendre une pile différente —
/// il le fait à chaque `execve`, à chaque signal, à chaque changement de tâche.
/// Le rapport dit ce qui a changé.
final class X86RingWatchTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000
    static let handler: UInt64 = 0x7000
    static let idt: UInt64 = 0x9000
    static let taskSegment: UInt64 = 0xC000
    static let kernelStackTop: UInt64 = 0xE000
    static let stack: UInt64 = 0x6000

    static func core(_ bytes: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        // Une porte pour le vecteur 14, et un TSS qui donne la pile du noyau.
        let low = (handler & 0xFFFF) | (UInt64(0x10) << 16)
            | (UInt64(0x8E) << 40) | ((handler & 0xFFFF_0000) << 32)
        try memory.write(idt &+ 14 * 16, 8, low)
        try memory.write(taskSegment &+ 4, 8, kernelStackTop)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.descriptorBases[1] = idt
        core.descriptorLimits[1] = 0xFFF
        core.taskSelector = 0x28
        core.taskBase = taskSegment
        core.taskLimit = 0x67
        core.segments[1] = 0x33
        core.registers[4] = stack
        core.canonicalWatchArmed = true
        return core
    }

    /// **Une pile rendue telle quelle ne laisse rien.** C'est le cas courant :
    /// il y en a des millions par démarrage, et les retenir noierait le seul
    /// qui compte.
    func testAnUntouchedStackIsNotWorthReporting() throws {
        var core = try Self.core([0x90])
        core.leavingRingThree(at: Self.program, cause: .systemCall)
        core.returningToRingThree()
        XCTAssertTrue(core.ringTrips.isEmpty)
    }

    /// Et une pile rendue décalée est nommée, avec le sens et l'ampleur du
    /// décalage. Négatif veut dire « plus bas », donc plus profond — le sens
    /// qui fait qu'un `ret` dépile un mot de trop.
    func testAShiftedStackIsNamedWithItsDirection() throws {
        var core = try Self.core([0x90])
        core.leavingRingThree(at: Self.program, cause: .systemCall)
        core.registers[4] = Self.stack &- 8
        core.rip = Self.program &+ 2
        core.returningToRingThree()
        let trip = try XCTUnwrap(core.ringTrips.first)
        XCTAssertEqual(trip.leaving, Self.stack)
        XCTAssertEqual(trip.returning, Self.stack &- 8)
        XCTAssertEqual(trip.shift, -8, "plus bas de huit octets")
        XCTAssertEqual(trip.cause, .systemCall)
        XCTAssertEqual(trip.resumed, Self.program &+ 2)
    }

    /// Un `syscall` d'anneau trois note son départ, et le retour compare.
    func testASystemCallIsADeparture() throws {
        // syscall
        var core = try Self.core([0x0F, 0x05])
        core.system.modelSpecific[X86SystemState.efer] =
            X86SystemState.longModeEnable | X86SystemState.systemCallEnable
        core.system.modelSpecific[X86SystemState.star] = UInt64(0x10) << 32
        core.system.modelSpecific[X86SystemState.longSystemCallTarget] = Self.handler
        _ = try? core.run(budget: 1)
        XCTAssertEqual(core.privilege, 0, "on est bien passé en anneau zéro")
        XCTAssertNotNil(core.ringDeparture)
        XCTAssertEqual(core.ringDeparture?.cause, .systemCall)
        XCTAssertEqual(core.ringDeparture?.stack, Self.stack)
    }

    /// Une faute prise en anneau trois aussi, et elle est distinguée d'une
    /// interruption de matériel : le code d'erreur est ce qui les sépare.
    func testAFaultIsADepartureAndIsToldFromAnInterrupt() throws {
        var core = try Self.core([0x90])
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        XCTAssertEqual(core.ringDeparture?.cause, .fault)

        var other = try Self.core([0x90])
        // Le vecteur 32 est une interruption de matériel : pas de code d'erreur.
        let low = (Self.handler & 0xFFFF) | (UInt64(0x10) << 16)
            | (UInt64(0x8E) << 40) | ((Self.handler & 0xFFFF_0000) << 32)
        try other.memory?.write(Self.idt &+ 32 * 16, 8, low)
        XCTAssertTrue(try other.enter(32, errorCode: 0))
        XCTAssertEqual(other.ringDeparture?.cause, .interrupt)
    }

    /// Le noyau qui passe d'anneau zéro à anneau zéro n'est pas un départ :
    /// sa pile est la sienne, et la comparer à celle d'un programme n'aurait
    /// pas de sens.
    func testTheKernelInterruptingItselfIsNotADeparture() throws {
        var core = try Self.core([0x90])
        core.segments[1] = 0x10
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        XCTAssertNil(core.ringDeparture)
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = try Self.core([0x90])
        core.canonicalWatchArmed = false
        XCTAssertTrue(try core.enter(14, errorCode: 0))
        XCTAssertNil(core.ringDeparture)
    }

    func testTheReportStopsAtItsLimit() throws {
        var core = try Self.core([0x90])
        for index in 0...(X86Core.ringTripLimit + 3) {
            core.registers[4] = Self.stack
            core.leavingRingThree(at: UInt64(index), cause: .fault)
            core.registers[4] = Self.stack &- 8
            core.returningToRingThree()
        }
        XCTAssertEqual(core.ringTrips.count, X86Core.ringTripLimit)
    }
}
