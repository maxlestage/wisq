import XCTest
@testable import WisqVM

/// Ce que l'oracle du MMX ne voit pas : la pile x87 que les registres MMX
/// partagent, et les rangements en mémoire. Voir `X86MMX.swift`.
final class X86MMXStateTests: XCTestCase {
    static let data: UInt64 = 0x2000

    /// `code` exécuté en entier, RSI et RDI sur la fenêtre de données.
    static func run(_ code: [UInt8], setup: (inout X86Core) -> Void = { _ in }) throws -> (X86Core, X86Memory) {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        try memory.load([UInt8](repeating: 0xEE, count: 16), at: data)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[6] = data
        registers[7] = data
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        setup(&core)
        while core.rip < 0x1000 &+ UInt64(code.count) {
            try core.execute(try X86Decoder.decode(memory.dump(core.rip, 15)))
        }
        return (core, memory)
    }

    /// **Une instruction MMX remet le sommet à zéro et marque les huit
    /// étiquettes valides** ; écrire MM3 met la mantisse du registre physique
    /// 3 et son exposant à tout-un. EMMS rend la pile vide.
    func testMMXSharesTheX87Stack() throws {
        // movq %rax, %mm3
        var (core, _) = try Self.run([0x48, 0x0F, 0x6E, 0xD8]) {
            $0.registers[0] = 0x1122_3344_5566_7788
            $0.x87TopIndex = 5
        }
        XCTAssertEqual(core.x87TopIndex, 0)
        XCTAssertEqual(core.x87Tags, 0, "les huit étiquettes valides")
        XCTAssertEqual(core.x87[3], X86Extended(significand: 0x1122_3344_5566_7788, signExponent: 0xFFFF))
        // emms
        (core, _) = try Self.run([0x0F, 0x77])
        XCTAssertEqual(core.x87Tags, 0xFFFF, "EMMS rend la pile vide")
    }

    /// **Les formes SSSE3 sur MMX entrent dans le MMX comme les autres** :
    /// `pshufb %mm1, %mm0` et `palignr $4, %mm1, %mm0`, sommet à zéro et
    /// étiquettes valides. L'oracle ne voit pas la pile x87 ; ce test, si.
    func testSSSE3OnMMXSharesTheX87Stack() throws {
        for code: [UInt8] in [[0x0F, 0x38, 0x00, 0xC1], [0x0F, 0x3A, 0x0F, 0xC1, 0x04]] {
            let (core, _) = try Self.run(code) {
                $0.x87TopIndex = 5
                $0.x87Tags = 0xFFFF
            }
            XCTAssertEqual(core.x87TopIndex, 0, "\(code)")
            XCTAssertEqual(core.x87Tags, 0, "\(code)")
        }
    }

    /// **Les rangements** : `movq mm, m64`, `movntq`, `movd r/m32, mm` (les
    /// quatre octets bas seulement), et `maskmovq`, qui ne range que les octets
    /// dont le bit fort du masque est à un, à [RDI].
    func testStoresWriteWhatTheyShould() throws {
        let value: UInt64 = 0x0807_0605_0403_0201
        func loaded(_ core: inout X86Core) {
            core.setMMX(0, value)
            core.setMMX(1, 0x8000_0080_0000_8080)  // le masque : octets 0, 1, 4, 7
        }
        // movq %mm0, (%rsi)
        var (_, memory) = try Self.run([0x0F, 0x7F, 0x06], setup: loaded)
        XCTAssertEqual(memory.dump(Self.data, 9), [1, 2, 3, 4, 5, 6, 7, 8, 0xEE])
        // movntq %mm0, (%rsi)
        (_, memory) = try Self.run([0x0F, 0xE7, 0x06], setup: loaded)
        XCTAssertEqual(memory.dump(Self.data, 9), [1, 2, 3, 4, 5, 6, 7, 8, 0xEE])
        // movd %mm0, (%rsi)
        (_, memory) = try Self.run([0x0F, 0x7E, 0x06], setup: loaded)
        XCTAssertEqual(memory.dump(Self.data, 5), [1, 2, 3, 4, 0xEE])
        // maskmovq %mm1, %mm0
        (_, memory) = try Self.run([0x0F, 0xF7, 0xC1], setup: loaded)
        XCTAssertEqual(memory.dump(Self.data, 8), [1, 2, 0xEE, 0xEE, 5, 0xEE, 0xEE, 8])
    }

    /// MOVNTQ n'a pas de forme registre : refusée, pas inventée.
    func testMOVNTQBetweenRegistersIsRefused() {
        XCTAssertThrowsError(try Self.run([0x0F, 0xE7, 0xC1]))
    }
}
