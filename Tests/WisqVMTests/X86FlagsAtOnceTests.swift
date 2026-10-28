import XCTest

@testable import WisqVM

/// Les six drapeaux de l'arithmétique, écrits d'un coup.
///
/// **Ce que la mesure a montré.** `ADD`, `SUB`, `CMP` et les opérations
/// logiques posaient leurs drapeaux un par un : six écritures de `flags`, et
/// une branche pour chacune. Sous callgrind, la seule ligne de `set` pesait
/// 2,2 % des instructions de l'hôte au démarrage du vrai noyau. Ils sont
/// maintenant calculés à part et rangés en une écriture.
///
/// La référence, ici, est l'ancienne façon, recopiée telle quelle : bit à
/// bit, avec ses branches. Les deux doivent donner le même mot de drapeaux
/// pour toutes les largeurs, toutes les retenues entrantes, et **quel que
/// soit l'état des drapeaux qui ne sont pas les leurs** — l'interruption, la
/// direction, le piège ne doivent pas bouger.
final class X86FlagsAtOnceTests: XCTestCase {
    typealias Flag = X86Core.Flag

    /// L'ancienne pose, drapeau par drapeau.
    static func set(_ flags: inout UInt64, _ flag: UInt64, _ on: Bool) {
        if on { flags |= flag } else { flags &= ~flag }
    }

    static func referenceResult(_ flags: inout UInt64, _ result: UInt64, _ size: Int) {
        set(&flags, Flag.zero, result & X86Core.mask(size) == 0)
        set(&flags, Flag.sign, result & X86Core.signBit(size) != 0)
        set(&flags, Flag.parity, (result & 0xFF).nonzeroBitCount % 2 == 0)
    }

    static func referenceAdd(_ flags: inout UInt64, _ a: UInt64, _ b: UInt64, _ size: Int,
                             _ carryIn: UInt64) -> UInt64 {
        let mask = X86Core.mask(size)
        let wide = size == 8 ? a &+ b &+ carryIn : (a & mask) &+ (b & mask) &+ carryIn
        let carryOut = size == 8
            ? a.addingReportingOverflow(b).overflow
                || (a &+ b).addingReportingOverflow(carryIn).overflow
            : wide >> UInt64(8 * size) != 0
        let result = wide & mask
        set(&flags, Flag.carry, carryOut)
        set(&flags, Flag.auxiliary, ((a ^ b ^ result) >> 4) & 1 != 0)
        set(&flags, Flag.overflow, ((a ^ result) & (b ^ result) & X86Core.signBit(size)) != 0)
        referenceResult(&flags, result, size)
        return result
    }

    static func referenceSubtract(_ flags: inout UInt64, _ a: UInt64, _ b: UInt64, _ size: Int,
                                  _ borrowIn: UInt64) -> UInt64 {
        let mask = X86Core.mask(size)
        let result = ((a & mask) &- (b & mask) &- borrowIn) & mask
        let borrowOut = (a & mask) < (b & mask) || (borrowIn != 0 && (a & mask) == (b & mask))
        set(&flags, Flag.carry, borrowOut)
        set(&flags, Flag.auxiliary, ((a ^ b ^ result) >> 4) & 1 != 0)
        set(&flags, Flag.overflow, ((a ^ b) & (a ^ result) & X86Core.signBit(size)) != 0)
        referenceResult(&flags, result, size)
        return result
    }

    static func referenceLogic(_ flags: inout UInt64, _ value: UInt64, _ size: Int) -> UInt64 {
        let result = value & X86Core.mask(size)
        set(&flags, Flag.carry, false)
        set(&flags, Flag.overflow, false)
        set(&flags, Flag.auxiliary, false)
        referenceResult(&flags, result, size)
        return result
    }

