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

    /// **Le décalage entier dans la page gardée.** La seconde instruction
    /// vient de la page gardée, loin de son début : sa place est celle de la
    /// trame plus les douze bits bas de `rip`, tous — un masque trop court
    /// lirait ailleurs dans la page.
    func testTheKeptPageReadsAtTheWholeOffset() throws {
        var core = try Pages.core([0x90], subjectFlags: Self.open, ring: 0)
        try core.memory!.load([0x90] + Self.movFortyTwo, at: Pages.program + 0x900)
        core.rip = Pages.program + 0x900
        XCTAssertEqual(try core.run(budget: 2), 2)
        XCTAssertEqual(core.registers[0], 42, "lue à 0x901 dans la page, pas à 0x101")
    }

    /// **Une page qui ne tient pas entière dans la mémoire n'est pas gardée.**
    /// La page du `rip` garde sa place en mémoire et ajoute le décalage sans
    /// revérifier la borne : c'est sûr parce qu'elle n'est gardée que si la
    /// page entière y tient. Ici la mémoire s'arrête au milieu de la page du
    /// code : le `nop` de son dernier octet s'exécute, et l'instruction
    /// suivante, au-delà, doit fauter — pas être lue hors du tampon.
    func testAPageCutByTheEndOfMemoryIsNotKept() throws {
        let memory = X86Memory(size: 0x7800, base: 0)
        try memory.write(Pages.pml4, 8, Pages.pdpt | Self.open)
        try memory.write(Pages.pdpt, 8, Pages.directory | Self.open)
        try memory.write(Pages.directory, 8, Pages.table | Self.open)
        try memory.write(Pages.table &+ 7 * 8, 8, 0x7000 | Self.open)
        try memory.write(0x77FF, 1, 0x90)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x77FF, memory: memory)
        core.system.control[3] = Pages.pml4
        core.pagingActive = true
        core.segments[1] = 0x10
        XCTAssertEqual(try core.run(budget: 1), 1, "le dernier octet de la mémoire")
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            XCTAssertEqual(error as? X86Core.Fault, .outsideMemory(0x7800))
        }
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
