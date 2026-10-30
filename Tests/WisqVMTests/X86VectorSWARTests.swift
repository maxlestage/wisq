import XCTest
@testable import WisqVM

/// Les formes sans tableau de `PCMPEQB`, `PMOVMSKB`, `PSRLDQ` et `PSLLDQ`,
/// contre l'écriture octet par octet qu'elles remplacent, sur des valeurs
/// tirées et sur les bords. Le processeur lui-même les tient aussi, par
/// l'oracle SIMD.
final class X86VectorSWARTests: XCTestCase {
    static func bytes(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    static func samples() -> [UInt64] {
        var generator = SystemRandomNumberGenerator()
        var values: [UInt64] = [0, .max, 0x8080_8080_8080_8080, 0x7F7F_7F7F_7F7F_7F7F, 0x0100_FF80_7F01_00FF,
                                0x8000_0000_0000_0001]
        for _ in 0..<2000 { values.append(generator.next()) }
        return values
    }

    func testEqualBytesIsByteForByteEquality() {
        let values = Self.samples()
        for (index, left) in values.enumerated() {
            // Des paires qui partagent des octets, sinon presque aucun ne serait égal.
            let other = values[(index * 7 + 3) % values.count]
            let right = (left & 0x00FF_00FF_F0F0_FF00) | (other & ~0x00FF_00FF_F0F0_FF00)
            let expected = zip(Self.bytes(left), Self.bytes(right)).enumerated().reduce(UInt64(0)) {
                $0 | ($1.element.0 == $1.element.1 ? UInt64(0xFF) << (8 * UInt64($1.offset)) : 0)
            }
            XCTAssertEqual(X86Core.equalBytes(left, right), expected, "\(String(left, radix: 16)) \(String(right, radix: 16))")
        }
        XCTAssertEqual(X86Core.equalBytes(0, 0), .max)
        XCTAssertEqual(X86Core.equalBytes(0x80, 0), 0xFFFF_FFFF_FFFF_FF00, "le bit haut seul fait la différence")
        XCTAssertEqual(X86Core.equalBytes(0x01_00, 0x00_00), 0xFFFF_FFFF_FFFF_00FF, "pas de retenue d'un octet à l'autre")
    }

    func testSignBitsTakesTheHighBitOfEachByteInOrder() {
        for value in Self.samples() {
            let expected = Self.bytes(value).enumerated().reduce(UInt64(0)) {
                $0 | UInt64($1.element >> 7) << UInt64($1.offset)
            }
            XCTAssertEqual(X86Core.signBits(value), expected, String(value, radix: 16))
        }
        XCTAssertEqual(X86Core.signBits(.max), 0xFF)
        XCTAssertEqual(X86Core.signBits(0x7F7F_7F7F_7F7F_7F7F), 0)
        XCTAssertEqual(X86Core.signBits(0x80), 1)
        XCTAssertEqual(X86Core.signBits(0x8000_0000_0000_0000), 0x80)
    }

    func testTheWholeShiftMovesBytesNotElements() {
        let values = Self.samples()
        for index in stride(from: 0, to: values.count - 1, by: 2) {
            let value = (low: values[index], high: values[index + 1])
            let source = X86Core.bytes(value)
            for count in UInt64(0)...17 {
                for left in [false, true] {
                    var expected = [UInt8](repeating: 0, count: 16)
                    for at in 0..<16 {
                        let from = left ? at - Int(count) : at + Int(count)
                        if from >= 0, from < 16 { expected[at] = source[from] }
                    }
                    let result = X86Core.shiftWhole(value, by: count, left: left)
                    XCTAssertTrue(result == X86Core.pack(expected), "\(count) \(left)")
                }
            }
        }
    }
}
