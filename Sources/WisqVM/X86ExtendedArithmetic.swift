import Foundation

// **L'arithmétique de quatre-vingts bits.**
//
// Rien n'est délégué à l'hôte ici : ni le calcul, ni l'arrondi, ni le
// traitement des NaN. Un `Double` ne porte que cinquante-trois bits de
// mantisse, et le corpus matériel contient exprès des valeurs qui ne tiennent
// pas dedans — `1 + 2⁻⁶³`, π sur soixante-quatre bits, `2⁶⁴ - 1`. Une
// implémentation qui passerait par le double les manquerait toutes, et le
// fichier d'oracle est fait pour que ça se voie.
//
// **Le travail se fait sur cent vingt-huit bits.** Une addition doit garder
// ce qui sort par le bas pour arrondir juste : un bit de garde, un d'arrondi,
// et un bit « collant » qui retient qu'il y avait autre chose. Les trois
// tiennent dans la moitié basse, et c'est elle qui décide de l'arrondi final.
extension X86Extended {
    /// Une mantisse de cent vingt-huit bits : soixante-quatre qui comptent, et
    /// soixante-quatre qui servent à arrondir.
    struct Wide {
        var high: UInt64
        var low: UInt64

        /// Décale à droite en **gardant** ce qui sort : le bit de poids
        /// faible de la moitié basse devient collant. Sans lui, une valeur
        /// écartée de justesse serait arrondie comme une valeur exacte.
        mutating func shift(right count: Int) {
            guard count > 0 else { return }
            guard count < 128 else {
                low = (high | low) == 0 ? 0 : 1
                high = 0
                return
            }
            var sticky: UInt64 = 0
            if count >= 64 {
                sticky = low != 0 ? 1 : 0
                low = high
                high = 0
                let rest = count - 64
                if rest > 0 {
                    if low & ((UInt64(1) << rest) - 1) != 0 { sticky = 1 }
                    low >>= UInt64(rest)
                }
            } else {
                if low & ((UInt64(1) << count) - 1) != 0 { sticky = 1 }
                low = (low >> UInt64(count)) | (high << UInt64(64 - count))
                high >>= UInt64(count)
            }
            low |= sticky
        }
    }

