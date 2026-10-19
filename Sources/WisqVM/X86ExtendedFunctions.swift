import Foundation

// **Ce que la `libm` de Fedora 44 demande au x87**, pour ses `long double` :
// la racine, le reste partiel, la mise à l'échelle, l'extraction de
// l'exposant, et les constantes. Comme l'arithmétique de
// `X86ExtendedArithmetic.swift`, rien n'est délégué à l'hôte : chaque
// résultat est calculé sur des entiers, puis arrondi **une fois** par
// `assemble`.
extension X86Extended {
    /// Un « non pris en charge » : bit entier absent alors que l'exposant ne
    /// l'est pas, ou une valeur particulière sans son bit entier. Le
    /// processeur les refuse tous comme opérandes.
    var isUnsupported: Bool {
        guard biased != 0 else { return false }
        return significand & 0x8000_0000_0000_0000 == 0
    }

    /// **`FSQRT`.** La racine d'un nombre positif, arrondie une fois.
    ///
    /// La mantisse, mise à une puissance de deux paire, devient un entier de
    /// cent vingt-huit bits dont la racine entière tient sur soixante-quatre
    /// bits, bit de tête posé. Le reste dit où tombait la racine vraie :
    /// au-dessus de la moitié quand il dépasse la racine elle-même, puisque
    /// `(r + ½)² = r² + r + ¼`. L'égalité ne peut pas arriver.
    public static func squareRoot(_ value: X86Extended, rounding: Rounding) -> (X86Extended, Report) {
        if value.isUnsupported { return (indefinite, Report(Report.invalid)) }
        if value.isNaN { return value.isSignalingNaN ? (value.quieted, Report(Report.invalid)) : (value, Report()) }
        if value.isZero { return (value, Report()) }
        if value.negative { return (indefinite, Report(Report.invalid)) }
        if value.isInfinite { return (value, Report()) }
        var opening = Report()
        if value.biased == 0 { opening.note(Report.denormal) }
        let normal = value.normalized
        // valeur = m · 2^(e − bias − 63) ; la puissance doit être paire.
        let power = normal.exponent - bias - 63
        let even = power & 1 == 0
        let number = even ? (high: normal.significand, low: UInt64(0))
            : (high: normal.significand >> 1, low: normal.significand << 63)
        let (root, remainder) = integerSquareRoot(number)
        let exponent = bias + 63 + (power - (even ? 64 : 63)) / 2
        let rest: UInt64 = remainder == (0, 0) ? 0
            : (remainder.high > 0 || remainder.low > root ? 0xC000_0000_0000_0000 : 0x4000_0000_0000_0000)
        return merged(assemble(Wide(high: root, low: rest), exponent: exponent,
                               negative: false, rounding: rounding), opening)
    }

    /// La racine entière d'un nombre de cent vingt-huit bits au moins égal à
    /// 2¹²⁶ — elle tient donc sur soixante-quatre bits, bit de tête posé — et
    /// le reste, `n − r²`, sur deux mots. Une estimation par le double, puis
    /// Newton, puis la correction d'une unité qui reste.
    static func integerSquareRoot(_ number: (high: UInt64, low: UInt64))
        -> (root: UInt64, remainder: (high: UInt64, low: UInt64)) {
        let approximate = (Double(number.high) * 18_446_744_073_709_551_616.0 + Double(number.low)).squareRoot()
        var root = approximate >= 18_446_744_073_709_551_615.0 ? UInt64.max : UInt64(approximate)
        root = max(root, 0x8000_0000_0000_0000)
        for _ in 0..<3 where number.high < root {
            let quotient = root.dividingFullWidth(number).quotient
            let (sum, carry) = root.addingReportingOverflow(quotient)
            root = carry ? (sum >> 1) | 0x8000_0000_0000_0000 : sum >> 1
        }
        func square(_ value: UInt64) -> (high: UInt64, low: UInt64) {
            let product = value.multipliedFullWidth(by: value)
            return (product.high, product.low)
        }
        func greater(_ left: (high: UInt64, low: UInt64), _ right: (high: UInt64, low: UInt64)) -> Bool {
            left.high != right.high ? left.high > right.high : left.low > right.low
        }
        while greater(square(root), number) { root -= 1 }
        while root < UInt64.max, !greater(square(root + 1), number) { root += 1 }
        let squared = square(root)
        let (low, borrow) = number.low.subtractingReportingOverflow(squared.low)
        return (root, (number.high &- squared.high &- (borrow ? 1 : 0), low))
    }

