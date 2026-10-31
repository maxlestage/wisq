import XCTest
@testable import WisqVM

/// **Le signe d'un entier en mémoire**, pour l'arithmétique x87 de `DA`
/// (trente-deux bits) et `DE` (seize). L'oracle juge ces formes contre le vrai
/// processeur, mais sa fenêtre ne porte que des octets de 0x10 à 0x4F : tous
/// ses entiers sont positifs, et un `FIMUL` qui lirait l'entier sans signe y
/// passait. Voir `X86X87Dispatch.swift`.
final class X86X87IntegerOperandTests: XCTestCase {
    static let data: UInt64 = 0x2000

    /// `code` exécuté en entier, RSI sur un entier de `width` octets posé à
    /// `data`, et `top` seul sur la pile x87.
    static func run(_ code: [UInt8], integer: UInt64, width: Int, top: Double) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        try memory.write(data, width, integer)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[6] = data
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        core.push(X86Extended(top))
        while core.rip < 0x1000 &+ UInt64(code.count) {
            try core.execute(try X86Decoder.decode(memory.dump(core.rip, 15)))
        }
        return core
    }

    /// `fimull (%rsi)` et `fimuls (%rsi)` : trois fois moins deux.
    func testANegativeIntegerMultipliesAsNegative() throws {
        let wide = try Self.run([0xDA, 0x0E], integer: 0xFFFF_FFFE, width: 4, top: 3)
        XCTAssertEqual(wide.stack(0).asDouble, -6)
        let narrow = try Self.run([0xDE, 0x0E], integer: 0xFFFE, width: 2, top: 3)
        XCTAssertEqual(narrow.stack(0).asDouble, -6)
    }

    /// `ficoml (%rsi)` contre moins deux : plus grand, égal, plus petit,
    /// dans C0 et C3 — un entier lu sans signe ne serait jamais égal.
    func testAComparisonSeesTheSign() throws {
        let compare: [UInt8] = [0xDA, 0x16]
        let greater = try Self.run(compare, integer: 0xFFFF_FFFE, width: 4, top: 3)
        XCTAssertEqual(greater.x87Status & 0x4500, 0)
        let equal = try Self.run(compare, integer: 0xFFFF_FFFE, width: 4, top: -2)
        XCTAssertEqual(equal.x87Status & 0x4500, 0x4000)
        let less = try Self.run(compare, integer: 0xFFFF_FFFE, width: 4, top: -5)
        XCTAssertEqual(less.x87Status & 0x4500, 0x0100)
    }

    /// `ficompl (%rsi)` dépile après avoir comparé ; `ficoml` non.
    func testTheComparisonThatPopsPops() throws {
        let kept = try Self.run([0xDA, 0x16], integer: 2, width: 4, top: 2)
        let popped = try Self.run([0xDA, 0x1E], integer: 2, width: 4, top: 2)
        XCTAssertEqual(popped.x87TopIndex, (kept.x87TopIndex + 1) & 7)
        XCTAssertEqual(popped.x87Status & 0x4500, 0x4000, "égal, puis dépilé")
    }
}