    /// Range une mantisse de cent vingt-huit bits dans un étendu, en
    /// normalisant puis en arrondissant.
    static func assemble(_ wide: Wide, exponent: Int, negative: Bool,
                         rounding: Rounding) -> (X86Extended, Report) {
        var report = Report()
        var value = wide
        var power = exponent
        guard value.high != 0 || value.low != 0 else {
            return (X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0), report)
        }
        // Normaliser : le bit de tête doit occuper la place du bit entier.
        while value.high & 0x8000_0000_0000_0000 == 0 {
            value.high = (value.high << 1) | (value.low >> 63)
            value.low <<= 1
            power -= 1
        }
        // Arrondir sur ce que la moitié basse retient.
        if value.low != 0 { report.note(Report.inexact) }
        if roundsUp(rest: value.low, even: value.high & 1 == 0,
                    negative: negative, rounding: rounding) {
            report.roundedUp = true
            let (sum, carry) = value.high.addingReportingOverflow(1)
            value.high = sum
            if carry {
                value.high = 0x8000_0000_0000_0000
                power += 1
            }
        }
        guard power < special else {
            // Débordement : l'infini, sauf si l'arrondi le refuse.
            report.note(Report.overflow | Report.inexact)
            report.roundedUp = true
            switch rounding {
            case .towardZero, .down where !negative, .up where negative:
                return (X86Extended(significand: 0xFFFF_FFFF_FFFF_FFFF,
                                    signExponent: UInt16(special - 1)
                                        | (negative ? 0x8000 : 0)), report)
            default: return (infinity(negative), report)
            }
        }
        guard power > 0 else {
            // **Sous-débordement graduel.** Le premier jet rendait zéro et
            // documentait ce choix comme sûr, au motif que la plage
            // d'exposants de quatre-vingts bits était trop large pour qu'on y
            // descende. Le corpus l'a démenti en une exécution : additionner
            // deux dénormaux rend un dénormal, pas zéro. La mantisse glisse
            // vers la droite jusqu'à ce que l'exposant atteigne son plancher,
            // et ce qui sort par le bas décide encore de l'arrondi.
            var narrowed = value
            narrowed.shift(right: 1 - power)
            if narrowed.low != 0 { report.note(Report.underflow | Report.inexact) }
            if roundsUp(rest: narrowed.low, even: narrowed.high & 1 == 0,
                        negative: negative, rounding: rounding) {
                narrowed.high &+= 1
                report.roundedUp = true
            }
            // L'arrondi peut faire remonter au plus petit normal.
            let exponent: UInt16 = narrowed.high & 0x8000_0000_0000_0000 != 0 ? 1 : 0
            return (X86Extended(significand: narrowed.high,
                                signExponent: exponent | (negative ? 0x8000 : 0)), report)
        }
        return (X86Extended(significand: value.high,
                            signExponent: UInt16(power) | (negative ? 0x8000 : 0)), report)
    }

    /// **La mantisse et l'exposant vrais, bit de tête posé.**
    ///
    /// Un dénormal porte un exposant biaisé nul et une mantisse dont le bit de
    /// tête ne l'est pas ; son exposant vrai est celui du plus petit normal,
    /// pas zéro. Le calcul se fait donc sur une forme normalisée, quitte à ce
    /// que l'exposant devienne négatif — `assemble` s'en charge.
    ///
    /// Ce n'est pas qu'une commodité. `dividingFullWidth` **piège** quand le
    /// diviseur est plus petit que la moitié haute du dividende, et un
    /// diviseur dénormal le garantit. Le premier cas du corpus qui a divisé
    /// par un dénormal a tué la suite de tests par un signal, pas par un
    /// désaccord.
    var normalized: (significand: UInt64, exponent: Int) {
        guard !isZero, !isSpecial else { return (significand, biased) }
        let real = biased == 0 ? 1 : biased
        guard significand & 0x8000_0000_0000_0000 == 0 else { return (significand, real) }
        let leading = significand.leadingZeroBitCount
        return (significand << UInt64(leading), real - leading)
    }

    /// Ce que le processeur rend quand l'un des opérandes est un NaN.
    ///
    /// **La règle n'est pas « le premier gagne ».** Entre deux NaN, x87 rend
    /// celui dont la mantisse est la plus grande ; à égalité, la destination.
    /// Un NaN signalant est rendu silencieux au passage.
    static func nan(_ left: X86Extended, _ right: X86Extended) -> X86Extended? {
        if left.isNaN, right.isNaN {
            return (right.significand > left.significand ? right : left).quieted
        }
        if left.isNaN { return left.quieted }
        if right.isNaN { return right.quieted }
        return nil
    }

    public static func add(_ left: X86Extended, _ right: X86Extended,
                           rounding: Rounding) -> (X86Extended, Report) {
        var opening = Report()
        // **L'invalidité prime sur le dénormal.** Quand un NaN signalant part,
        // le processeur ne signale pas en plus qu'un opérande était dénormal :
        // l'opération est abandonnée avant d'en arriver là. Les poser tous les
        // deux ferait dire au mot d'état une chose que la machine ne dit pas.
        if left.isSignalingNaN || right.isSignalingNaN {
            opening.note(Report.invalid)
        } else if isDenormalOperand(left) || isDenormalOperand(right) {
            opening.note(Report.denormal)
        }
        if let answer = nan(left, right) { return (answer, opening) }
        if left.isInfinite || right.isInfinite {
            guard left.isInfinite, right.isInfinite else {
                return (left.isInfinite ? left : right, opening)
            }
            guard left.negative == right.negative else {
                opening.note(Report.invalid)
                return (indefinite, opening)
            }
            return (left, opening)
        }
        if left.isZero, right.isZero {
            // Deux zéros : le signe ne survit que s'ils s'accordent, sauf en
            // arrondi vers le bas où le moins l'emporte.
            let negative = left.negative == right.negative
                ? left.negative : (rounding == .down)
            return (X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0), opening)
        }
        if left.isZero { return (right, opening) }
        if right.isZero { return (left, opening) }

        var high = left, low = right
        var bigger = left.normalized, smaller = right.normalized
        if smaller.exponent > bigger.exponent
            || (smaller.exponent == bigger.exponent
                && smaller.significand > bigger.significand) {
            swap(&high, &low)
            swap(&bigger, &smaller)
        }
        var first = Wide(high: bigger.significand, low: 0)
        var second = Wide(high: smaller.significand, low: 0)
        second.shift(right: bigger.exponent - smaller.exponent)

        if high.negative == low.negative {
            var exponent = bigger.exponent
            let (sum, carry) = first.high.addingReportingOverflow(second.high)
            let (bottom, spill) = first.low.addingReportingOverflow(second.low)
            first.low = bottom
            first.high = sum
            if spill {
                let (again, more) = first.high.addingReportingOverflow(1)
                first.high = again
                if more || carry {
                    first.shift(right: 1)
                    first.high |= 0x8000_0000_0000_0000
                    exponent += 1
                    return merged(assemble(first, exponent: exponent,
                                           negative: high.negative,
                                           rounding: rounding), opening)
                }
            }
            if carry {
                first.shift(right: 1)
                first.high |= 0x8000_0000_0000_0000
                exponent += 1
            }
            return merged(assemble(first, exponent: exponent,
                                   negative: high.negative, rounding: rounding), opening)
        }
        // Signes opposés : une soustraction, et le plus grand décide du signe.
        var borrowed = first.low &- second.low
        let borrow = first.low < second.low
        first.low = borrowed
        borrowed = first.high &- second.high &- (borrow ? 1 : 0)
        first.high = borrowed
        // **Deux valeurs égales qui s'annulent rendent un zéro POSITIF**, quel
        // que soit leur signe — sauf en arrondi vers le bas, où c'est le moins
        // qui l'emporte. C'est une règle d'IEEE 754 que le signe du plus grand
        // opérande contredirait : `x - x` vaut `+0` même pour un `x` négatif.
        if first.high == 0, first.low == 0 {
            return (X86Extended(significand: 0,
                                signExponent: rounding == .down ? 0x8000 : 0), opening)
        }
        return merged(assemble(first, exponent: bigger.exponent,
                               negative: high.negative, rounding: rounding), opening)
    }

    public static func subtract(_ left: X86Extended, _ right: X86Extended,
                                rounding: Rounding) -> (X86Extended, Report) {
        if let answer = nan(left, right) {
            var report = Report()
            if left.isSignalingNaN || right.isSignalingNaN { report.note(Report.invalid) }
            return (answer, report)
        }
        let flipped = X86Extended(significand: right.significand,
                                  signExponent: right.signExponent ^ 0x8000)
        return add(left, flipped, rounding: rounding)
    }

    public static func multiply(_ left: X86Extended, _ right: X86Extended,
                                rounding: Rounding) -> (X86Extended, Report) {
        var opening = Report()
        // **L'invalidité prime sur le dénormal.** Quand un NaN signalant part,
        // le processeur ne signale pas en plus qu'un opérande était dénormal :
        // l'opération est abandonnée avant d'en arriver là. Les poser tous les
        // deux ferait dire au mot d'état une chose que la machine ne dit pas.
        if left.isSignalingNaN || right.isSignalingNaN {
            opening.note(Report.invalid)
        } else if isDenormalOperand(left) || isDenormalOperand(right) {
            opening.note(Report.denormal)
        }
        if let answer = nan(left, right) { return (answer, opening) }
        let negative = left.negative != right.negative
        if left.isInfinite || right.isInfinite {
            if left.isZero || right.isZero {
                opening.note(Report.invalid)
                return (indefinite, opening)
            }
            return (infinity(negative), opening)
        }
        if left.isZero || right.isZero {
            return (X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0), opening)
        }
        let first = left.normalized, second = right.normalized
        let (high, low) = first.significand.multipliedFullWidth(by: second.significand)
        // Les deux bits de tête sont posés, donc le produit occupe le rang 127
        // ou le rang 126 ; l'exposant s'ajuste dans `assemble`.
        return merged(assemble(Wide(high: high, low: low),
                               exponent: first.exponent + second.exponent - bias + 1,
                               negative: negative, rounding: rounding), opening)
    }

    public static func divide(_ left: X86Extended, _ right: X86Extended,
                              rounding: Rounding) -> (X86Extended, Report) {
        // **Le dénormal ne se note qu'en arrivant au calcul.** L'invalidité et
        // la division par zéro abandonnent l'opération avant, et le processeur
        // ne signale alors pas en plus qu'un opérande était dénormal. Les
        // poser ensemble ferait dire au mot d'état une chose que la machine ne
        // dit pas.
        var opening = Report()
        if left.isSignalingNaN || right.isSignalingNaN { opening.note(Report.invalid) }
        if let answer = nan(left, right) { return (answer, opening) }
        let negative = left.negative != right.negative
        if left.isInfinite {
            if right.isInfinite {
                opening.note(Report.invalid)
                return (indefinite, opening)
            }
            return (infinity(negative), opening)
        }
        if right.isInfinite {
            return (X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0), opening)
        }
        if right.isZero {
            if left.isZero {
                opening.note(Report.invalid)
                return (indefinite, opening)
            }
            opening.note(Report.zeroDivide)
            return (infinity(negative), opening)
        }
        // Un dividende nul rend zéro, mais le diviseur a bien été lu : s'il
        // était dénormal, ça se signale quand même.
        if isDenormalOperand(left) || isDenormalOperand(right) {
            opening.note(Report.denormal)
        }
        if left.isZero {
            return (X86Extended(significand: 0, signExponent: negative ? 0x8000 : 0), opening)
        }
        // **Le quotient sort déjà normalisé, et ce n'est pas un détail.**
        //
        // Le premier jet rendait un quotient dont le bit de tête pouvait être
        // absent, et fabriquait un « bit collant » dans la moitié basse. La
        // normalisation de `assemble` décalait alors les deux vers la gauche —
        // et faisait entrer le bit collant **dans la mantisse**. Toutes les
        // divisions sortaient trop grandes d'une unité du dernier rang, ce que
        // seul un corpus au bit près pouvait montrer.
        //
        // Les deux mantisses ont leur bit de tête posé, donc `numérateur / 2`
        // est toujours plus petit que le dénominateur : la division de cent
        // vingt-huit bits par soixante-quatre ne peut pas déborder.
        let numerator = left.normalized, denominator = right.normalized
        var exponent = numerator.exponent - denominator.exponent + bias
        var (quotient, remainder) = denominator.significand.dividingFullWidth(
            (high: numerator.significand >> 1, low: numerator.significand << 63))
        if quotient & 0x8000_0000_0000_0000 == 0 {
            // Un bit de précision de plus, pris à la main : le quotient double
            // et le reste suit, ce qui vaut un décalage de l'exposant.
            quotient <<= 1
            // **Doubler le reste peut déborder**, et le débordement compte :
            // le reste est plus petit que le diviseur, mais le diviseur a son
            // bit de tête posé, donc le reste peut dépasser 2⁶³. Un simple
            // décalage perdait ce bit en silence, et une division sur deux
            // sortait fausse du dernier rang.
            let (doubled, carry) = remainder.multipliedReportingOverflow(by: 2)
            remainder = doubled
            if carry || remainder >= denominator.significand {
                quotient |= 1
                remainder &-= denominator.significand
            }
            exponent -= 1
        }
        // Le reste dit s'il restait moins, autant, ou plus que la moitié — ce
        // qui suffit à l'arrondi, et se compare sans risque de déborder.
        let half = denominator.significand - remainder
        let rest: UInt64 = remainder == 0 ? 0
            : (remainder > half ? 0xC000_0000_0000_0000
                : (remainder == half ? 0x8000_0000_0000_0000 : 0x4000_0000_0000_0000))
        return merged(assemble(Wide(high: quotient, low: rest), exponent: exponent,
                               negative: negative, rounding: rounding), opening)
    }

    /// Un opérande dénormal se signale, même quand le résultat est exact.
    static func isDenormalOperand(_ value: X86Extended) -> Bool {
        !value.isZero && !value.isSpecial
            && (value.biased == 0 || value.significand & 0x8000_0000_0000_0000 == 0)
    }

    /// Les drapeaux rencontrés à l'entrée s'ajoutent à ceux du calcul.
    static func merged(_ outcome: (X86Extended, Report),
                       _ opening: Report) -> (X86Extended, Report) {
        var report = outcome.1
        report.flags |= opening.flags
        return (outcome.0, report)
    }

    /// La comparaison, avec la quatrième réponse que les entiers n'ont pas :
    /// **non ordonné**, quand l'un des deux est un NaN.
    public enum Order: Sendable { case less, equal, greater, unordered }

    public static func compare(_ left: X86Extended, _ right: X86Extended) -> Order {
        if left.isNaN || right.isNaN { return .unordered }
        if left.isZero, right.isZero { return .equal }
        if left.negative != right.negative { return left.negative ? .less : .greater }
        let bigger: Bool
        if left.biased != right.biased {
            bigger = left.biased > right.biased
        } else if left.significand != right.significand {
            bigger = left.significand > right.significand
        } else {
            return .equal
        }
        return bigger != left.negative ? .greater : .less
    }
}