    /// **`FPREM` et `FPREM1`** : le reste de `ST(0)` par `ST(1)`, exact, et les
    /// trois bits bas du quotient (C0 reçoit Q2, C3 Q1, C1 Q0). `FPREM`
    /// tronque le quotient, `FPREM1` l'arrondit au plus proche, pair en cas
    /// d'égalité — c'est le reste de IEEE.
    ///
    /// **Partiel quand les exposants sont trop loin.** Au-delà de soixante-
    /// trois rangs d'écart, le processeur ne fait qu'une partie du chemin,
    /// lève C2 et laisse au programme le soin de recommencer : il retire au
    /// dividende un multiple du diviseur décalé, de sorte que l'écart
    /// restant tombe entre 32 et 63. `reduction` est ce choix.
    public static func partialRemainder(_ dividend: X86Extended, _ divisor: X86Extended, nearest: Bool)
        -> (value: X86Extended, quotient: UInt64, complete: Bool, report: Report) {
        var opening = Report()
        if dividend.isUnsupported || divisor.isUnsupported {
            return (indefinite, 0, true, Report(Report.invalid))
        }
        if dividend.isSignalingNaN || divisor.isSignalingNaN { opening.note(Report.invalid) }
        if let answer = nan(dividend, divisor) { return (answer, 0, true, opening) }
        if dividend.isInfinite || divisor.isZero {
            opening.note(Report.invalid)
            return (indefinite, 0, true, opening)
        }
        if isDenormalOperand(dividend) || isDenormalOperand(divisor) { opening.note(Report.denormal) }
        if dividend.isZero || divisor.isInfinite { return (dividend, 0, true, opening) }

        let top = dividend.normalized, bottom = divisor.normalized
        var difference = top.exponent - bottom.exponent
        var complete = true
        var offset = 0
        if difference >= 64 {
            // La part du chemin faite en une fois : le diviseur est vu
            // décalé de `offset` rangs, l'écart restant devient
            // `reduction(difference)`, et le quotient de ce tour, tronqué
            // même pour `FPREM1`, n'est pas rendu.
            complete = false
            offset = difference - reduction(difference)
            difference -= offset
        }
        // Le dividende vu à l'exposant du diviseur, décalé de `difference`.
        // Hors de portée par le bas (écart négatif), le quotient est nul —
        // sauf pour `FPREM1`, où un dividende au-delà de la moitié du
        // diviseur le fait passer à un.
        var quotient: UInt64 = 0
        var magnitude: UInt64
        var exponent = bottom.exponent
        var negative = dividend.negative
        if difference < 0 {
            guard nearest, difference == -1, top.significand > bottom.significand else {
                return (dividend, 0, complete, opening)
            }
            // |x| entre la moitié de |y| et |y| : le reste est |y| − |x|,
            // de signe opposé, à l'exposant du dividende.
            magnitude = (bottom.significand << 1) &- top.significand
            exponent = top.exponent
            negative.toggle()
            quotient = 1
        } else {
            let shifted = (high: difference == 0 ? 0 : top.significand >> UInt64(64 - difference),
                           low: top.significand << UInt64(difference))
            let division = bottom.significand.dividingFullWidth(shifted)
            quotient = division.quotient
            magnitude = division.remainder
            if nearest && complete && magnitude != 0 {
                let half = bottom.significand - magnitude  // ce qu'il manque pour un diviseur de plus
                if magnitude > half || (magnitude == half && quotient & 1 == 1) {
                    magnitude = half
                    negative.toggle()
                    quotient &+= 1
                }
            }
            exponent = bottom.exponent + offset
        }
        if !complete { quotient = 0 }
        let (result, _) = assemble(Wide(high: magnitude, low: 0), exponent: exponent,
                                   negative: negative, rounding: .nearestEven)
        // Un reste nul garde le signe du dividende.
        let signed = magnitude == 0
            ? X86Extended(significand: 0, signExponent: dividend.negative ? 0x8000 : 0) : result
        return (signed, quotient, complete, opening)
    }

    /// L'écart d'exposants qui reste après un tour partiel de `FPREM`.
    static func reduction(_ difference: Int) -> Int { 32 + (difference - 32) % 32 }

