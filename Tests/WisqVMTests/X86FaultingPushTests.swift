import XCTest

@testable import WisqVM

/// Une instruction qui faute ne doit laisser aucune trace.
///
/// **Pourquoi ce fichier existe.** `push` descendait RSP *avant* de traduire
/// l'adresse où écrire. Une pile qui grandit tombe sur une page absente, le
/// processeur lève une faute, le noyau ajoute la page, et l'`IRETQ`
/// **recommence l'instruction fautive** — c'est une garantie du matériel. Avec
/// RSP déjà descendu, le `push` redescendait une seconde fois, et le programme
/// perdait huit octets de pile pour toujours. Son `ret` dépilait alors un mot
/// de trop et partait n'importe où.
///
/// C'est le défaut qui tuait `/init` : quatre fois sur quatre, dans trois
/// processus différents, le retour fautif dépilait exactement huit octets trop
/// bas. Le registre des mouvements de pile l'a montré en montrant un **trou** :
/// entre deux mouvements consécutifs, RSP descendait de huit octets sans
/// qu'aucune instruction ne l'ait fait — parce que l'instruction qui l'avait
/// fait avait fauté, et que le témoin ne note qu'après une exécution réussie.
final class X86FaultingPushTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let directory: UInt64 = 0x4000
    static let table: UInt64 = 0x5000
    static let program: UInt64 = 0x1000
    /// La pile démarre au premier octet d'une page présente : le `push` vise
    /// donc la page d'en dessous, qu'on laisse absente.
    static let stack: UInt64 = 0x8000
    static let below: UInt64 = 0x7000

    static let open = X86Core.present | X86Core.writable | X86Core.userAccessible

    /// Une pagination à quatre niveaux où toutes les pages sont ouvertes sauf
    /// celle qui est juste sous la pile.
    static func core(_ instructions: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(instructions, at: program)
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, directory | open)
        try memory.write(directory, 8, table | open)
        for page in stride(from: UInt64(0), to: UInt64(0x10000), by: 0x1000) {
            try memory.write(table &+ (page >> 12) * 8, 8,
                             page == below ? 0 : page | open)
        }
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = 0x33
        core.registers[4] = stack
        return core
    }

    /// Ouvre la page absente, comme le ferait un noyau qui agrandit la pile.
    static func mapTheMissingPage(_ core: X86Core) throws {
        try core.memory?.write(table &+ (below >> 12) * 8, 8, below | open)
    }

    /// **Le cœur du défaut.** Le `push` faute parce que la page d'en dessous
    /// est absente ; RSP doit être exactement là où il était.
    func testAPushThatFaultsLeavesTheStackPointerAlone() throws {
        var core = try Self.core([0x50])          // push %rax
        core.registers[0] = 0xDEAD
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.registers[4], Self.stack,
                       "une instruction qui faute ne laisse aucune trace")
    }

    /// Et le RIP non plus : le processeur doit revenir sur l'instruction
    /// fautive, pas sur la suivante.
    func testAPushThatFaultsLeavesTheProgramCounterAlone() throws {
        var core = try Self.core([0x50])
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.rip, Self.program)
    }

    /// **La preuve complète.** On faute, on cartographie la page comme le
    /// ferait un noyau, on recommence : la valeur atterrit huit octets sous le
    /// sommet d'origine, et pas seize.
    func testTheRestartedPushLandsWhereTheFirstAttemptAimed() throws {
        var core = try Self.core([0x50])
        core.registers[0] = 0xC0FFEE
        XCTAssertThrowsError(try core.run(budget: 1))

        try Self.mapTheMissingPage(core)
        _ = try core.run(budget: 1)

        XCTAssertEqual(core.registers[4], Self.stack &- 8,
                       "un seul mot empilé, pas deux")
        let written = try XCTUnwrap(core.memory).read(Self.stack &- 8, 8)
        XCTAssertEqual(written, 0xC0FFEE)
    }

    /// Le même défaut, vu par le retour : après la faute et le redémarrage, le
    /// `ret` doit retrouver ce que l'appel avait posé. C'est la forme exacte
    /// sous laquelle `/init` mourait.
    func testAReturnStillFindsWhatTheCallPromisedAcrossAFault() throws {
        // push %rax (faute) ; puis, une fois la page ouverte : pop %rbx
        var core = try Self.core([0x50, 0x5B])
        core.registers[0] = 0x1234_5678
        XCTAssertThrowsError(try core.run(budget: 2))
        try Self.mapTheMissingPage(core)
        _ = try core.run(budget: 2)

        XCTAssertEqual(core.registers[3], 0x1234_5678,
                       "le mot dépilé est celui qui avait été empilé")
        XCTAssertEqual(core.registers[4], Self.stack, "la pile est revenue à zéro net")
    }

    /// Un `call` empile son adresse de retour par le même chemin : lui aussi
    /// doit pouvoir fauter sans rien laisser.
    func testACallThatFaultsLeavesNothingBehind() throws {
        var core = try Self.core([0xE8, 0x00, 0x00, 0x00, 0x00])  // call +0
        XCTAssertThrowsError(try core.run(budget: 1))
        XCTAssertEqual(core.registers[4], Self.stack)
        XCTAssertEqual(core.rip, Self.program, "le call fautif n'a pas sauté")
    }
}
