import Foundation

// **FMA, F16C, et les conversions qui changent de largeur sur 256 bits.**
//
// Les trois dernières pièces de x86-64-v3 avant que CPUID puisse annoncer AVX
// et AVX2 : la glibc de RHEL 10 exige FMA et F16C avec eux, et les
// conversions entre doubles et simples ou entiers sur un YMM entier
// traversent les moitiés — seize octets d'un côté, trente-deux de l'autre.
//
// **FMA est fusionné** : `a × b + c` arrondi une seule fois, ce que
// `addingProduct` fait — c'est l'instruction de l'hôte, ou sa bibliothèque.
// Les trois ordres (`132`, `213`, `231`) disent quel opérande joue quel rôle ;
// la règle des NaN — le premier NaN des trois, dans l'ordre du calcul, les
// facteurs avant l'addende — est celle que le processeur a montrée : le
// premier jet suivait l'ordre des registres, et `231` le contredisait.
//
// **F16C** convertit entre simples et demi-précision, sur des bits : l'hôte
// n'a pas toujours `Float16`, et l'arrondi de `vcvtps2ph` se choisit dans
// l'immédiat.
//
// Comme pour le reste du flottant de ce cœur, MXCSR n'est ni lu ni écrit :
// l'arrondi est au plus proche, sans exceptions comptées.
//
// La référence est le processeur : `Tests/Fixtures/x86-fma-oracle.tsv`.
extension X86Core {
    /// FMA, F16C, ou une conversion de largeur sur 256 bits ; `false` sinon.
    mutating func extendedFloatInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws -> Bool {
        guard instruction.modrm != nil else { return false }
        let wide = instruction.vexLength == 1
        let prefix = instruction.vexImpliedPrefix
        switch (instruction.map, opcode) {
        case (.threeByte38, 0x96...0x9F) where prefix == 1, (.threeByte38, 0xA6...0xAF) where prefix == 1,
             (.threeByte38, 0xB6...0xBF) where prefix == 1:
            try fusedMultiplyAdd(instruction, opcode)
        case (.threeByte38, 0x13) where prefix == 1 && instruction.wideOperandSize != 8:
            try halfToSingle(instruction)
        case (.threeByte3A, 0x1D) where prefix == 1 && instruction.wideOperandSize != 8:
            try singleToHalf(instruction)
        case (.twoByte, 0x5A) where wide && prefix <= 1, (.twoByte, 0xE6) where wide && prefix != 0:
            try wideConversion(instruction, opcode, prefix)
        default:
            return false
        }
        return true
    }

    // MARK: - FMA

    private mutating func fusedMultiplyAdd(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        let doubles = instruction.wideOperandSize == 8
        let scalar = opcode & 1 == 1 && opcode & 0x0F >= 0x09
        guard !(scalar && instruction.vexLength == 1) else { throw Self.vectorRefusal() }
        let bits = doubles ? 64 : 32
        let wordCount = instruction.vexLength == 0 ? 2 : 4
        let fields = try decodeFields(instruction)
        let reg = ymmWords(fields.reg)
        let vvvv = ymmWords(instruction.vexRegister)
        var rm: [UInt64]
        if fields.mod == 0b11 {
            rm = ymmWords(fields.rm)
        } else {
            rm = [UInt64](repeating: 0, count: 4)
            let bytes = scalar ? bits / 8 : 8 * wordCount
            if bytes == 4 {
                rm[0] = try readMemory(lastAddress, 4)
            } else {
                for index in 0..<bytes / 8 { rm[index] = try readMemory(lastAddress &+ UInt64(8 * index), 8) }
            }
        }
        // Qui multiplie quoi : `132` dest × r/m + vvvv, `213` vvvv × dest + r/m,
        // `231` vvvv × r/m + dest.
        let (a, b, c): ([UInt64], [UInt64], [UInt64])
        switch opcode >> 4 {
        case 0x9: (a, b, c) = (reg, rm, vvvv)
        case 0xA: (a, b, c) = (vvvv, reg, rm)
        default: (a, b, c) = (vvvv, rm, reg)
        }
        let kind = opcode & 0x0F
        var words = Array(reg.prefix(wordCount))
        let count = scalar ? 1 : 64 * wordCount / bits
        for index in 0..<count {
            // Le signe du produit et celui de l'addende, élément par élément :
            // `fmaddsub` soustrait aux pairs, `fmsubadd` aux impairs.
            let even = index % 2 == 0
            let negateProduct = kind >= 0x0C
            let negateAddend: Bool
            switch kind {
            case 0x6: negateAddend = even
            case 0x7: negateAddend = !even
            case 0xA, 0xB, 0xE, 0xF: negateAddend = true
            default: negateAddend = false
            }
            let x = Self.element(a, index, bits)
            let y = Self.element(b, index, bits)
            let z = Self.element(c, index, bits)
            let result = doubles
                ? Self.fused(x, y, z, negateProduct, negateAddend)
                : Self.fusedSingle(x, y, z, negateProduct, negateAddend)
            Self.setElement(&words, index, bits, result)
        }
        setYMMWords(fields.reg, words)
    }

