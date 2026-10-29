import XCTest

@testable import WisqVM

/// **`REP MOVS` et `REP STOS` par pages entières** (`bulkString`) contre
/// l'élément un par un.
///
/// Le chemin par pages ne doit rien changer à ce que l'invité voit. Le témoin
/// d'adresse armé le coupe — il veut voir chaque accès —, ce qui donne
/// l'ancien chemin sur la même machine : chaque cas tourne deux fois, une fois
/// témoin armé loin de tout, une fois sans, et les deux doivent finir à
/// l'identique — registres, drapeaux, mémoire entière, faute et code d'erreur.
///
/// La mémoire est celle de `X86PagePermissionTests` : les pages jusqu'à
/// 0x7000 ouvertes, la page à l'essai en 0x8000, et rien au-delà — la page
/// 0x9000 faute.
final class X86BulkStringTests: XCTestCase {
    typealias Pages = X86PagePermissionTests
    static let open = Pages.present | Pages.writable | Pages.user

    struct Outcome: Equatable {
        var registers: X86Registers
        var rip: UInt64
        var flags: UInt64
        var memory: [UInt8]
        var fault: X86Core.Fault?
        var errorCode: UInt64
    }

    private func run(_ code: [UInt8], rax: UInt64 = 0, rcx: UInt64, rsi: UInt64 = 0,
                     rdi: UInt64, direction: Bool = false,
                     subjectFlags: UInt64 = open, ring: UInt16 = 0,
                     elementByElement: Bool) throws -> Outcome {
        var core = try Pages.core(code, subjectFlags: subjectFlags, ring: ring)
        // Une graine qui n'est pas des zéros, pour qu'une copie se voie.
        for page in stride(from: UInt64(0x6000), to: 0x9000, by: 0x1000) {
            try core.memory!.load((0..<0x1000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(page >> 12)) },
                                  at: page)
        }
        core.registers[0] = rax
        core.registers[1] = rcx
        core.registers[6] = rsi
        core.registers[7] = rdi
        if direction { core.flags |= X86Core.Flag.direction }
        if elementByElement {
            core.watchedAddress = 0x7FFF_0000
            core.watchedLength = 1
        }
        var fault: X86Core.Fault?
        do {
            _ = try core.run(budget: 1)
        } catch let error as X86Core.Fault {
            fault = error
        }
        return Outcome(registers: core.registers, rip: core.rip, flags: core.flags,
                       memory: core.memory!.dump(0, 0x10000), fault: fault,
                       errorCode: core.pageFaultErrorCode)
    }

    private func assertSame(_ code: [UInt8], rax: UInt64 = 0, rcx: UInt64, rsi: UInt64 = 0,
                            rdi: UInt64, direction: Bool = false,
                            subjectFlags: UInt64 = open, ring: UInt16 = 0,
                            _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let slow = try run(code, rax: rax, rcx: rcx, rsi: rsi, rdi: rdi, direction: direction,
                           subjectFlags: subjectFlags, ring: ring, elementByElement: true)
        let fast = try run(code, rax: rax, rcx: rcx, rsi: rsi, rdi: rdi, direction: direction,
                           subjectFlags: subjectFlags, ring: ring, elementByElement: false)
        XCTAssertEqual(fast.registers, slow.registers, "registres : \(message)", file: file, line: line)
        XCTAssertEqual(fast.rip, slow.rip, "rip : \(message)", file: file, line: line)
        XCTAssertEqual(fast.flags, slow.flags, "drapeaux : \(message)", file: file, line: line)
        XCTAssertEqual(fast.fault, slow.fault, "faute : \(message)", file: file, line: line)
        XCTAssertEqual(fast.errorCode, slow.errorCode, "code d'erreur : \(message)", file: file, line: line)
        XCTAssertTrue(fast.memory == slow.memory, "mémoire : \(message)", file: file, line: line)
    }

    static let repMovsb: [UInt8] = [0xF3, 0xA4]
    static let repMovsq: [UInt8] = [0xF3, 0x48, 0xA5]
    static let repStosb: [UInt8] = [0xF3, 0xAA]
    static let repStosw: [UInt8] = [0x66, 0xF3, 0xAB]
    static let repStosd: [UInt8] = [0xF3, 0xAB]
    static let repStosq: [UInt8] = [0xF3, 0x48, 0xAB]

    /// Une copie qui traverse deux frontières, source et destination
    /// décalées l'une de l'autre dans leur page.
    func testACopyAcrossPagesMatches() throws {
        try assertSame(Self.repMovsb, rcx: 0x1800, rsi: 0x6123, rdi: 0x7010, "rep movsb sur deux pages")
        try assertSame(Self.repMovsq, rcx: 0x300, rsi: 0x6008, rdi: 0x7100, "rep movsq sur deux pages")
    }

    /// **Un élément à cheval sur deux pages** : le morceau s'arrête avant, et
    /// l'élément qui traverse prend l'ancien chemin.
    func testAnElementStraddlingAPageMatches() throws {
        try assertSame(Self.repMovsq, rcx: 0x40, rsi: 0x6FFC, rdi: 0x7804, "source à cheval")
        try assertSame(Self.repStosq, rax: 0x1122_3344_5566_7788, rcx: 0x40, rdi: 0x7FFA, "destination à cheval")
    }

    /// **La faute au milieu** : RCX, RSI et RDI disent ce qui a été fait, et
    /// les octets d'avant la page manquante sont écrits.
    func testAFaultHalfwayLeavesTheSameState() throws {
        try assertSame(Self.repStosb, rax: 0xAB, rcx: 0x300, rdi: 0x8F00, "remplissage jusqu'à 0x9000")
        try assertSame(Self.repMovsb, rcx: 0x300, rsi: 0x8F00, rdi: 0x6000, "lecture jusqu'à 0x9000")
        try assertSame(Self.repMovsb, rcx: 0x300, rsi: 0x6000, rdi: 0x8F00, "écriture jusqu'à 0x9000")
    }

    /// Une page en lecture seule : l'écriture faute sur son premier élément,
    /// sans rien avoir touché.
    func testAReadOnlyDestinationMatches() throws {
        try assertSame(Self.repMovsb, rcx: 0x100, rsi: 0x6000, rdi: 0x8000,
                       subjectFlags: Pages.present | Pages.user, ring: 3, "destination en lecture seule")
    }

    /// **La destination qui commence dans la source, plus haut** : un par un,
    /// l'octet copié est relu à l'élément suivant et le motif se répète.
    /// Une copie d'un bloc ne le ferait pas — d'où l'ancien chemin.
    func testAnOverlapThatRepeatsAPatternMatches() throws {
        try assertSame(Self.repMovsb, rcx: 0x200, rsi: 0x6000, rdi: 0x6001, "décalage d'un octet")
        try assertSame(Self.repMovsq, rcx: 0x80, rsi: 0x6000, rdi: 0x6018, "décalage de trois mots")
    }

    /// La destination sous la source : la copie d'un bloc rend la même chose
    /// que l'élément un par un.
    func testAnOverlapBelowTheSourceMatches() throws {
        try assertSame(Self.repMovsb, rcx: 0x400, rsi: 0x6010, rdi: 0x6000, "destination plus bas")
        try assertSame(Self.repMovsq, rcx: 0x100, rsi: 0x6000, rdi: 0x6000, "même place")
    }

    /// Les quatre largeurs du remplissage.
    func testEveryFillWidthMatches() throws {
        let value: UInt64 = 0x0102_0304_0506_0708
        try assertSame(Self.repStosb, rax: value, rcx: 0x1234, rdi: 0x6010, "stosb")
        try assertSame(Self.repStosw, rax: value, rcx: 0x900, rdi: 0x6010, "stosw")
        try assertSame(Self.repStosd, rax: value, rcx: 0x480, rdi: 0x6010, "stosd")
        try assertSame(Self.repStosq, rax: value, rcx: 0x240, rdi: 0x6010, "stosq")
    }

    /// Le sens arrière, et un RCX nul : rien de neuf, mais les deux chemins
    /// doivent s'accorder aussi là.
    func testBackwardAndEmptyMatch() throws {
        try assertSame(Self.repMovsb, rcx: 0x300, rsi: 0x7200, rdi: 0x6400, direction: true, "en arrière")
        try assertSame(Self.repStosq, rax: 5, rcx: 0, rdi: 0x6000, "RCX nul")
    }
}
