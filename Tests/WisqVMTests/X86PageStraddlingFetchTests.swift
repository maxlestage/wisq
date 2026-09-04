import XCTest

@testable import WisqVM

/// Une instruction à cheval sur deux pages.
///
/// **Ce que la mesure a montré.** Les quatre morts de `mdev` sont des sauts
/// vers une page absente, et le témoin les fait toutes partir de la **même
/// place dans une page** : le déplacement `ffd`, trois octets avant la fin.
/// Un `jle rel32` en fait six. Il traverse.
///
/// Le cœur ne traduisait que le **premier octet** de l'instruction, puis
/// laissait le décodeur lire quatorze octets de plus, contigus en mémoire
/// **physique**. Or la page physiquement suivante n'est presque jamais la page
/// virtuellement suivante : l'instruction se décodait sur les octets d'ailleurs.
///
/// Ici les deux pages virtuelles sont mises exprès sur des trames **non
/// adjacentes**, et dans le désordre — c'est la seule disposition où le défaut
/// se voit, et c'est aussi la disposition ordinaire d'un vrai programme.
final class X86PageStraddlingFetchTests: XCTestCase {
    static let pml4: UInt64 = 0x1_0000
    static let pdpt: UInt64 = 0x1_1000
    static let directory: UInt64 = 0x1_2000
    static let table: UInt64 = 0x1_3000
    /// La page virtuelle où l'on exécute, et celle qui la suit.
    static let first: UInt64 = 0x20_0000
    static let second: UInt64 = 0x20_1000
    /// Leurs trames, **dans le désordre** : la seconde page virtuelle vit sur
    /// une trame physique *avant* la première.
    static let firstFrame: UInt64 = 0x5_0000
    static let secondFrame: UInt64 = 0x4_0000

    static func core() throws -> X86Core {
        let memory = X86Memory(size: 0x10_0000, base: 0)
        let open = X86Core.present | X86Core.writable | X86Core.userAccessible
        try memory.write(pml4, 8, pdpt | open)
        try memory.write(pdpt, 8, directory | open)
        // L'index du répertoire pour 0x200000 est **un**, pas zéro : deux
        // mégaoctets par entrée.
        try memory.write(directory &+ (first >> 21 & 0x1FF) * 8, 8, table | open)
        try memory.write(table &+ (first >> 12 & 0x1FF) * 8, 8, firstFrame | open)
        try memory.write(table &+ (second >> 12 & 0x1FF) * 8, 8, secondFrame | open)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16),
                           rip: first, memory: memory)
        core.system.control[3] = pml4
        core.pagingActive = true
        return core
    }

    /// Le cas nu : `jle rel32`, six octets, posés à trois octets de la fin.
    ///
    /// Sans la correction, le cœur lit `0f 8e` puis quatre octets pris dans la
    /// trame physiquement suivante — ici celle d'une *autre* page virtuelle —
    /// et saute n'importe où.
    func testAnInstructionThatStraddlesTwoPagesReadsTheSecondPage() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        // `0f 8e 20 00 00 00` : jle +0x20, à cheval — trois octets dans la
        // première page, trois dans la seconde.
        try memory.load([0x0F, 0x8E, 0x20], at: Self.firstFrame &+ 0xFFD)
        try memory.load([0x00, 0x00, 0x00], at: Self.secondFrame)
        // Et de quoi tromper : la trame *physiquement* suivante porte un
        // déplacement énorme. C'est elle que l'ancien chemin lisait.
        try memory.load([0xAA, 0x48, 0x89, 0x0C], at: Self.firstFrame &+ 0x1000)
        core.flags |= X86Core.Flag.zero  // ZF : la condition est vraie
        core.rip = Self.first &+ 0xFFD

        _ = try core.run(budget: 1)
        XCTAssertEqual(core.rip, Self.second &+ 0x23,
                       "le saut suit le déplacement de la seconde page,"
                       + " pas celui de la trame voisine")
    }

    /// Et le cas où la seconde page **manque** : le processeur prend une faute
    /// sur elle, il n'invente pas des octets. Sans ça, un programme dont la
    /// page suivante n'est pas encore là exécuterait n'importe quoi.
    func testAStraddlingInstructionFaultsOnTheSecondPageWhenItIsAbsent() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        try memory.write(Self.table &+ (Self.second >> 12 & 0x1FF) * 8, 8, 0)
        try memory.load([0x0F, 0x8E, 0x20], at: Self.firstFrame &+ 0xFFD)
        core.rip = Self.first &+ 0xFFD
        XCTAssertThrowsError(try core.run(budget: 1)) { error in
            guard case X86Core.Fault.pageFault(let address) = error else {
                return XCTFail("une faute de page, et pas \(error)")
            }
            XCTAssertEqual(address & ~UInt64(0xFFF), Self.second,
                           "et c'est la seconde page qui manque")
        }
    }

    /// Une instruction qui tient dans sa page n'est pas concernée : c'est le
    /// cas de toutes les autres, et le chemin rapide doit rester ce qu'il est.
    func testAnInstructionWithinOnePageIsUnaffected() throws {
        var core = try Self.core()
        let memory = try XCTUnwrap(core.memory)
        // `48 c7 c0 07 00 00 00` : mov $7,%rax, bien au milieu de la page.
        try memory.load([0x48, 0xC7, 0xC0, 0x07, 0x00, 0x00, 0x00],
                        at: Self.firstFrame &+ 0x100)
        core.rip = Self.first &+ 0x100
        _ = try core.run(budget: 1)
        XCTAssertEqual(core.registers[0], 7)
    }
}