    /// Des valeurs qui touchent les bords : zéro, un, les bits de signe et
    /// les masques de chaque largeur, plus un générateur fixe pour le reste.
    static func operands() -> [UInt64] {
        var values: [UInt64] = [0, 1, 0x0F, 0x10, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000,
                                0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF,
                                0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, .max]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<40 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.append(state)
        }
        return values
    }

    func core(flags: UInt64) -> X86Core {
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0,
                           memory: X86Memory(size: 0x1000, base: 0))
        core.flags = flags
        return core
    }

    /// Tous les bits de départ possibles parmi ceux qu'on surveille : les six
    /// de l'arithmétique et trois qui ne sont pas à elle.
    static let startingFlags: [UInt64] = [
        0, Flag.reserved, ~UInt64(0) & 0x3F_FFFF,
        Flag.interrupt | Flag.trap | 0x400, Flag.carry | Flag.zero | Flag.interrupt,
    ]

    func testAdditionMatchesTheFlagByFlagReference() {
        let values = Self.operands()
        for size in [1, 2, 4, 8] {
            for start in Self.startingFlags {
                for carryIn: UInt64 in [0, 1] {
                    for a in values {
                        for b in values {
                            var expected = start
                            let want = Self.referenceAdd(&expected, a, b, size, carryIn)
                            var cpu = core(flags: start)
                            let got = cpu.add(a, b, size, carryIn: carryIn)
                            guard got == want, cpu.flags == expected else {
                                return XCTFail("""
                                    add \(a) + \(b) + \(carryIn) sur \(size) octets, drapeaux \
                                    \(String(start, radix: 16)) : \(got) / \
                                    \(String(cpu.flags, radix: 16)), attendu \(want) / \
                                    \(String(expected, radix: 16))
                                    """)
                            }
                        }
                    }
                }
            }
        }
    }

    func testSubtractionMatchesTheFlagByFlagReference() {
        let values = Self.operands()
        for size in [1, 2, 4, 8] {
            for start in Self.startingFlags {
                for borrowIn: UInt64 in [0, 1] {
                    for a in values {
                        for b in values {
                            var expected = start
                            let want = Self.referenceSubtract(&expected, a, b, size, borrowIn)
                            var cpu = core(flags: start)
                            let got = cpu.subtract(a, b, size, borrowIn: borrowIn)
                            guard got == want, cpu.flags == expected else {
                                return XCTFail("""
                                    sub \(a) - \(b) - \(borrowIn) sur \(size) octets, drapeaux \
                                    \(String(start, radix: 16)) : \(got) / \
                                    \(String(cpu.flags, radix: 16)), attendu \(want) / \
                                    \(String(expected, radix: 16))
                                    """)
                            }
                        }
                    }
                }
            }
        }
    }

    func testLogicMatchesTheFlagByFlagReference() {
        for size in [1, 2, 4, 8] {
            for start in Self.startingFlags {
                for value in Self.operands() {
                    var expected = start
                    let want = Self.referenceLogic(&expected, value, size)
                    var cpu = core(flags: start)
                    XCTAssertEqual(cpu.logic(value, size), want)
                    XCTAssertEqual(cpu.flags, expected,
                                   "logique sur \(value), \(size) octets, drapeaux \(String(start, radix: 16))")
                }
            }
        }
    }

    /// **Ce qui n'est pas à l'arithmétique ne bouge pas.** Une soustraction
    /// qui efface tout ce qu'elle touche — résultat nul, sans retenue — sous
    /// des interruptions permises, une direction posée et le piège armé.
    func testTheOtherFlagsSurviveAnArithmeticWrite() {
        let others = Flag.interrupt | Flag.trap | 0x400 | Flag.reserved
        var cpu = core(flags: others | X86Core.arithmeticFlags)
        _ = cpu.subtract(5, 5, 4)
        XCTAssertEqual(cpu.flags & others, others, "l'interruption, le piège et la direction restent")
        XCTAssertEqual(cpu.flags & X86Core.arithmeticFlags, Flag.zero | Flag.parity,
                       "cinq moins cinq : zéro, pair, rien d'autre")
    }

    /// Le signe d'un résultat qui déborde de sa largeur : seul compte le bit
    /// de signe de la largeur, pas ce qui traîne au-dessus.
    func testTheSignIsReadAtTheOperandWidth() {
        XCTAssertEqual(X86Core.resultFlagBits(0x180, 1) & Flag.sign, Flag.sign)
        XCTAssertEqual(X86Core.resultFlagBits(0x17F, 1) & Flag.sign, 0)
        XCTAssertEqual(X86Core.resultFlagBits(0x1_0000_8000, 2) & Flag.sign, Flag.sign)
        XCTAssertEqual(X86Core.resultFlagBits(0x8000_0000_0000_0000, 8) & Flag.sign, Flag.sign)
        XCTAssertEqual(X86Core.resultFlagBits(0x8000_0000, 8) & Flag.sign, 0)
    }
}