    /// `±(x × y) ± z`, un seul arrondi. L'ordre des NaN est celui du calcul —
    /// les deux facteurs, puis l'addende —, quel que soit le registre qui
    /// les porte.
    static func fused(_ x: UInt64, _ y: UInt64, _ z: UInt64, _ negateProduct: Bool, _ negateAddend: Bool) -> UInt64 {
        if let nan = [x, y, z].map(asDouble).first(where: \.isNaN) { return quiet(nan).bitPattern }
        let a = Double(bitPattern: x), b = Double(bitPattern: y), c = Double(bitPattern: z)
        let result = (negateAddend ? -c : c).addingProduct(negateProduct ? -a : a, b)
        return (result.isNaN ? indefiniteDouble : result).bitPattern
    }

    static func fusedSingle(_ x: UInt64, _ y: UInt64, _ z: UInt64, _ negateProduct: Bool,
                            _ negateAddend: Bool) -> UInt64 {
        if let nan = [x, y, z].map(asSingle).first(where: \.isNaN) { return UInt64(quiet(nan).bitPattern) }
        let a = asSingle(x), b = asSingle(y), c = asSingle(z)
        let result = (negateAddend ? -c : c).addingProduct(negateProduct ? -a : a, b)
        return UInt64((result.isNaN ? indefiniteSingle : result).bitPattern)
    }

    // MARK: - F16C

    /// `vcvtph2ps` : quatre ou huit demi-précisions en simples, exactement.
    private mutating func halfToSingle(_ instruction: X86Instruction) throws {
        guard instruction.vexRegister == 0 else { throw Self.vectorRefusal() }
        let wide = instruction.vexLength == 1
        let fields = try decodeFields(instruction)
        var source = [UInt64](repeating: 0, count: 2)
        if fields.mod == 0b11 {
            source = Array(ymmWords(fields.rm).prefix(2))
        } else {
            source[0] = try readMemory(lastAddress, 8)
            if wide { source[1] = try readMemory(lastAddress &+ 8, 8) }
        }
        var words = [UInt64](repeating: 0, count: wide ? 4 : 2)
        for index in 0..<(wide ? 8 : 4) {
            let half = UInt16(truncatingIfNeeded: Self.element(source, index, 16))
            Self.setElement(&words, index, 32, UInt64(Self.single(fromHalf: half)))
        }
        setYMMWords(fields.reg, words)
    }

    /// `vcvtps2ph` : quatre ou huit simples en demi-précision, arrondies
    /// selon l'immédiat — ou au plus proche quand il renvoie à MXCSR.
    private mutating func singleToHalf(_ instruction: X86Instruction) throws {
        guard instruction.vexRegister == 0 else { throw Self.vectorRefusal() }
        let wide = instruction.vexLength == 1
        let fields = try decodeFields(instruction)
        let source = ymmWords(fields.reg)
        let control = Int(instruction.immediate)
        let rounding = control & 4 != 0 ? 0 : control & 3
        var words: [UInt64] = [0, 0]
        for index in 0..<(wide ? 8 : 4) {
            let single = UInt32(truncatingIfNeeded: Self.element(source, index, 32))
            Self.setElement(&words, index, 16, UInt64(Self.half(fromSingle: single, rounding: rounding)))
        }
        if fields.mod == 0b11 {
            setYMMWords(fields.rm, words)
        } else {
            try writeMemory(lastAddress, 8, words[0])
            if wide { try writeMemory(lastAddress &+ 8, 8, words[1]) }
        }
    }

    /// Une demi-précision en simple : exacte, les sous-normales normalisées,
    /// un NaN rendu silencieux, sa charge gardée.
    static func single(fromHalf half: UInt16) -> UInt32 {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = Int(half >> 10 & 0x1F)
        var fraction = UInt32(half & 0x3FF)
        if exponent == 0x1F {
            return sign | 0x7F80_0000 | fraction << 13 | (fraction != 0 ? 0x0040_0000 : 0)
        }
        if exponent == 0 {
            guard fraction != 0 else { return sign }
            var shift = 0
            while fraction & 0x400 == 0 { fraction <<= 1; shift += 1 }
            return sign | UInt32(127 - 15 - shift + 1) << 23 | (fraction & 0x3FF) << 13
        }
        return sign | UInt32(exponent - 15 + 127) << 23 | fraction << 13
    }

