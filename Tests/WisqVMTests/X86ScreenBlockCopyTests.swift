import XCTest

@testable import WisqVM

/// **`REP MOVS` et `REP STOS` vers l'écran, d'un bloc** : voir la note de
/// `X86Core.bulkString`.
///
/// `simpledrm` pousse son image vers le cadre par `memcpy_toio`, un `rep movsl`
/// par ligne. Le cadre n'était pas de la RAM, et chaque pixel prenait le chemin
/// d'un élément à la fois. Comme pour `X86BulkStringTests`, chaque cas tourne
/// deux fois — témoin d'adresse armé loin de tout, ce qui coupe le chemin par
/// blocs, puis sans — et les deux doivent finir à l'identique : registres,
/// drapeaux, RAM, écran, faute.
///
/// Sans pagination : la RAM va de 0 à 0x40000, l'écran (64 × 32, deux pages
/// pile) commence à 0x100000, et rien entre les deux.
final class X86ScreenBlockCopyTests: XCTestCase {
    static let screenBase: UInt64 = 0x10_0000
    static let screenBytes = 64 * 32 * 4

    struct Outcome: Equatable {
        var registers: X86Registers
        var rip: UInt64
        var flags: UInt64
        var ram: [UInt8]
        var screen: [UInt8]
        var fault: X86Core.Fault?
    }

