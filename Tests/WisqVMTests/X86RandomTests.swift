import Foundation
import XCTest
@testable import WisqVM

/// **`RDRAND` et `RDSEED`** : un nombre tiré de la source de la machine,
/// CF qui dit qu'il y en avait un, et deux machines reprises du même fichier
/// qui ne tirent pas la même chose. Voir `X86Entropy`.
final class X86RandomTests: XCTestCase {
    /// Un cœur qui tire dans une suite fixée, et des drapeaux tous posés :
    /// ce que l'instruction efface se voit.
    private func core(seed: UInt64 = 7) -> X86Core {
        var registers = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 { registers[index] = 0xAAAA_BBBB_CCCC_DDDD }
        var core = X86Core(registers: registers,
                           flags: X86Core.Flag.reserved | X86Core.Flag.arithmetic & ~X86Core.Flag.carry)
        core.entropy = .seeded(seed)
        return core
    }

    private func run(_ bytes: [UInt8], on core: inout X86Core) throws {
        try core.execute(try X86Decoder.decode(bytes))
    }

    /// Les trois largeurs, à la règle de `write` : soixante-quatre bits
    /// entiers, trente-deux qui effacent le haut, seize qui le gardent. CF
    /// posé, les cinq autres drapeaux arithmétiques effacés.
    func testRdrandFillsEachWidthAndSetsOnlyTheCarry() throws {
        var machine = core()
        let expected = X86Entropy.seeded(7)

        try run([0x48, 0x0F, 0xC7, 0xF0], on: &machine)  // rdrand %rax
        XCTAssertEqual(machine.registers[0], expected.next())
        XCTAssertEqual(machine.flags & X86Core.Flag.arithmetic, X86Core.Flag.carry,
                       "CF dit « il y en avait un » ; OF, SF, ZF, AF et PF sont effacés")

        machine.flags |= X86Core.Flag.arithmetic & ~X86Core.Flag.carry
        try run([0x0F, 0xC7, 0xF1], on: &machine)  // rdrand %ecx
        XCTAssertEqual(machine.registers[1], expected.next() & 0xFFFF_FFFF,
                       "trente-deux bits effacent le haut du registre")
        XCTAssertEqual(machine.flags & X86Core.Flag.arithmetic, X86Core.Flag.carry)

        try run([0x66, 0x0F, 0xC7, 0xF2], on: &machine)  // rdrand %dx
        XCTAssertEqual(machine.registers[2], 0xAAAA_BBBB_CCCC_0000 | (expected.next() & 0xFFFF),
                       "seize bits gardent le reste du registre")

        try run([0x49, 0x0F, 0xC7, 0xF3], on: &machine)  // rdrand %r11
        XCTAssertEqual(machine.registers[11], expected.next(), "REX.B choisit le registre")
    }

    /// `/7` tire dans la même source, et REX.R — qui n'a pas de sens dans
    /// un champ d'opcode — ne le change pas en autre chose.
    func testRdseedDrawsFromTheSameSource() throws {
        var machine = core(seed: 11)
        let expected = X86Entropy.seeded(11)
        try run([0x0F, 0xC7, 0xF8], on: &machine)  // rdseed %eax
        XCTAssertEqual(machine.registers[0], expected.next() & 0xFFFF_FFFF)
        XCTAssertEqual(machine.flags & X86Core.Flag.arithmetic, X86Core.Flag.carry)
        try run([0x4C, 0x0F, 0xC7, 0xF9], on: &machine)  // rdseed %rcx, REX.R posé
        XCTAssertEqual(machine.registers[1], expected.next())
    }

    /// Ce qui partage l'octet et n'est pas ici reste refusé : `RDPID`
    /// (`F3 0F C7 /7`) et les pointeurs de VMX (`/6` et `/7` en mémoire).
    func testRdpidAndTheMemoryFormsAreStillRefused() {
        for bytes: [UInt8] in [[0xF3, 0x0F, 0xC7, 0xF8], [0x0F, 0xC7, 0x30], [0x0F, 0xC7, 0x38]] {
            var machine = core()
            XCTAssertThrowsError(try run(bytes, on: &machine), "\(bytes)")
            XCTAssertEqual(machine.registers[0], 0xAAAA_BBBB_CCCC_DDDD, "rien n'est écrit")
        }
    }

    /// CPUID les annonce : RDRAND dans la feuille 1, RDSEED dans la 7. Sans
    /// ces bits, le noyau ne les exécute jamais.
    func testCPUIDAnnouncesBoth() {
        XCTAssertNotEqual(X86CPUID.answer(leaf: 1, subleaf: 0).2 & (1 << 30), 0, "RDRAND")
        XCTAssertNotEqual(X86CPUID.answer(leaf: 7, subleaf: 0).1 & (1 << 18), 0, "RDSEED")
    }

