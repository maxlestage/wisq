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
        for _ in 0...(X86Core.ringTripLimit + 3) {
            core.registers[4] = Self.stack
            // Le départ est à l'adresse où le cœur se trouve : la reprise y
            // est donc, et le décalage reste inexpliqué.
            core.leavingRingThree(at: Self.program, cause: .fault)
            core.registers[4] = Self.stack &- 8
            core.returningToRingThree()
        }
        XCTAssertEqual(core.ringTrips.count, X86Core.ringTripLimit)
    }

    // MARK: - Ce qui explique un décalage, et ce qui ne l'explique pas

    /// **Un autre espace d'adressage est un autre programme.** Comparer sa
    /// pile à celle du précédent ne veut rien dire, et compter ce décalage
    /// comme un défaut serait accuser à tort.
    func testAShiftAcrossAddressSpacesIsExplainedByTheOtherProgram() throws {
        var core = try Self.core([0x90])
        core.registers[4] = Self.stack
        core.leavingRingThree(at: Self.program, cause: .systemCall)
        core.system.control[3] = 0x9_9000
        core.registers[4] = Self.stack &- 0x400
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.otherProgram, 1)
        XCTAssertEqual(core.ringPassages.unexplained, 0)
        XCTAssertTrue(core.ringTrips.isEmpty, "il n'accuse personne")
    }

    /// **Une reprise ailleurs est un flot détourné.** Aucune instruction x86
    /// ne fait plus de quinze octets : au-delà, ce n'est plus une reprise,
    /// c'est le noyau qui envoie le programme autre part — un gestionnaire de
    /// signal — et déplacer la pile est alors son droit.
    func testAShiftWithAResumptionElsewhereIsExplainedByTheRedirection() throws {
        var core = try Self.core([0x90])
        core.registers[4] = Self.stack
        core.leavingRingThree(at: Self.program, cause: .interrupt)
        core.rip = Self.program &+ 0x2000
        core.registers[4] = Self.stack &- 0x80
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.redirected, 1)
        XCTAssertEqual(core.ringPassages.unexplained, 0)
        XCTAssertTrue(core.ringTrips.isEmpty)
    }

    /// **Et une continuation reste une reprise.** Un appel système repart
    /// juste après l'instruction : quinze octets sont la limite, pas zéro.
    /// Confondre les deux ferait passer tout appel système décalé pour un
    /// détournement, et le défaut recherché est précisément là.
    func testAContinuationJustAfterTheInstructionIsStillAResumption() throws {
        var core = try Self.core([0x90])
        core.registers[4] = Self.stack
        core.leavingRingThree(at: Self.program, cause: .systemCall)
        core.rip = Self.program &+ 2  // syscall fait deux octets
        core.registers[4] = Self.stack &- 8
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.unexplained, 1)
        XCTAssertEqual(core.ringTrips.count, 1, "et celui-là, on le garde")
    }

    /// Un rapport vide a deux causes possibles — tout allait bien, ou rien
    /// n'a regardé. Le compte les sépare, et c'est sa seule raison d'être.
    func testAPassageThatChangesNothingIsStillCounted() throws {
        var core = try Self.core([0x90])
        for _ in 0..<5 {
            core.registers[4] = Self.stack
            core.leavingRingThree(at: 0x1000, cause: .systemCall)
            core.returningToRingThree()
        }
        XCTAssertTrue(core.ringTrips.isEmpty, "aucune pile n'a bougé")
        XCTAssertEqual(core.ringPassages.total, 5)
        XCTAssertEqual(core.ringPassages.systemCalls, 5)
        XCTAssertEqual(core.ringPassages.shifted, 0)
    }

    func testATallyThatSawNothingSaysSoRatherThanSayingZero() {
        XCTAssertEqual(X86Core.RingTally().description,
                       "aucun — le témoin n'a jamais été appelé")
    }

    func testTheCountSeparatesTheThreeCauses() throws {
        var core = try Self.core([0x90])
        for cause in [X86Core.RingTrip.Cause.systemCall, .fault, .fault,
                      .interrupt, .interrupt, .interrupt] {
            core.registers[4] = Self.stack
            core.leavingRingThree(at: 0x1000, cause: cause)
            core.returningToRingThree()
        }
        XCTAssertEqual(core.ringPassages.systemCalls, 1)
        XCTAssertEqual(core.ringPassages.faults, 2)
        XCTAssertEqual(core.ringPassages.interrupts, 3)
        XCTAssertEqual(core.ringPassages.total, 6)
    }

    /// Le rapport ne garde que seize décalages ; le compte, lui, les voit
    /// tous. Sans ça, « seize » serait indiscernable de « seize et quelques ».
    func testTheCountSeesTheShiftsTheReportCannotKeep() throws {
        var core = try Self.core([0x90])
        let many = X86Core.ringTripLimit + 4
        for _ in 0..<many {
            core.registers[4] = Self.stack
            core.leavingRingThree(at: Self.program, cause: .fault)
            core.registers[4] = Self.stack &- 8
            core.returningToRingThree()
        }
        XCTAssertEqual(core.ringTrips.count, X86Core.ringTripLimit)
        XCTAssertEqual(core.ringPassages.shifted, UInt64(many))
        XCTAssertEqual(core.ringPassages.total, UInt64(many))
    }

    /// Le témoin ne suit qu'un départ à la fois. Une faute pendant un appel
    /// système recouvre donc le départ en cours — ce qui est acceptable, mais
    /// doit se compter, sans quoi le total mentirait par omission.
    func testADepartureCoveredByAnotherIsCountedAsAbandoned() throws {
        var core = try Self.core([0x90])
        core.registers[4] = Self.stack
        core.leavingRingThree(at: 0x1000, cause: .systemCall)
        core.leavingRingThree(at: 0x2000, cause: .fault)
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.abandoned, 1)
        XCTAssertEqual(core.ringPassages.total, 1)
        XCTAssertEqual(core.ringPassages.faults, 1)
        XCTAssertEqual(core.ringPassages.systemCalls, 0)
    }

    func testTheTallySaysWhatItSawAndWhatItFound() throws {
        var core = try Self.core([0x90])
        core.registers[4] = Self.stack
        core.leavingRingThree(at: 0x1000, cause: .systemCall)
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.description,
                       "1 achevés (syscall 1, faute 0, interruption 0),"
                       + " aucun ne décale la pile")

        core.registers[4] = Self.stack
        core.leavingRingThree(at: 0x1000, cause: .fault)
        core.registers[4] = Self.stack &- 8
        core.returningToRingThree()
        XCTAssertEqual(core.ringPassages.description,
                       "2 achevés (syscall 1, faute 1, interruption 0),"
                       + " dont 1 décalent la pile (0 autre programme,"
                       + " 0 flot détourné, 1 inexpliqué)")
    }
}