    /// **`FSCALE`** : `ST(0) · 2^n`, où `n` est `ST(1)` tronqué vers zéro.
    /// Seul l'exposant change, et `assemble` se charge de ce qui déborde ou
    /// descend sous le plus petit normal.
    public static func scaled(_ value: X86Extended, by power: X86Extended, rounding: Rounding)
        -> (X86Extended, Report) {
        var opening = Report()
        if value.isUnsupported || power.isUnsupported { return (indefinite, Report(Report.invalid)) }
        if value.isSignalingNaN || power.isSignalingNaN { opening.note(Report.invalid) }
        if let answer = nan(value, power) { return (answer, opening) }
        if power.isInfinite {
            // Multiplier par 2^+∞ ou 2^−∞ : l'infini ou zéro, et les deux
            // formes indéterminées, 0 · 2^+∞ et ∞ · 2^−∞, sont invalides.
            if (value.isZero && !power.negative) || (value.isInfinite && power.negative) {
                opening.note(Report.invalid)
                return (indefinite, opening)
            }
            if value.isZero || value.isInfinite { return (value, opening) }
            if isDenormalOperand(value) { opening.note(Report.denormal) }
            return (power.negative ? X86Extended(significand: 0, signExponent: value.negative ? 0x8000 : 0)
                        : infinity(value.negative), opening)
        }
        if isDenormalOperand(value) || isDenormalOperand(power) { opening.note(Report.denormal) }
        if value.isZero || value.isInfinite { return (value, opening) }
        // Au-delà de ±2¹⁶, le résultat déborde ou s'évanouit de toute façon ;
        // borner garde l'arithmétique des exposants loin de ses limites.
        let whole = power.asInteger(bits: 64, rounding: .towardZero) ?? (power.negative ? -65_536 : 65_536)
        let shift = Int(max(-65_536, min(65_536, whole)))
        let normal = value.normalized
        return merged(assemble(Wide(high: normal.significand, low: 0), exponent: normal.exponent + shift,
                               negative: value.negative, rounding: rounding), opening)
    }

    /// **`FXTRACT`** : l'exposant vrai, en étendu, et la mantisse ramenée
    /// entre 1 et 2, de même signe. Zéro donne −∞ pour exposant et divise
    /// par zéro ; l'infini donne +∞ ; un dénormal est d'abord normalisé.
    public static func extracted(_ value: X86Extended) -> (exponent: X86Extended, significand: X86Extended, report: Report) {
        if value.isUnsupported { return (indefinite, indefinite, Report(Report.invalid)) }
        if value.isNaN {
            let quiet = value.quieted
            return (quiet, quiet, Report(value.isSignalingNaN ? Report.invalid : 0))
        }
        if value.isZero { return (infinity(true), value, Report(Report.zeroDivide)) }
        if value.isInfinite { return (infinity(false), value, Report()) }
        let normal = value.normalized
        let report = Report(value.biased == 0 ? Report.denormal : 0)
        return (X86Extended(Int64(normal.exponent - bias)),
                X86Extended(significand: normal.significand,
                            signExponent: UInt16(bias) | (value.negative ? 0x8000 : 0)), report)
    }

    /// **Les constantes du x87**, arrondies **juste** depuis leur valeur
    /// vraie, selon le mode : `FLDPI` rend `…C235` au plus proche et vers
    /// +∞, `…C234` vers −∞ et vers zéro. Chacune est gardée ici en
    /// soixante-quatre bits, deux bits de garde, et un bit collant toujours
    /// levé : aucune ne s'arrête au soixante-sixième.
    ///
    /// Le premier jet arrondissait sur les deux bits de garde seuls, comme si
    /// le processeur tronquait la constante à soixante-six bits. `FLDLG2`
    /// l'a démenti : ses deux bits valent exactement une demie, l'arrondi au
    /// pair gardait `…F798`, et le processeur rend `…F799` — ce qui suit les
    /// soixante-six bits compte.
    public enum Constant: UInt8, Sendable {
        case log2Of10 = 0xE9, log2OfE = 0xEA, pi = 0xEB, log10Of2 = 0xEC, logEOf2 = 0xED

        var parts: (significand: UInt64, guardBits: UInt64, signExponent: UInt16) {
            switch self {
            case .log2Of10: return (0xD49A_784B_CD1B_8AFE, 1, 0x4000)
            case .log2OfE: return (0xB8AA_3B29_5C17_F0BB, 2, 0x3FFF)
            case .pi: return (0xC90F_DAA2_2168_C234, 3, 0x4000)
            case .log10Of2: return (0x9A20_9A84_FBCF_F798, 2, 0x3FFD)
            case .logEOf2: return (0xB172_17F7_D1CF_79AB, 3, 0x3FFE)
            }
        }
    }

    public static func constant(_ constant: Constant, rounding: Rounding) -> (X86Extended, Report) {
        let parts = constant.parts
        var report = Report()
        var significand = parts.significand
        if roundsUp(rest: parts.guardBits << 62 | 1, even: significand & 1 == 0, negative: false, rounding: rounding) {
            significand += 1
            report.roundedUp = true
        }
        return (X86Extended(significand: significand, signExponent: parts.signExponent), report)
    }
}
