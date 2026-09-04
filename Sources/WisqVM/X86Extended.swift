import Foundation

// **Le flottant de quatre-vingts bits, en logiciel.**
//
// Swift a `Float80` sur x86 et **pas** sur l'ARM d'Apple. S'en servir ferait
// échouer la moitié de l'intégration continue — mais surtout, ce serait
// refaire à l'identique l'erreur que la tranche précédente vient de corriger :
// un émulateur dont le résultat dépend de la machine qui l'exécute n'émule
// rien. Le format est donc écrit ici, entièrement, et il donne les mêmes bits
// partout.
//
// **Ce qui distingue quatre-vingts bits de soixante-quatre**, et qui n'est pas
// qu'une question de taille : le bit entier de la mantisse est **explicite**.
// En simple et en double il est sous-entendu — toujours un, sauf pour les
// dénormaux. Ici il occupe une place, ce qui rend représentables des valeurs
// que rien d'autre ne distingue : une mantisse dont le bit de tête est zéro
// alors que l'exposant ne l'est pas est un « non-nombre non pris en charge »,
// que le processeur traite à part.
public struct X86Extended: Sendable, Equatable {
    /// Les soixante-quatre bits de mantisse, bit entier compris en tête.
    public var significand: UInt64
    /// Le signe dans le bit de poids fort, et l'exposant biaisé de 16 383 dans
    /// les quinze autres.
    public var signExponent: UInt16

    public init(significand: UInt64, signExponent: UInt16) {
        self.significand = significand
        self.signExponent = signExponent
    }

    public var negative: Bool { signExponent & 0x8000 != 0 }
    public var biased: Int { Int(signExponent & 0x7FFF) }

    public static let bias = 16383
    /// L'exposant biaisé qui signale un infini ou un NaN.
    public static let special = 0x7FFF

    public static let zero = X86Extended(significand: 0, signExponent: 0)
    /// « L'indéfini réel » : le NaN que le processeur fabrique quand
    /// l'opération elle-même est invalide. Il est **négatif**, comme en SSE.
    public static let indefinite = X86Extended(significand: 0xC000_0000_0000_0000,
                                               signExponent: 0xFFFF)

    public static func infinity(_ negative: Bool) -> X86Extended {
        X86Extended(significand: 0x8000_0000_0000_0000,
                    signExponent: negative ? 0xFFFF : 0x7FFF)
    }

    public var isZero: Bool { biased == 0 && significand == 0 }
    public var isSpecial: Bool { biased == Self.special }
    public var isInfinite: Bool { isSpecial && significand == 0x8000_0000_0000_0000 }
    public var isNaN: Bool { isSpecial && significand & 0x7FFF_FFFF_FFFF_FFFF != 0 }
    /// Un NaN dont le bit de tête de la fraction est à zéro **signale** ; les
    /// autres sont silencieux. C'est le bit 62, pas le 63 — celui-là est le
    /// bit entier, et il vaut un pour tout NaN bien formé.
    public var isSignalingNaN: Bool { isNaN && significand & 0x4000_0000_0000_0000 == 0 }
    public var quieted: X86Extended {
        X86Extended(significand: significand | 0x4000_0000_0000_0000,
                    signExponent: signExponent)
    }

    /// Les dix octets tels qu'ils vivent en mémoire.
    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: significand >> (UInt64($0) * 8)) }
            + [UInt8(truncatingIfNeeded: signExponent),
               UInt8(truncatingIfNeeded: signExponent >> 8)]
    }

    public init(bytes: [UInt8]) {
        var low: UInt64 = 0
        for index in 0..<8 { low |= UInt64(bytes[index]) << (UInt64(index) * 8) }
        significand = low
        signExponent = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
    }
}

// MARK: - Les conversions

extension X86Extended {
    /// Un entier signé vers l'étendu. Exact : soixante-quatre bits de mantisse
    /// portent n'importe quel entier de soixante-quatre bits sans perte, ce
    /// qui n'est pas vrai d'un double.
    public init(_ value: Int64) {
        guard value != 0 else { self = .zero; return }
        let negative = value < 0
        let magnitude = value.magnitude
        let leading = magnitude.leadingZeroBitCount
        significand = magnitude << UInt64(leading)
        let exponent = 63 - leading + Self.bias
        signExponent = UInt16(exponent) | (negative ? 0x8000 : 0)
    }

