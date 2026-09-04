import XCTest

@testable import WisqVM

/// La pile d'ombre : un `ret` rend-il la main là où le `call` l'avait promis ?
///
/// **Pourquoi ce témoin existe.** Cinq corpus matériels ont épuisé le jeu
/// d'instructions du chargeur de l'invité, le vecteur auxiliaire s'est révélé
/// juste, et `/init` meurt quand même. Ce que le témoin des adresses
/// impossibles avait montré, c'est un `ret` qui rend la main **en dehors** de
/// l'objet dont il vient.
///
/// Or `ret` est prouvé : le corpus de branchement le tient sous ses trois
/// formes d'appel, avec des appels imbriqués. Si l'instruction est juste et
/// que l'adresse est fausse, **c'est que la pile a changé entre l'appel et le
/// retour** — et c'est cela qu'il faut voir arriver.
final class X86ReturnWatchTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000
    static let stack: UInt64 = 0x9000

    static func core(_ bytes: [UInt8], ring: UInt16 = 3) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = ring == 3 ? 0x33 : 0x10
        core.canonicalWatchArmed = true
        core.registers[4] = stack
        return core
    }

    /// `call +3` puis trois `nop`, puis `ret` : l'appel et le retour
    /// s'accordent.
    static let honest: [UInt8] = [0xE8, 0x03, 0, 0, 0] + [0x90, 0x90, 0x90] + [0xC3]

    /// Le même, mais la fonction écrase son adresse de retour avant de
    /// revenir. `call +0` tombe sur l'instruction suivante — c'est le corps de
    /// la fonction — qui écrit `0x1234` là où l'appel venait d'empiler, puis
    /// rend la main.
    static let dishonest: [UInt8] = [0xE8, 0, 0, 0, 0]
        + [0x48, 0xC7, 0x04, 0x24, 0x34, 0x12, 0x00, 0x00] + [0xC3]

    func testAnHonestReturnRaisesNothing() throws {
        var core = try Self.core(Self.honest)
        _ = try? core.run(budget: 5)
        XCTAssertTrue(core.brokenReturns.isEmpty)
        XCTAssertTrue(core.shadowStack.isEmpty, "l'appel a été dépilé")
    }

    /// **Le cas qu'on cherche.** La fonction change son adresse de retour ; le
    /// `ret` part ailleurs, et le témoin dit où l'appel avait promis d'aller.
    func testAReturnThatWasTamperedWithIsNamed() throws {
        var core = try Self.core(Self.dishonest)
        _ = try? core.run(budget: 3)
        XCTAssertEqual(core.brokenReturns.count, 1)
        let broken = try XCTUnwrap(core.brokenReturns.first)
        XCTAssertEqual(broken.taken, 0x1234, "où le ret est parti")
        XCTAssertEqual(broken.promised, Self.program &+ 5, "ce que le call avait promis")
        XCTAssertEqual(broken.calledAt, Self.program)
        XCTAssertEqual(broken.at, Self.program &+ 13, "l'adresse du ret lui-même")
        XCTAssertEqual(broken.stackAtCall, Self.stack &- 8)
        XCTAssertEqual(broken.stackAtReturn, Self.stack)
    }

    /// Un retour dont on n'a pas vu l'appel n'est pas un désaccord : la pile
    /// d'ombre commence vide au milieu d'un programme déjà lancé.
    func testAReturnWithoutItsCallIsNotAccused() throws {
        var core = try Self.core([0xC3])
        try core.memory?.write(Self.stack, 8, 0x4000)
        _ = try? core.run(budget: 1)
        XCTAssertTrue(core.brokenReturns.isEmpty)
    }

    /// Les trois formes d'appel sont reconnues, pas seulement la relative.
    func testTheThreeShapesOfCallAreAllRemembered() throws {
        // call *%rax, call *(%rax), call rel32
        for bytes in [[UInt8]([0xFF, 0xD0]), [0xFF, 0x10], [0xE8, 0, 0, 0, 0]] {
            var core = try Self.core(bytes)
            core.registers[0] = Self.program &+ 0x100
            try core.memory?.write(Self.program &+ 0x100, 8, Self.program &+ 0x200)
            _ = try? core.run(budget: 1)
            XCTAssertEqual(core.shadowStack.count, 1, "\(bytes)")
            XCTAssertEqual(core.shadowStack.first?.promised,
                           Self.program &+ UInt64(bytes.count))
        }
    }

    /// Un saut n'est pas un appel : `ff /4` saute, `ff /2` appelle, et le seul
    /// bit qui les sépare est dans le champ `reg` du ModRM.
    func testAnIndirectJumpIsNotACall() throws {
        var core = try Self.core([0xFF, 0xE0])  // jmp *%rax
        core.registers[0] = Self.program &+ 0x100
        _ = try? core.run(budget: 1)
        XCTAssertTrue(core.shadowStack.isEmpty)
    }

    func testTheKernelIsNotWatched() throws {
        var core = try Self.core(Self.dishonest, ring: 0)
        _ = try? core.run(budget: 4)
        XCTAssertTrue(core.brokenReturns.isEmpty)
        XCTAssertTrue(core.shadowStack.isEmpty)
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = try Self.core(Self.dishonest)
        core.canonicalWatchArmed = false
        _ = try? core.run(budget: 4)
        XCTAssertTrue(core.brokenReturns.isEmpty)
    }

    /// La pile d'ombre a un fond : un programme qui récurse profond n'est pas
    /// un défaut, et le témoin oublie le plus vieil appel plutôt que de
    /// grandir sans fin.
    func testTheShadowStackHasAFloor() throws {
        var core = try Self.core([0x90])
        for index in 0..<(X86Core.shadowStackDepth + 5) {
            core.rememberCall(promised: UInt64(index), at: UInt64(index))
        }
        XCTAssertEqual(core.shadowStack.count, X86Core.shadowStackDepth)
        XCTAssertEqual(core.shadowStack.first?.promised, 5,
                       "c'est le fond qui part, pas le sommet")
    }
}
