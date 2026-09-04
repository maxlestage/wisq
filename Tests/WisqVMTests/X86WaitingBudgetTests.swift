import XCTest

@testable import WisqVM

/// Travailler et attendre ne se paient pas dans la même monnaie.
///
/// **Ce que la mesure a montré.** Le démarrage du vrai noyau consommait
/// **deux milliards et demi** de ses six milliards d'instructions à
/// patienter devant un média de démarrage absent — un tour d'attente coûtait
/// autant qu'une instruction. Les temporisations de l'invité ne pouvaient donc
/// pas expirer : on lui coupait le courant pendant qu'il attendait, et le
/// rapport lisait ça comme un arrêt.
///
/// `waiting` donne à l'attente son allocation à part. Sans lui, rien ne
/// change — et c'est exigé ici, parce que cent quarante-six appels
/// s'appuient sur l'ancien comportement.
final class X86WaitingBudgetTests: XCTestCase {
    /// Un cœur qui s'endort tout de suite, avec une horloge armée et les
    /// interruptions permises : les deux conditions sans lesquelles `HLT` est
    /// un arrêt et non une attente.
    static func sleeping() throws -> X86Core {
        let memory = X86Memory(size: 0x1000, base: 0)
        try memory.load([0xF4], at: 0)  // hlt
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: 0, memory: memory)
        core.flags |= X86Core.Flag.interrupt
        // Une valeur de rechargement non nulle est ce qui arme l'horloge.
        core.devices.reload = 0xFFFF
        return core
    }

    /// **Sans allocation d'attente, un tour d'attente coûte une instruction.**
    /// C'est le comportement d'avant, et cent quarante-six appels en dépendent.
    func testWithoutAnAllowanceWaitingSpendsTheInstructionBudget() throws {
        var core = try Self.sleeping()
        _ = try core.run(budget: 1000)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.idled, 999, "le `hlt` lui-même prend le premier tour")
        XCTAssertFalse(core.outOfPatience, "ce n'est pas l'attente qui a manqué")
    }

    /// **Avec une allocation, l'attente ne puise plus dans le budget.** C'est
    /// ce qui permet à une temporisation d'expirer au lieu d'être coupée.
    func testAnAllowanceKeepsWaitingOutOfTheInstructionBudget() throws {
        var core = try Self.sleeping()
        _ = try core.run(budget: 1000, waiting: 50)
        XCTAssertTrue(core.outOfPatience, "c'est la patience qui s'est épuisée")
        XCTAssertEqual(core.idled, 50)
    }

    /// **Les deux comptes ne se mélangent pas.** La machine travaille, puis
    /// s'endort : les instructions vont au budget, les tours d'attente à
    /// l'allocation, et c'est celle-ci qui finit par arrêter la course.
    func testWorkAndWaitingAreCountedSeparately() throws {
        let memory = X86Memory(size: 0x1000, base: 0)
        // Trois `nop`, puis `hlt`.
        try memory.load([0x90, 0x90, 0x90, 0xF4], at: 0)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: 0, memory: memory)
        core.flags |= X86Core.Flag.interrupt
        core.devices.reload = 0xFFFF

        let done = try core.run(budget: 1_000_000, waiting: 20)
        XCTAssertTrue(core.outOfPatience, "c'est l'attente qui s'est épuisée")
        XCTAssertEqual(core.idled, 20, "et elle seule a compté les tours")
        XCTAssertEqual(done, 4, "trois nop et le hlt : le budget n'a pas payé l'attente")
    }

    /// Une machine qui ne peut **pas** être réveillée s'arrête tout de suite,
    /// allocation ou pas : sans horloge, l'attente serait éternelle.
    func testAMachineThatCannotBeWokenStopsAtOnce() throws {
        var core = try Self.sleeping()
        core.devices.reload = 0
        _ = try core.run(budget: 1_000_000, waiting: 1_000_000)
        XCTAssertTrue(core.halted)
        XCTAssertEqual(core.idled, 0, "elle n'a pas attendu : elle s'est arrêtée")
        XCTAssertFalse(core.outOfPatience)
    }
}
