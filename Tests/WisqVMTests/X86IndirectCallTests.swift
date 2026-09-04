import XCTest

@testable import WisqVM

/// Ce que le programme trouve dans sa table des globales.
///
/// **Ce qu'il a fallu écarter avant.** Cinq corpus matériels ont épuisé le jeu
/// d'instructions ; le vecteur auxiliaire que le noyau pose est juste ; et la
/// pile d'ombre a montré que sur six milliards d'instructions, **aucun `ret`
/// ne trahit son `call`**.
///
/// Reste ce que la pile d'ombre ne peut pas voir : **où le `call` allait**. Un
/// appel qui passe par la table des globales lit son adresse en mémoire. Si
/// cette case porte la mauvaise fonction, l'appel y va, en revient proprement,
/// et rend à l'appelant une valeur du mauvais genre — la pile est intacte du
/// début à la fin, et le programme meurt quand même. C'est exactement ce qu'on
/// observe : `/init` reçoit un nombre là où son code attend une adresse.
final class X86IndirectCallTests: XCTestCase {
    static let pml4: UInt64 = 0x2000
    static let pdpt: UInt64 = 0x3000
    static let program: UInt64 = 0x1000
    static let slot: UInt64 = 0x5000
    static let target: UInt64 = 0x6000

    static func core(_ bytes: [UInt8], ring: UInt16 = 3) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        try memory.write(slot, 8, target)
        try memory.load([0xC3], at: target)  // ret
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, X86Core.present | X86Core.hugePage | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        core.segments[1] = ring == 3 ? 0x33 : 0x10
        core.canonicalWatchArmed = true
        core.registers[4] = 0x9000
        core.registers[0] = slot
        return core
    }

    /// `call *(%rax)` — la forme qu'a tout appel passant par une table.
    static let indirectCall: [UInt8] = [0xFF, 0x10]
    /// `jmp *(%rax)` — la forme qu'a un tremplin de liaison.
    static let indirectJump: [UInt8] = [0xFF, 0x20]

    func testAnIndirectCallSaysWhichSlotAndWhichTarget() throws {
        var core = try Self.core(Self.indirectCall)
        _ = try? core.run(budget: 1)
        XCTAssertEqual(core.indirectCalls.count, 1)
        let seen = try XCTUnwrap(core.indirectCalls.first)
        XCTAssertEqual(seen.at, Self.program)
        XCTAssertEqual(seen.slot, Self.slot, "la case lue")
        XCTAssertEqual(seen.target, Self.target, "ce qu'on y a trouvé")
        XCTAssertFalse(seen.jumped)
    }

    /// **Le tremplin compte autant.** Une liaison dynamique passe par un
    /// `jmp *m`, pas par un `call` : c'est lui qui va chercher l'adresse dans
    /// la table, et l'ignorer laisserait le chemin le plus fréquent hors de vue.
    func testATrampolineJumpIsRememberedToo() throws {
        var core = try Self.core(Self.indirectJump)
        _ = try? core.run(budget: 1)
        let seen = try XCTUnwrap(core.indirectCalls.first)
        XCTAssertEqual(seen.slot, Self.slot)
        XCTAssertEqual(seen.target, Self.target)
        XCTAssertTrue(seen.jumped)
    }

    /// Une forme de registre ne lit rien en mémoire : elle n'apprend rien sur
    /// une table, et l'inscrire ferait du bruit.
    func testTheRegisterFormsAreNotAboutATable() throws {
        for bytes in [[UInt8]([0xFF, 0xD0]), [0xFF, 0xE0]] {  // call *%rax, jmp *%rax
            var core = try Self.core(bytes)
            core.registers[0] = Self.target
            _ = try? core.run(budget: 1)
            XCTAssertTrue(core.indirectCalls.isEmpty, "\(bytes)")
        }
    }

    /// `ff /6` empile, il n'appelle ni ne saute — et c'est le même octet
    /// d'opcode. Seul le champ `reg` du ModRM les sépare.
    func testThePushFormOfTheSameOpcodeIsNotACall() throws {
        var core = try Self.core([0xFF, 0x30])  // push (%rax)
        _ = try? core.run(budget: 1)
        XCTAssertTrue(core.indirectCalls.isEmpty)
    }

    /// Le même couple deux fois ne compte qu'une : ce qui apprend quelque
    /// chose, c'est la liste des cibles distinctes, pas leur nombre.
    func testTheSameCallTwiceIsListedOnce() throws {
        // jmp *(%rax) qui revient sur lui-même : la cible est un jmp vers le
        // départ, donc on repasse par la même case.
        var core = try Self.core(Self.indirectJump)
        try core.memory?.load([0xE9, 0xFB, 0xEF, 0xFF, 0xFF], at: Self.target)
        _ = try? core.run(budget: 6)
        XCTAssertEqual(core.indirectCalls.count, 1)
    }

    func testTheKernelIsNotWatched() throws {
        var core = try Self.core(Self.indirectCall, ring: 0)
        _ = try? core.run(budget: 1)
        XCTAssertTrue(core.indirectCalls.isEmpty)
    }

    func testTheWatchIsOffUnlessItIsArmed() throws {
        var core = try Self.core(Self.indirectCall)
        core.canonicalWatchArmed = false
        _ = try? core.run(budget: 1)
        XCTAssertTrue(core.indirectCalls.isEmpty)
    }

    func testTheListStopsAtItsLimit() throws {
        var core = try Self.core(Self.indirectCall)
        for index in 0...(X86Core.indirectCallLimit + 3) {
            core.rip = UInt64(index)
            core.rememberIndirectCall(at: UInt64(index), slot: 0, jumped: false)
        }
        XCTAssertEqual(core.indirectCalls.count, X86Core.indirectCallLimit)
    }
}
