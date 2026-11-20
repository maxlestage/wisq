import XCTest

@testable import WisqVM

/// **Les seize conditions, devant tous les drapeaux.**
///
/// `X86Core.condition` ne passe plus par un aiguillage : elle range les huit
/// conditions de base dans un mot et y prend la sienne par un décalage. Une
/// place fausse dans ce mot ne se verrait que sur la condition qui l'occupe,
/// et les corpus matériels ne portent pas toutes les combinaisons. Ce test
/// les porte toutes : seize codes devant les soixante-quatre états de CF, PF,
/// AF, ZF, SF et OF, contre la définition du manuel écrite ici une seconde
/// fois, cas par cas.
final class X86ConditionTests: XCTestCase {
    /// La définition, telle que le manuel la donne (Jcc, volume 2).
    struct Flags {
        let carry: Bool
        let parity: Bool
        let zero: Bool
        let sign: Bool
        let overflow: Bool
    }

    static func manual(_ code: UInt8, _ flags: Flags) -> Bool {
        let (carry, parity, zero, sign, overflow) = (flags.carry, flags.parity, flags.zero, flags.sign,
                                                     flags.overflow)
        switch code {
        case 0x0: return overflow                      // O
        case 0x1: return !overflow                     // NO
        case 0x2: return carry                         // B, C, NAE
        case 0x3: return !carry                        // AE, NB, NC
        case 0x4: return zero                          // E, Z
        case 0x5: return !zero                         // NE, NZ
        case 0x6: return carry || zero                 // BE, NA
        case 0x7: return !carry && !zero               // A, NBE
        case 0x8: return sign                          // S
        case 0x9: return !sign                         // NS
        case 0xA: return parity                        // P, PE
        case 0xB: return !parity                       // NP, PO
        case 0xC: return sign != overflow              // L, NGE
        case 0xD: return sign == overflow              // GE, NL
        case 0xE: return zero || sign != overflow      // LE, NG
        default: return !zero && sign == overflow      // G, NLE
        }
    }

    func testEveryConditionReadsItsFlags() {
        typealias Flag = X86Core.Flag
        var core = X86Core()
        var checked = 0
        for combination in 0..<64 {
            let carry = combination & 1 != 0
            let parity = combination & 2 != 0
            let zero = combination & 4 != 0
            let sign = combination & 8 != 0
            let overflow = combination & 16 != 0
            // La retenue auxiliaire ne décide d'aucune condition, et le bit
            // d'interruption non plus : ils sont là pour ne rien changer.
            let auxiliary = combination & 32 != 0
            core.flags = Flag.reserved | (carry ? Flag.carry : 0) | (parity ? Flag.parity : 0)
                | (zero ? Flag.zero : 0) | (sign ? Flag.sign : 0) | (overflow ? Flag.overflow : 0)
                | (auxiliary ? Flag.auxiliary | Flag.interrupt : 0)
            for code in UInt8(0)..<16 {
                let expected = Self.manual(code, Flags(carry: carry, parity: parity, zero: zero,
                                                       sign: sign, overflow: overflow))
                // Le code arrive avec son opcode : seuls ses quatre bits du
                // bas comptent, sous `7x`, `0F 8x`, `0F 9x` comme sous `0F 4x`.
                for high in [0x00, 0x70, 0x80, 0x90, 0x40] as [UInt8] {
                    XCTAssertEqual(core.condition(high | code), expected,
                                   "condition \(code) sous \(String(high, radix: 16)), drapeaux \(String(core.flags, radix: 16))")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 64 * 16 * 5)
    }
}