    /// La graine fixée rend la même suite, d'une source à l'autre — et deux
    /// graines voisines ne rendent pas des suites voisines.
    func testTheFixedSeedGivesTheSameSequence() {
        let one = X86Entropy.seeded(42), two = X86Entropy.seeded(42), other = X86Entropy.seeded(43)
        let first = (0..<8).map { _ in one.next() }
        XCTAssertEqual(first, (0..<8).map { _ in two.next() })
        XCTAssertEqual(Set(first).count, 8, "huit nombres différents")
        XCTAssertTrue(Set(first).isDisjoint(with: (0..<8).map { _ in other.next() }))
    }

    /// `rdrand %rax ; rdseed %rbx ; hlt`, interruptions coupées : la machine
    /// tire deux nombres et s'éteint.
    static let drawing: [UInt8] = [0x48, 0x0F, 0xC7, 0xF0, 0x48, 0x0F, 0xC7, 0xFB, 0xF4]

    /// Une machine prête à tirer, et l'instantané pris juste avant.
    private static func savedBeforeTheDraw() throws -> Data {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.load(kernelImage: X86LocalMachineTests.kernel(drawing))
        return machine.snapshot()
    }

    private static func draw(in machine: X86Machine, from saved: Data) throws -> [UInt64] {
        try machine.restore(saved)
        XCTAssertEqual(machine.run(instructionBudget: 1000), .powerOff)
        return [machine.core.registers[0], machine.core.registers[3]]
    }

    /// **Deux machines reprises du même instantané ne tirent pas le même
    /// nombre** — c'est tout l'objet : un bureau prêt est le même fichier sur
    /// tous les téléphones. Les machines de l'application reçoivent l'aléa du
    /// système (`GuestMachineFactory.make`).
    func testTwoMachinesResumedFromOneSnapshotDrawDifferentNumbers() throws {
        let saved = try Self.savedBeforeTheDraw()
        func applicationMachine() throws -> X86Machine {
            let made = GuestMachineFactory.make(for: .x86_64, ramSizeBytes: X86Machine.minimumRAMSize,
                                                onOutput: { _ in })
            return try XCTUnwrap(made as? X86Machine)
        }
        let first = try Self.draw(in: applicationMachine(), from: saved)
        let second = try Self.draw(in: applicationMachine(), from: saved)
        XCTAssertNotEqual(first, second, "deux téléphones, deux tirages")
        XCTAssertNotEqual(first[0], first[1], "RDRAND puis RDSEED : deux nombres")
    }

    /// **Et une machine construite sans rien dire tire la suite fixée** :
    /// deux reprises du même instantané y rendent les mêmes nombres, ceux de
    /// `X86Entropy.reproducibleSeed`. C'est ce qui garde les bancs et la
    /// fabrication d'un bureau reproductibles.
    func testAMachineGivenNothingIsReproducible() throws {
        let saved = try Self.savedBeforeTheDraw()
        let first = try Self.draw(in: X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in }),
                                  from: saved)
        let second = try Self.draw(in: X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in }),
                                   from: saved)
        XCTAssertEqual(first, second)
        let expected = X86Entropy.seeded(X86Entropy.reproducibleSeed)
        XCTAssertEqual(first, [expected.next(), expected.next()])
    }

    /// La source est celle de la machine, et elle survit à `load` comme à
    /// `restore`, qui construisent chacun un cœur neuf. Elle n'entre pas dans
    /// l'instantané : celui d'une machine reprise ailleurs est le même octet
    /// pour octet.
    func testTheSourceBelongsToTheMachineAndStaysOutOfTheSnapshot() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        let source = X86Entropy.seeded(99)
        machine.entropy = source
        try machine.load(kernelImage: X86LocalMachineTests.kernel(Self.drawing))
        XCTAssertTrue(machine.core.entropy === source, "après load")
        let saved = machine.snapshot()
        try machine.restore(saved)
        XCTAssertTrue(machine.core.entropy === source, "après restore")

        let elsewhere = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        elsewhere.entropy = .system()
        try elsewhere.restore(saved)
        XCTAssertEqual(elsewhere.snapshot(), saved, "la source n'est pas dans le fichier")
        XCTAssertEqual(elsewhere.core.entropy.kind, .system)
    }

    /// La fabrique de l'application donne l'aléa du système ; une machine
    /// construite à la main garde la suite fixée.
    func testTheApplicationFactoryGivesTheSystemSource() throws {
        let made = try XCTUnwrap(GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: X86Machine.minimumRAMSize, onOutput: { _ in }) as? X86Machine)
        XCTAssertEqual(made.entropy.kind, .system)
        XCTAssertEqual(made.core.entropy.kind, .system)
        let plain = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertEqual(plain.entropy.kind, .seeded(X86Entropy.reproducibleSeed))
    }
}