    /// Une simple en demi-précision, arrondie : 0 au plus proche (pair), 1
    /// vers moins l'infini, 2 vers plus l'infini, 3 vers zéro.
    static func half(fromSingle single: UInt32, rounding: Int) -> UInt16 {
        let sign = UInt16(single >> 16 & 0x8000)
        let exponent = Int(single >> 23 & 0xFF)
        let fraction = single & 0x7F_FFFF
        if exponent == 0xFF {
            // Un NaN garde le haut de sa charge, rendu silencieux.
            return fraction == 0 ? sign | 0x7C00 : sign | 0x7E00 | UInt16(fraction >> 13)
        }
        let negative = sign != 0
        // La valeur en unités de 2⁻²⁴ (la plus petite sous-normale), comme un
        // entier exact augmenté de bits de garde : 2⁻²⁴ × mantisse × 2^décalage.
        let significand = UInt64(exponent == 0 ? fraction : fraction | 0x80_0000)
        // simple = significand × 2^(e − 150) ; en unités de 2⁻²⁴ : × 2^(e − 126).
        let shift = (exponent == 0 ? 1 : exponent) - 126
        var units: UInt64
        var inexact: Bool
        var halfway = false
        var aboveHalf = false
        if shift >= 0 {
            guard shift < 40 else { return overflow(sign, negative, rounding) }
            units = significand << UInt64(shift)
            inexact = false
        } else if -shift >= 64 {
            units = 0
            inexact = significand != 0
            aboveHalf = false
        } else {
            let dropped = significand & ((1 << UInt64(-shift)) - 1)
            units = significand >> UInt64(-shift)
            inexact = dropped != 0
            let half = UInt64(1) << UInt64(-shift - 1)
            halfway = dropped == half
            aboveHalf = dropped > half
        }
        // Les unités d'un nombre normal de demi-précision ne sont pas toutes
        // représentables : au-delà de 2¹¹ unités, la mantisse n'a que onze
        // bits. On ramène donc à la précision de l'exposant atteint.
        var step: UInt64 = 1
        while units >= step << 11 { step <<= 1 }
        if step > 1 {
            let dropped = units & (step - 1)
            let halfStep = step >> 1
            let wasInexact = inexact
            halfway = dropped == halfStep && !wasInexact
            aboveHalf = dropped > halfStep || (dropped == halfStep && wasInexact)
            inexact = dropped != 0 || wasInexact
            units -= dropped
        }
        if inexact {
            let roundUp: Bool
            switch rounding {
            case 0: roundUp = aboveHalf || (halfway && (units / step) & 1 == 1)
            case 1: roundUp = negative
            case 2: roundUp = !negative
            default: roundUp = false
            }
            if roundUp { units += step }
        }
        // Le plus grand fini, 65 504, vaut 2047 × 2⁵ : en unités de 2⁻²⁴,
        // 2047 × 2²⁹. Le premier jet comptait 2⁵ en unités de 2⁻¹⁴ et
        // débordait dès 2 — le corpus l'a vu sur chaque nombre normal.
        if units > 0x7FF << 29 { return overflow(sign, negative, rounding) }
        if units < 0x400 { return sign | UInt16(units) }
        // Normal : exposant e tel que units = (1.f) × 2^(e − 1) × 2¹⁰.
        var exponentOut = 1
        var value = units
        while value >= 0x800 { value >>= 1; exponentOut += 1 }
        return sign | UInt16(exponentOut) << 10 | UInt16(value & 0x3FF)
    }

    /// Ce que rend un dépassement : l'infini, ou le plus grand fini quand
    /// l'arrondi s'éloigne de l'infini de ce signe.
    private static func overflow(_ sign: UInt16, _ negative: Bool, _ rounding: Int) -> UInt16 {
        let toInfinity = rounding == 0 || (rounding == 1 && negative) || (rounding == 2 && !negative)
        return sign | (toInfinity ? 0x7C00 : 0x7BFF)
    }

    // MARK: - Les conversions de largeur sur 256 bits

    private mutating func wideConversion(_ instruction: X86Instruction, _ opcode: UInt8, _ prefix: Int) throws {
        guard instruction.vexRegister == 0 else { throw Self.vectorRefusal() }
        let fields = try decodeFields(instruction)
        // Ce qui s'élargit lit seize octets ; ce qui se rétrécit, trente-deux.
        let widening = (opcode == 0x5A && prefix == 0) || (opcode == 0xE6 && prefix == 2)
        var source = [UInt64](repeating: 0, count: 4)
        if fields.mod == 0b11 {
            source = ymmWords(fields.rm)
        } else {
            for index in 0..<(widening ? 2 : 4) { source[index] = try readMemory(lastAddress &+ UInt64(8 * index), 8) }
        }
        var words = [UInt64](repeating: 0, count: widening ? 4 : 2)
        for index in 0..<4 {
            let result: UInt64
            switch (opcode, prefix) {
            case (0x5A, 0):  // vcvtps2pd
                result = Self.widened(Float(bitPattern: UInt32(truncatingIfNeeded: Self.element(source, index, 32))))
                    .bitPattern
            case (0xE6, 2):  // vcvtdq2pd
                result = Double(Int32(truncatingIfNeeded: Self.element(source, index, 32))).bitPattern
            case (0x5A, _):  // vcvtpd2ps
                result = UInt64(Self.narrowed(Self.asDouble(source[index])).bitPattern)
            case (0xE6, 1):  // vcvttpd2dq
                result = Self.toInteger(Self.asDouble(source[index]).rounded(.towardZero), 4)
            default:  // vcvtpd2dq
                result = Self.toInteger(Self.asDouble(source[index]).rounded(.toNearestOrEven), 4)
            }
            Self.setElement(&words, index, widening ? 64 : 32, result)
        }
        setYMMWords(fields.reg, words)
    }
}
