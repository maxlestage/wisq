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

    /// **Une machine endormie doit pouvoir être réveillée.** C'est le défaut
    /// que l'allocation d'attente a failli introduire, et que les trois tests
    /// précédents ne voyaient pas : ils comptaient les tours sans jamais
    /// vérifier que l'horloge servait encore à quelque chose.
    ///
    /// Le service du matériel est cadencé sur les instructions **exécutées**.
    /// Une machine au repos n'en exécute aucune, donc ce compteur se fige — et
    /// s'il ne tombait pas juste au moment de l'endormissement, plus rien ne
    /// regardait l'horloge. Elle avançait, personne ne la lisait.
    ///
    /// Un `nop` avant le `hlt` suffit à le montrer : il décale le compteur
    /// d'un cran, et ça change tout.
    func testASleepingMachineIsStillWoken() throws {
        let memory = X86Memory(size: 0x1000, base: 0)
        try memory.load([0x90, 0xF4], at: 0)  // nop, puis hlt
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: 0, memory: memory)
        core.flags |= X86Core.Flag.interrupt
        core.devices.reload = 4  // une horloge qui bat vite
        _ = try core.run(budget: 1000, waiting: 500)
        XCTAssertGreaterThan(core.devices.raised, 0,
                             "l'horloge a battu, et quelqu'un l'a lue")
    }

    /// **Chaque course a sa propre patience.** Le drapeau était posé une fois
    /// pour toutes : une machine qu'on relance après lui avoir donné de quoi
    /// travailler — une frappe au clavier, par exemple — rendait encore
    /// « attente épuisée » alors qu'elle venait de travailler tout son budget.
    /// Sans ça, on ne peut pas tenir une conversation avec l'invité : le
    /// premier silence rend tous les suivants illisibles.
    func testEachRunReportsItsOwnPatience() throws {
        var core = try Self.sleeping()
        _ = try core.run(budget: 1_000_000, waiting: 10)
        XCTAssertTrue(core.outOfPatience)

        // De quoi travailler : la machine se réveille et consomme son budget.
        core.halted = false
        try core.memory?.load([0x90, 0xEB, 0xFD], at: 0)  // nop ; jmp -3
        core.rip = 0
        _ = try core.run(budget: 100, waiting: 10)
        XCTAssertFalse(core.outOfPatience, "cette course-ci n'a pas attendu")
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

    /// **Sauter l'attente rend la même machine que la compter.** Une boucle
    /// `sti ; hlt`, et un gestionnaire qui compte ses réveils, acquitte le
    /// 8259 et revient : la même course, pas à pas puis par sauts, en mode
    /// périodique puis en coup unique, avec et sans allocation d'attente.
    /// Instructions retirées, tours d'attente, réveils, leurs heures et RIP doivent être
    /// les mêmes au tour près — sans quoi un instantané ou une mesure ne
    /// rejouerait plus la même chose.
    func testSkippingTheWaitGivesTheSameMachineAsCountingIt() throws {
        func machine(skipping: Bool, oneShot: Bool) throws -> X86Core {
            let ram = X86Memory(size: 1 << 20, base: 0)
            try ram.load([0xFB, 0xF4, 0xEB, 0xFC], at: 0x100)  // sti ; hlt ; jmp .-4
            // rdtsc ; add %rax,%rdi ; inc %rbx ; mov $0x20,%al ; out %al,$0x20 ; iretq
            // La somme des heures de réveil, dans RDI : un réveil d'un tour
            // en retard s'y voit, même quand la fin de course est la même.
            try ram.load([0x0F, 0x31, 0x48, 0x01, 0xC7, 0x48, 0xFF, 0xC3, 0xB0, 0x20, 0xE6, 0x20, 0x48, 0xCF],
                         at: 0x8000)
            let low = UInt64(0x8000) | (UInt64(0x10) << 16) | (UInt64(0x8E) << 40)
            try ram.write(0x9000 &+ 0x30 * 16, 8, low)
            try ram.write(0x9000 &+ 0x30 * 16 &+ 8, 8, 0)
            var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
            core.descriptorBases[1] = 0x9000
            core.descriptorLimits[1] = 0xFFF
            core.registers[4] = 0x7000
            core.devices.primary.mask = 0xFE
            core.devices.primary.vectorBase = 0x30
            core.devices.reload = oneShot ? 700 : 1193
            core.devices.oneShot = oneShot
            core.skipsIdleTime = skipping
            return core
        }
        for oneShot in [false, true] {
            for waiting in [nil, 75_000 * X86LegacyDevices.instructionsPerTick] as [UInt64?] {
                var counted = try machine(skipping: false, oneShot: oneShot)
                var skipped = try machine(skipping: true, oneShot: oneShot)
                // Cinquante mille battements : une quarantaine de réveils en
                // mode périodique, une dizaine en coup unique.
                let budget = 50_000 * X86LegacyDevices.instructionsPerTick
                let a = try counted.run(budget: budget, waiting: waiting)
                let b = try skipped.run(budget: budget, waiting: waiting)
                let label = "coup unique : \(oneShot), attente : \(String(describing: waiting))"
                XCTAssertGreaterThan(counted.registers[3], 4, "la machine s'est réveillée : \(label)")
                XCTAssertEqual(a, b, label)
                XCTAssertEqual(counted.registers[3], skipped.registers[3], "réveils, \(label)")
                XCTAssertEqual(counted.registers[7], skipped.registers[7], "heures de réveil, \(label)")
                XCTAssertEqual(counted.retired, skipped.retired, label)
                XCTAssertEqual(counted.idled, skipped.idled, label)
                XCTAssertEqual(counted.rip, skipped.rip, label)
                XCTAssertEqual(counted.devices.raised, skipped.devices.raised, label)
                XCTAssertEqual(counted.outOfPatience, skipped.outOfPatience, label)
            }
        }
    }
}
