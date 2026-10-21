import XCTest

@testable import WisqVM

/// **La page du dernier `rip`**, que `run` garde traduite (`fetchTag`) : elle
/// ne doit jamais rendre une trame que le cache de traductions ne rendrait
/// plus. Trois façons de la rendre fausse, chacune essayée ici : le cache
/// vidé, une traduction remplacée dans le même emplacement, l'anneau changé.
final class X86FetchPageTests: XCTestCase {
    typealias Pages = X86PagePermissionTests
    static let open = Pages.present | Pages.writable | Pages.user
    /// La trame où l'on déplace la page du code.
    static let moved: UInt64 = 0x6000
    /// `mov $42, %eax`, ce que la trame déplacée exécute à la place d'un `nop`.
    static let movFortyTwo: [UInt8] = [0xB8, 0x2A, 0x00, 0x00, 0x00]

    /// Le code en 0x1000 (lu par la première instruction), et la trame
    /// déplacée qui porte `mov $42` au même décalage que l'instruction
    /// suivante.
    private func core(_ first: [UInt8], ring: UInt16 = 0) throws -> X86Core {
        var core = try Pages.core(first + [0x90], subjectFlags: Self.open, ring: ring)
        try core.memory!.load(Self.movFortyTwo, at: Self.moved + UInt64(first.count))
        return core
    }

    private func remapCode(_ core: inout X86Core) throws {
        try core.memory!.write(Pages.table &+ (Pages.program >> 12) * 8, 8, Self.moved | Self.open)
    }

    /// **CR3 réécrit** : le cache est vidé, la page du `rip` avec lui, et
    /// l'instruction suivante vient de la nouvelle trame.
    func testAFlushForgetsTheInstructionPage() throws {
        var core = try core([0x90])
        XCTAssertEqual(try core.run(budget: 1), 1)
        try remapCode(&core)
        core.writeControlRegister(3, Pages.pml4)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.registers[0], 42, "lue dans la trame déplacée")
    }

    /// **Une traduction remplacée dans le même emplacement.** La donnée lue en
    /// 0x401000 tombe dans l'emplacement de la page du code (0x401 et 0x1, à
    /// 1024 emplacements) et l'en chasse. Le cache de traductions refait
    /// alors le parcours, et voit la page du code déplacée — la page du `rip`
    /// doit faire comme lui, et pas garder l'ancienne trame.
    func testATranslationTakingTheSlotForgetsTheInstructionPage() throws {
        // `mov (%rsi), %rax`, avec RSI dans une grande page de 2 Mio en
        // 0x400000, qui recouvre la mémoire depuis zéro.
        var core = try core(Pages.read)
        try core.memory!.write(Pages.directory &+ 2 * 8, 8, 0 | Self.open | 0x80)
        core.registers[6] = 0x40_1000
        XCTAssertEqual(try core.run(budget: 1), 1, "la lecture passe par la grande page")
        try remapCode(&core)
        XCTAssertEqual(try core.run(budget: 1), 1)
        XCTAssertEqual(core.registers[0], 42, "le parcours refait voit la trame déplacée")
    }

    /// **L'anneau fait partie de la clé.** Une page de code fermée aux
    /// programmes, lue depuis le noyau, puis exécutée depuis l'anneau trois :
    /// c'est la lecture de l'instruction qui doit fauter, pas l'opérande
    /// d'après.
    func testDroppingToRingThreeChecksTheInstructionPageAgain() throws {
        // Un `nop` d'abord : une lecture de donnée remplirait le cache de
        // traductions, ce qui effacerait déjà la page du `rip` — le test ne
        // jugerait plus l'anneau.
        var core = try Pages.core([0x90] + Pages.read, subjectFlags: Self.open,
                                  tableFlags: Pages.present | Pages.writable, ring: 0)
        XCTAssertEqual(try core.run(budget: 1), 1, "le noyau lit son code")
        core.segments[1] = 0x33
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .pageFault(Pages.program + 1))
        }
        XCTAssertEqual(core.pageFaultErrorCode,
                       Pages.presentBit | Pages.userBit | Pages.fetchBit,
                       "une lecture d'instruction, depuis un programme")
    }
}
