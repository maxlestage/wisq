import XCTest
@testable import WisqVM

/// **Les conversions entre MMX et flottants**, sur des valeurs que l'oracle
/// ne porte pas. Ses flottants sont minuscules (ils arrondissent à zéro de
/// toute façon) ou hors des entiers ; ses doubles en mémoire aussi. Ni la
/// troncature de `CVTTPS2PI` ni le second double de `CVTPD2PI` ne s'y
/// voyaient. Voir `X86Core.mmxConversion`.
final class X86MMXConversionTests: XCTestCase {
    static let data: UInt64 = 0x2000

    static func run(_ code: [UInt8], memory bytes: [UInt8] = [],
                    setup: (inout X86Core) -> Void = { _ in }) throws -> X86Core {
        let memory = X86Memory(size: 0x4000, base: 0)
        try memory.load(code, at: 0x1000)
        try memory.load(bytes, at: data)
        var registers = [UInt64](repeating: 0, count: 16)
        registers[6] = data
        var core = X86Core(registers: registers, rip: 0x1000, memory: memory)
        setup(&core)
        while core.rip < 0x1000 &+ UInt64(code.count) {
            try core.execute(try X86Decoder.decode(memory.dump(core.rip, 15)))
        }
        return core
    }

    static func pair(_ low: Int32, _ high: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: low)) | UInt64(UInt32(bitPattern: high)) << 32
    }

    /// **`CVTPS2PI` arrondit au plus proche, `CVTTPS2PI` tronque** : 1,5 et
    /// −2,7 rendent 2 et −3 d'un côté, 1 et −2 de l'autre.
    func testRoundingAndTruncation() throws {
        let floats = UInt64(Float(1.5).bitPattern) | UInt64(Float(-2.7).bitPattern) << 32
        let nearest = try Self.run([0x0F, 0x2D, 0xC1]) { $0.setVector(1, floats, 0) }
        XCTAssertEqual(nearest.mmx(0), Self.pair(2, -3))
        let truncated = try Self.run([0x0F, 0x2C, 0xC1]) { $0.setVector(1, floats, 0) }
        XCTAssertEqual(truncated.mmx(0), Self.pair(1, -2))
    }

    /// **`CVTPD2PI` lit seize octets** : deux doubles en mémoire, 3 et −7.
    func testTwoDoublesFromMemory() throws {
        let bytes = withUnsafeBytes(of: Double(3).bitPattern.littleEndian, Array.init)
            + withUnsafeBytes(of: Double(-7).bitPattern.littleEndian, Array.init)
        let core = try Self.run([0x66, 0x0F, 0x2D, 0x06], memory: bytes)  // cvtpd2pi (%rsi), %mm0
        XCTAssertEqual(core.mmx(0), Self.pair(3, -7))
    }

    /// Un flottant hors des entiers rend l'entier indéfini, et l'autre
    /// moitié sa valeur.
    func testAnOutOfRangeValueGivesTheIndefiniteInteger() throws {
        let floats = UInt64(Float(3e9).bitPattern) | UInt64(Float(-4).bitPattern) << 32
        let core = try Self.run([0x0F, 0x2D, 0xC1]) { $0.setVector(1, floats, 0) }
        XCTAssertEqual(core.mmx(0), Self.pair(Int32.min, -4))
    }
}