    /// Un double vers l'étendu. Exact aussi, dans l'autre sens : tout double
    /// tient dans un étendu.
    public init(_ value: Double) {
        let bits = value.bitPattern
        let negative = bits & 0x8000_0000_0000_0000 != 0
        let exponent = Int((bits >> 52) & 0x7FF)
        let fraction = bits & 0x000F_FFFF_FFFF_FFFF
        if exponent == 0x7FF {
            // Infini ou NaN : la fraction monte de onze bits, et le bit entier
            // est posé.
            significand = 0x8000_0000_0000_0000 | (fraction << 11)
            signExponent = UInt16(Self.special) | (negative ? 0x8000 : 0)
            return
        }
        if exponent == 0 {
            guard fraction != 0 else {
                self = X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0)
                return
            }
            // Un dénormal double devient un nombre normal en étendu : la plage
            // d'exposants y est bien plus large.
            let leading = fraction.leadingZeroBitCount
            significand = fraction << UInt64(leading)
            let real = 1 - 1023 - (leading - 11) + Self.bias
            signExponent = UInt16(real) | (negative ? 0x8000 : 0)
            return
        }
        significand = 0x8000_0000_0000_0000 | (fraction << 11)
        signExponent = UInt16(exponent - 1023 + Self.bias) | (negative ? 0x8000 : 0)
    }

    /// Vers le double, avec l'arrondi au plus proche et pair.
    public var asDouble: Double {
        if isZero { return negative ? -0.0 : 0.0 }
        if isSpecial {
            if isInfinite { return negative ? -.infinity : .infinity }
            // **Un NaN qui rétrécit devient silencieux.** Le bit de tête de
            // la fraction est posé au passage : c'est ce que fait `FSTP m64`
            // d'un NaN signalant, et l'oublier range en mémoire un NaN qui
            // signalera chez celui qui le relira.
            let fraction = ((significand & 0x7FFF_FFFF_FFFF_FFFF) >> 11)
                | 0x0008_0000_0000_0000
            let bits = (negative ? UInt64(0x8000_0000_0000_0000) : 0)
                | (0x7FF << 52) | fraction
            return Double(bitPattern: bits)
        }
        let exponent = biased - Self.bias
        guard exponent >= -1022 else { return negative ? -0.0 : 0.0 }
        guard exponent <= 1023 else { return negative ? -.infinity : .infinity }
        // Onze bits de trop : on arrondit au plus proche, pair en cas
        // d'égalité.
        var fraction = (significand & 0x7FFF_FFFF_FFFF_FFFF) >> 11
        let dropped = significand & 0x7FF
        var raised = exponent
        if dropped > 0x400 || (dropped == 0x400 && fraction & 1 == 1) {
            fraction += 1
            if fraction > 0x000F_FFFF_FFFF_FFFF {
                fraction = 0
                raised += 1
                guard raised <= 1023 else { return negative ? -.infinity : .infinity }
            }
        }
        let bits = (negative ? UInt64(0x8000_0000_0000_0000) : 0)
            | (UInt64(raised + 1023) << 52) | fraction
        return Double(bitPattern: bits)
    }

    /// **Rétrécir vers le simple ou le double**, avec ce que ça coûte.
    ///
    /// C'est là que se perdent des bits, et le processeur le dit : inexact
    /// quand quelque chose est tombé, débordement quand la valeur ne tient
    /// plus, sous-débordement quand elle descend sous le plus petit normal,
    /// invalide quand la source est un NaN signalant. Rendre la bonne valeur
    /// sans ces drapeaux serait juste à moitié.
    public func narrowed(fractionBits: Int, exponentBits: Int,
                         rounding: Rounding) -> (bits: UInt64, report: Report) {
        var report = Report()
        let maximum = (1 << (exponentBits - 1)) - 1
        let minimum = 2 - (1 << (exponentBits - 1))
        let signBit = UInt64(negative ? 1 : 0) << UInt64(fractionBits + exponentBits)
        let allOnes = UInt64((1 << exponentBits) - 1)
        if isZero { return (signBit, report) }
        if isSpecial {
            if isInfinite { return (signBit | (allOnes << UInt64(fractionBits)), report) }
            if isSignalingNaN { report.note(Report.invalid) }
            // La charge utile descend, et le bit silencieux est posé.
            let payload = (significand & 0x7FFF_FFFF_FFFF_FFFF) >> UInt64(63 - fractionBits)
            let quiet = UInt64(1) << UInt64(fractionBits - 1)
            return (signBit | (allOnes << UInt64(fractionBits)) | quiet | payload, report)
        }
        let normal = self.normalized
        var exponent = normal.exponent - Self.bias
        var value = Wide(high: normal.significand, low: 0)
        // Aligner : garder un bit de plus que la fraction, l'entier compris.
        value.shift(right: 63 - fractionBits)
        if exponent < minimum {
            value.shift(right: min(minimum - exponent, 127))
            exponent = minimum
            if value.high == 0, value.low == 0 {
                report.note(Report.underflow | Report.inexact)
                return (signBit, report)
            }
        }
        if value.low != 0 { report.note(Report.inexact) }
        if Self.roundsUp(rest: value.low, even: value.high & 1 == 0,
                         negative: negative, rounding: rounding) {
            value.high += 1
            report.roundedUp = true
        }
        let implicit = UInt64(1) << UInt64(fractionBits)
        if value.high >= implicit << 1 {
            value.high >>= 1
            exponent += 1
        }
        if exponent > maximum {
            // Un débordement vers l'infini est un arrondi **vers le haut** en
            // valeur absolue, et C1 le dit : le programme qui le lit sait dans
            // quel sens il a perdu.
            report.note(Report.overflow | Report.inexact)
            report.roundedUp = true
            return (signBit | (allOnes << UInt64(fractionBits)), report)
        }
        if value.high < implicit {
            // Un dénormal du format visé : l'exposant tombe à zéro.
            if report.flags & Report.inexact != 0 { report.note(Report.underflow) }
            return (signBit | value.high, report)
        }
        let biased = UInt64(exponent - minimum + 1)
        return (signBit | (biased << UInt64(fractionBits))
                | (value.high & (implicit - 1)), report)
    }

    /// Vers un entier signé, tronqué vers zéro ou arrondi selon le mode.
    /// Rend `nil` quand la valeur ne tient pas — l'appelant range alors
    /// l'entier indéfini, comme le fait le processeur.
    public func asInteger(bits: Int, rounding: X86Extended.Rounding) -> Int64? {
        if isZero { return 0 }
        guard !isSpecial else { return nil }
        let exponent = biased - Self.bias
        guard exponent >= 0 || rounding != .towardZero || exponent >= -1 else { return 0 }
        guard exponent < bits else {
            // Le seul débordement acceptable est la borne négative exacte.
            if negative, exponent == bits - 1, significand == 0x8000_0000_0000_0000 {
                return bits == 64 ? Int64.min : -(Int64(1) << (bits - 1))
            }
            return nil
        }
        var whole: UInt64 = 0
        var rest: UInt64 = 0
        if exponent >= 63 {
            whole = significand
        } else if exponent >= 0 {
            whole = significand >> UInt64(63 - exponent)
            rest = significand << UInt64(exponent + 1)
        } else {
            rest = exponent == -1 ? significand : 0
        }
        if Self.roundsUp(rest: rest, even: whole & 1 == 0,
                         negative: negative, rounding: rounding) {
            whole += 1
        }
        let limit: UInt64 = bits == 64 ? 0x8000_0000_0000_0000 : (UInt64(1) << (bits - 1))
        if negative {
            guard whole <= limit else { return nil }
            return whole == limit ? (bits == 64 ? Int64.min : -Int64(limit))
                : -Int64(whole)
        }
        guard whole < limit else { return nil }
        return Int64(whole)
    }

    static func roundsUp(rest: UInt64, even: Bool, negative: Bool,
                         rounding: Rounding) -> Bool {
        guard rest != 0 else { return false }
        switch rounding {
        case .nearestEven:
            if rest > 0x8000_0000_0000_0000 { return true }
            if rest < 0x8000_0000_0000_0000 { return false }
            return !even
        case .towardZero: return false
        case .down: return negative
        case .up: return !negative
        }
    }

    /// **Ce que le calcul a rencontré en chemin.**
    ///
    /// Un cœur qui calcule juste et rend compte faux est un cœur faux : musl
    /// lit le mot d'état trente-sept fois dans son `printf`, et s'en sert pour
    /// décider. Les six drapeaux occupent les bits 0 à 5 du mot d'état, dans
    /// cet ordre, et le septième — C1, le bit 9 — dit si l'arrondi est monté.
    public struct Report: Sendable {
        public var flags: UInt16 = 0
        public var roundedUp = false

        public static let invalid: UInt16 = 1 << 0
        public static let denormal: UInt16 = 1 << 1
        public static let zeroDivide: UInt16 = 1 << 2
        public static let overflow: UInt16 = 1 << 3
        public static let underflow: UInt16 = 1 << 4
        public static let inexact: UInt16 = 1 << 5

        public init(_ flags: UInt16 = 0, roundedUp: Bool = false) {
            self.flags = flags
            self.roundedUp = roundedUp
        }

        public mutating func note(_ bit: UInt16) { flags |= bit }
    }

    /// La même valeur sans sa partie fractionnaire, pour dire si une
    /// conversion vers l'entier a perdu quelque chose.
    public var rounded: X86Extended {
        guard !isZero, !isSpecial else { return self }
        let exponent = biased - Self.bias
        guard exponent < 63 else { return self }
        guard exponent >= 0 else {
            return X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0)
        }
        let keep = UInt64(63 - exponent)
        let mask = keep >= 64 ? UInt64.max : ((UInt64(1) << keep) - 1)
        return X86Extended(significand: significand & ~mask, signExponent: signExponent)
    }

    /// Les quatre modes d'arrondi, tels que les bits 10 et 11 du mot de
    /// contrôle les nomment.
    public enum Rounding: Sendable {
        case nearestEven, down, up, towardZero

        public init(control: UInt16) {
            switch (control >> 10) & 0x03 {
            case 1: self = .down
            case 2: self = .up
            case 3: self = .towardZero
            default: self = .nearestEven
            }
        }
    }
}