    /// `code` exécuté une fois, avec ses registres de chaîne. La RAM et
    /// l'écran portent une graine qui n'est pas des zéros, pour qu'une copie
    /// se voie. Rend aussi de combien la révision de l'écran a avancé.
    private func run(_ code: [UInt8], rax: UInt64 = 0, rcx: UInt64, rsi: UInt64 = 0, rdi: UInt64,
                     elementByElement: Bool) throws -> (Outcome, revisions: UInt64) {
        let memory = X86Memory(size: 0x4_0000, base: 0)
        let screen = X86Framebuffer(base: Self.screenBase, width: 64, height: 32)
        memory.screen = screen
        try memory.load(code, at: 0x1000)
        try memory.load((0..<0x8000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }, at: 0x8000)
        screen.replacePixels { pixels in
            for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: index &* 13 &+ 5) }
        }
        var registers = [UInt64](repeating: 0, count: 16)
        registers[0] = rax
        registers[1] = rcx
        registers[6] = rsi
        registers[7] = rdi
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        if elementByElement {
            core.watchedAddress = 0x7FFF_0000
            core.watchedLength = 1
        }
        let before = screen.revision
        var fault: X86Core.Fault?
        do {
            _ = try core.run(budget: 1)
        } catch let error as X86Core.Fault {
            fault = error
        }
        let outcome = Outcome(registers: core.registers, rip: core.rip, flags: core.flags,
                              ram: memory.dump(0, 0x4_0000), screen: screen.snapshot(), fault: fault)
        return (outcome, screen.revision &- before)
    }

    @discardableResult
    private func assertSame(_ code: [UInt8], rax: UInt64 = 0, rcx: UInt64, rsi: UInt64 = 0, rdi: UInt64,
                            _ message: String, file: StaticString = #filePath,
                            line: UInt = #line) throws -> (Outcome, revisions: UInt64) {
        let slow = try run(code, rax: rax, rcx: rcx, rsi: rsi, rdi: rdi, elementByElement: true).0
        let fast = try run(code, rax: rax, rcx: rcx, rsi: rsi, rdi: rdi, elementByElement: false)
        XCTAssertEqual(fast.0.registers, slow.registers, "registres : \(message)", file: file, line: line)
        XCTAssertEqual(fast.0.rip, slow.rip, "rip : \(message)", file: file, line: line)
        XCTAssertEqual(fast.0.flags, slow.flags, "drapeaux : \(message)", file: file, line: line)
        XCTAssertEqual(fast.0.fault, slow.fault, "faute : \(message)", file: file, line: line)
        XCTAssertTrue(fast.0.ram == slow.ram, "RAM : \(message)", file: file, line: line)
        XCTAssertTrue(fast.0.screen == slow.screen, "écran : \(message)", file: file, line: line)
        return fast
    }

    static let repMovsb: [UInt8] = [0xF3, 0xA4]
    static let repMovsd: [UInt8] = [0xF3, 0xA5]
    static let repStosq: [UInt8] = [0xF3, 0x48, 0xAB]

    /// **La ligne de `memcpy_toio`** : la RAM vers l'écran, deux pages en
    /// `rep movsl`. L'image est la source, et la révision n'avance qu'une fois
    /// par page — une copie d'un bloc, pas deux mille écritures.
    func testACopyFromRAMToTheScreen() throws {
        let fast = try assertSame(Self.repMovsd, rcx: 2048, rsi: 0x8000, rdi: Self.screenBase,
                                  "rep movsl de la RAM vers l'écran")
        let source = (0..<Self.screenBytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        XCTAssertTrue(fast.0.screen == source, "l'écran porte la source")
        XCTAssertGreaterThan(fast.revisions, 0, "la vue doit repeindre")
        XCTAssertLessThanOrEqual(fast.revisions, 2, "une copie d'un bloc par page, pas pixel par pixel")
    }

    /// `memset_io` : un remplissage de l'écran entier.
    func testAFillOfTheScreen() throws {
        let fast = try assertSame(Self.repStosq, rax: 0x00FF_00FF_0000_FF00, rcx: UInt64(Self.screenBytes / 8),
                                  rdi: Self.screenBase, "rep stosq sur l'écran")
        XCTAssertLessThanOrEqual(fast.revisions, 2)
    }

    /// `memcpy_fromio` : l'écran relu vers la RAM, d'une position qui n'est
    /// pas au début d'une page.
    func testACopyFromTheScreenToRAM() throws {
        try assertSame(Self.repMovsb, rcx: 0x1800, rsi: Self.screenBase + 0x123, rdi: 0x8010,
                       "rep movsb de l'écran vers la RAM")
    }

    /// **L'écran recopié sur lui-même**, comme un défilement. Vers le bas de
    /// la mémoire, la copie d'un bloc rend la même chose ; vers le haut, la
    /// destination commence dans la source et l'élément un par un répète un
    /// motif, que seul l'ancien chemin reproduit.
    func testTheScreenCopiedOntoItself() throws {
        try assertSame(Self.repMovsd, rcx: 512, rsi: Self.screenBase + 0x400, rdi: Self.screenBase,
                       "défilement vers le haut de l'image")
        try assertSame(Self.repMovsd, rcx: 512, rsi: Self.screenBase, rdi: Self.screenBase + 0x10,
                       "destination dans la source, plus haut")
    }

    /// **Au-delà de la fin du cadre**, l'élément qui sort faute « hors
    /// mémoire », au même endroit des deux côtés : les seize pixels d'avant
    /// sont écrits, RCX dit ce qui reste.
    func testACopyRunningPastTheEndFaultsAtTheSameElement() throws {
        let fast = try assertSame(Self.repMovsd, rcx: 64, rsi: 0x8000,
                                  rdi: Self.screenBase + UInt64(Self.screenBytes) - 64,
                                  "rep movsl qui sort du cadre")
        XCTAssertEqual(fast.0.registers[1], 48)
        guard case .outsideMemory? = fast.0.fault else {
            return XCTFail("la sortie du cadre doit fauter : \(String(describing: fast.0.fault))")
        }
    }

    /// Un cadre plus petit qu'une page ne fait pas tomber la copie : le
    /// morceau n'y tient pas, et l'élément un par un fait le reste.
    func testAFrameSmallerThanAPage() throws {
        let memory = X86Memory(size: 0x4_0000, base: 0)
        let screen = X86Framebuffer(base: Self.screenBase, width: 1, height: 1)
        memory.screen = screen
        XCTAssertNil(memory.block(Self.screenBase, 0x1000))
        XCTAssertNotNil(memory.block(Self.screenBase, 4))
        XCTAssertNil(memory.block(Self.screenBase + 1, 4))
    }
}
