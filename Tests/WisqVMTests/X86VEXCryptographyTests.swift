import XCTest

@testable import WisqVM

/// **Les formes VEX d'AES et de `PCLMULQDQ`, par leur chemin direct** (voir
/// `X86Core.vexCryptography`). Les valeurs sont tenues par le corpus VEX.128
/// (`x86-avx128-oracle.tsv`) ; ce qu'il ne voit pas, c'est le haut des
/// registres YMM, que toute forme VEX.128 remet à zéro.
final class X86VEXCryptographyTests: XCTestCase {
    static let a: (UInt64, UInt64) = (0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210)
    static let b: (UInt64, UInt64) = (0x0F1E_2D3C_4B5A_6978, 0x8796_A5B4_C3D2_E1F0)

    /// xmm1 = a, xmm2 = b, et le haut de ymm0 non nul.
    static func run(_ code: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x1000, memory: memory)
        core.setVector(1, a.0, a.1)
        core.setVector(2, b.0, b.1)
        core.setVector(0, 0x5555, 0x6666)
        core.upperVectors[0] = 0x7777
        core.upperVectors[1] = 0x8888
        try core.execute(try X86Decoder.decode(code))
        return core
    }

    /// `vaesenc %xmm2, %xmm1, %xmm0` (`C4 E2 71 DC C2`) : un tour sur xmm1,
    /// la clé dans xmm2, le résultat dans xmm0 et le haut de ymm0 à zéro.
    func testARoundUnderVEXClearsTheUpperHalf() throws {
        let core = try Self.run([0xC4, 0xE2, 0x71, 0xDC, 0xC2])
        let expected = X86Core.aesRound(0xDC, Self.a, Self.b)
        XCTAssertEqual(core.vector(0).low, expected.0)
        XCTAssertEqual(core.vector(0).high, expected.1)
        XCTAssertEqual(core.upperVectors[0], 0)
        XCTAssertEqual(core.upperVectors[1], 0)
        XCTAssertEqual(core.rip, 0x1005)
    }

    /// `vpclmulqdq $0x11, %xmm2, %xmm1, %xmm0` (`C4 E3 71 44 C2 11`) : les
    /// deux moitiés hautes, et le haut de ymm0 à zéro.
    func testTheCarrylessMultiplyUnderVEXClearsTheUpperHalf() throws {
        let core = try Self.run([0xC4, 0xE3, 0x71, 0x44, 0xC2, 0x11])
        let expected = X86Core.carrylessMultiply(Self.a.1, Self.b.1)
        XCTAssertEqual(core.vector(0).low, expected.0)
        XCTAssertEqual(core.vector(0).high, expected.1)
        XCTAssertEqual(core.upperVectors[0], 0)
        XCTAssertEqual(core.upperVectors[1], 0)
    }
}
