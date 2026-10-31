import XCTest

@testable import WisqVM

/// **`vmovss` et `vmovsd` entre registres, forme « rangement »** (`0F 11`) :
/// voir `X86Core.scalarMoveBetweenRegisters`. Les octets sont ceux que la
/// session Xfce de Void se voyait refuser, et ceux qu'assemble `gcc` ; les
/// résultats attendus sont ceux relevés sur le processeur.
final class X86VEXScalarMoveTests: XCTestCase {
    static let a: (UInt64, UInt64) = (0x1111_1111_1111_1111, 0x2222_2222_2222_2222)
    static let b: (UInt64, UInt64) = (0x3333_3333_3333_3333, 0x4444_4444_4444_4444)
    static let c: (UInt64, UInt64) = (0x5555_5555_5555_5555, 0x6666_6666_6666_6666)

    /// xmm11 = a, xmm12 = b, xmm2 = c, et le haut de ymm2 non nul.
    static func run(_ code: [UInt8]) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x1000, memory: memory)
        core.setVector(11, a.0, a.1)
        core.setVector(12, b.0, b.1)
        core.setVector(2, c.0, c.1)
        core.upperVectors[4] = 0x7777
        core.upperVectors[5] = 0x8888
        try core.execute(try X86Decoder.decode(code))
        return core
    }

    /// `C5 23 11 DA`, refusé à Void : xmm2 ← bas de xmm11, haut de xmm11.
    func testTheFormVoidAskedFor() throws {
        let core = try Self.run([0xC5, 0x23, 0x11, 0xDA])
        XCTAssertEqual(core.vector(2).low, Self.a.0)
        XCTAssertEqual(core.vector(2).high, Self.a.1)
    }

    /// `vmovsd %xmm12, %xmm11, %xmm2` (`C5 23 11 E2`) : le bas vient de
    /// `reg` (xmm12), le haut de `vvvv` (xmm11), et le haut de ymm2 tombe à
    /// zéro. Relevé sur le processeur : 3333…, 2222….
    func testTheLowHalfComesFromRegAndTheRestFromVvvv() throws {
        let core = try Self.run([0xC5, 0x23, 0x11, 0xE2])
        XCTAssertEqual(core.vector(2).low, Self.b.0)
        XCTAssertEqual(core.vector(2).high, Self.a.1)
        XCTAssertEqual(core.upperVectors[4], 0)
        XCTAssertEqual(core.upperVectors[5], 0)
    }

    /// `vmovss %xmm12, %xmm11, %xmm2` (`C5 22 11 E2`) : quatre octets
    /// seulement viennent de `reg`.
    func testTheSingleFormMovesFourBytes() throws {
        let core = try Self.run([0xC5, 0x22, 0x11, 0xE2])
        XCTAssertEqual(core.vector(2).low, 0x1111_1111_3333_3333)
        XCTAssertEqual(core.vector(2).high, Self.a.1)
    }
}
