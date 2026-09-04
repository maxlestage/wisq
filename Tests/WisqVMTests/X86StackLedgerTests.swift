import XCTest

@testable import WisqVM

/// Qui a bougé la pile, et de combien.
///
/// **Pourquoi ce témoin existe.** Le `ret` qui envoie `/init` dans des données
/// dépile un mot situé huit octets sous celui que l'appel avait posé. La
/// fonction est équilibrée, et le témoin d'anneau a mesuré 2 127 passages
/// achevés sans qu'aucun ne décale la pile : ce n'est donc ni le programme,
/// ni le noyau. Reste à regarder RSP changer, instruction par instruction, et
/// à montrer les derniers changements au moment où le retour tombe à côté.
final class X86StackLedgerTests: XCTestCase {
    static let program: UInt64 = 0x1000
    static let stack: UInt64 = 0x6000

    static func core(_ bytes: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x10000, base: 0)
        try memory.load(bytes, at: program)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: program, memory: memory)
        core.segments[1] = 0x33
        core.registers[4] = stack
        core.canonicalWatchArmed = true
        return core
    }

    /// Un registre neuf ne montre rien, et le dit en ne montrant rien plutôt
    /// qu'en montrant trente-deux cases vides.
    func testAFreshLedgerHasNothingToShow() throws {
        let core = try Self.core([0x90])
        XCTAssertTrue(core.stackMoves.isEmpty)
    }

    /// `push %rax` descend la pile de huit octets, et le registre le dit avec
    /// le sens : négatif veut dire « plus bas », donc empilé.
    func testAPushIsRecordedWithItsDirection() throws {
        var core = try Self.core([0x50, 0x90])   // push %rax ; nop
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.stackMoves.count, 1)
        let move = try XCTUnwrap(core.stackMoves.first)
        XCTAssertEqual(move.at, Self.program)
        XCTAssertEqual(move.opcode, 0x50)
        XCTAssertEqual(move.from, Self.stack)
        XCTAssertEqual(move.to, Self.stack &- 8)
        XCTAssertEqual(move.delta, -8)
    }

    /// Une instruction qui ne touche pas à la pile n'a rien à faire dans le
    /// registre : sinon il déborderait de `nop` et le mouvement qui compte
    /// serait déjà sorti quand on viendrait le lire.
    func testAnInstructionThatLeavesTheStackAloneIsNotRecorded() throws {
        var core = try Self.core([0x90, 0x90, 0x90])
        _ = try core.run(budget: 3)
        XCTAssertTrue(core.stackMoves.isEmpty)
    }

    /// Un couple équilibré laisse deux traces de sens opposé, dans l'ordre où
    /// elles ont eu lieu.
    func testTheLedgerKeepsTheOrderOfWhatHappened() throws {
        var core = try Self.core([0x50, 0x58, 0x90])  // push %rax ; pop %rax
        _ = try core.run(budget: 2)
        XCTAssertEqual(core.stackMoves.map { $0.delta }, [-8, 8])
        XCTAssertEqual(core.stackMoves.map { $0.opcode }, [0x50, 0x58])
    }

    /// Le registre est circulaire : passé sa profondeur, il garde les plus
    /// récents et oublie les plus anciens. C'est le bon sens de l'oubli — le
    /// mouvement qu'on cherche est celui d'avant le `ret`, pas celui du
    /// démarrage.
    func testThePastFallsOutOfTheLedgerBeforeThePresent() throws {
        let depth = X86Core.stackLedgerDepth
        var bytes = [UInt8]()
        for _ in 0..<(depth + 4) { bytes += [0x50, 0x58] }   // push ; pop
        var core = try Self.core(bytes + [0x90])
        _ = try core.run(budget: UInt64(2 * (depth + 4)))
        XCTAssertEqual(core.stackMoves.count, depth)
        // Le plus récent est le dernier `pop`, et le plus ancien n'est plus le
        // premier `push`.
        XCTAssertEqual(core.stackMoves.last?.delta, 8)
        XCTAssertGreaterThan(try XCTUnwrap(core.stackMoves.first).at, Self.program)
    }

    /// Le registre ne tourne que sous le témoin. Éteint, le chemin chaud reste
    /// ce qu'il était et rien n'est noté.
    func testTheLedgerIsOffUnlessTheWatchIsArmed() throws {
        var core = try Self.core([0x50, 0x90])
        core.canonicalWatchArmed = false
        _ = try core.run(budget: 1)
        XCTAssertTrue(core.stackMoves.isEmpty)
    }

    /// Et c'est là que ça sert : un retour sans promesse emporte avec lui la
    /// trace de ce qui a bougé la pile juste avant.
    func testAnUnmatchedReturnCarriesWhatMovedTheStack() throws {
        // push %rax ; ret — le `ret` dépile ce que le `push` a posé, et aucun
        // `call` ne l'avait promis.
        var core = try Self.core([0x50, 0xC3])
        _ = try core.run(budget: 2)
        let unmatched = try XCTUnwrap(core.unmatchedReturns.first)
        XCTAssertFalse(unmatched.moves.isEmpty, "le registre doit suivre le retour")
        XCTAssertEqual(unmatched.moves.map { $0.opcode }, [0x50, 0xC3])
        XCTAssertEqual(unmatched.moves.last?.delta, 8, "un ret dépile huit octets")
    }
}
