import Foundation

// Ce que chaque instruction fait. Séparé de `X86Core` parce que le fichier
// serait autrement une seule fonction de mille lignes ; la structure, les
// registres et les drapeaux sont à côté.
extension X86Core {
    // MARK: - L'arithmétique, et surtout ses drapeaux

    /// Une addition, avec sa retenue entrante, et les six drapeaux.
    ///
    /// `AF` est calculée comme une retenue sortant du bit 3, ce qui se lit
    /// directement dans `a ^ b ^ résultat` : c'est le seul endroit du
    /// processeur où ce bit compte, et il est posé même en mode 64 bits où
    /// l'arithmétique décimale n'existe plus.
    mutating func add(_ a: UInt64, _ b: UInt64, _ size: Int, carryIn: UInt64 = 0) -> UInt64 {
        let bits = UInt64(8 * size)
        let mask = Self.mask(size)
        let sign = Self.signBit(size)
        let wide: UInt64
        let carryOut: Bool
        if size == 8 {
            let (first, overflow1) = a.addingReportingOverflow(b)
            let (second, overflow2) = first.addingReportingOverflow(carryIn)
            wide = second
            carryOut = overflow1 || overflow2
        } else {
            let sum = (a & mask) &+ (b & mask) &+ carryIn
            wide = sum
            carryOut = sum >> bits != 0
        }
        let result = wide & mask
        set(Flag.carry, carryOut)
        set(Flag.auxiliary, ((a ^ b ^ result) >> 4) & 1 != 0)
        set(Flag.overflow, ((a ^ result) & (b ^ result) & sign) != 0)
        setResultFlags(result, size)
        return result
    }

    /// Une soustraction. `CMP` est la même chose sans écrire le résultat, et
    /// c'est bien la même fonction qui sert : deux implémentations
    /// divergeraient un jour.
    mutating func subtract(_ a: UInt64, _ b: UInt64, _ size: Int, borrowIn: UInt64 = 0) -> UInt64 {
        let mask = Self.mask(size)
        let sign = Self.signBit(size)
        let result = ((a & mask) &- (b & mask) &- borrowIn) & mask
        let borrowOut: Bool
        if borrowIn != 0 {
            borrowOut = (a & mask) < (b & mask) || ((a & mask) == (b & mask) && borrowIn != 0)
                || (a & mask) &- (b & mask) < borrowIn
        } else {
            borrowOut = (a & mask) < (b & mask)
        }
        set(Flag.carry, borrowOut)
        set(Flag.auxiliary, ((a ^ b ^ result) >> 4) & 1 != 0)
        set(Flag.overflow, ((a ^ b) & (a ^ result) & sign) != 0)
        setResultFlags(result, size)
        return result
    }

    /// ET, OU, OU exclusif : la retenue et le débordement tombent, et `AF` est
    /// **effacée**. Le manuel la dit indéfinie ; le processeur la met à zéro,
    /// et c'est ce que l'oracle a répondu.
    mutating func logic(_ result: UInt64, _ size: Int) -> UInt64 {
        let value = result & Self.mask(size)
        set(Flag.carry, false)
        set(Flag.overflow, false)
        set(Flag.auxiliary, false)
        setResultFlags(value, size)
        return value
    }

    /// Les huit opérations que les octets 0x00 à 0x3D portent, dans l'ordre.
    mutating func arithmetic(_ index: Int, _ a: UInt64, _ b: UInt64, _ size: Int) -> UInt64? {
        switch index {
        case 0: return add(a, b, size)
        case 1: return logic(a | b, size)
        case 2: return add(a, b, size, carryIn: carry ? 1 : 0)
        case 3: return subtract(a, b, size, borrowIn: carry ? 1 : 0)
        case 4: return logic(a & b, size)
        case 5: return subtract(a, b, size)
        case 6: return logic(a ^ b, size)
        // CMP calcule et jette : seuls les drapeaux restent.
        default: _ = subtract(a, b, size); return nil
        }
    }

    // MARK: - Les opérandes

    /// La valeur de `r/m` quand `mod` vaut 11 — un registre. Toute autre forme
    /// désigne la mémoire, que ce cœur ne sait pas encore lire.
    func readRM(_ fields: Fields, _ size: Int) throws -> UInt64 {
        guard fields.mod == 0b11 else { throw Fault.unsupported("un opérande en mémoire") }
        return read(fields.rm, size, highByte: fields.rmIsHighByte)
    }

    mutating func writeRM(_ fields: Fields, _ size: Int, _ value: UInt64) throws {
        guard fields.mod == 0b11 else { throw Fault.unsupported("un opérande en mémoire") }
        write(fields.rm, size, highByte: fields.rmIsHighByte, value)
    }

    func readReg(_ fields: Fields, _ size: Int) -> UInt64 {
        read(fields.reg, size, highByte: fields.regIsHighByte)
    }

    mutating func writeReg(_ fields: Fields, _ size: Int, _ value: UInt64) {
        write(fields.reg, size, highByte: fields.regIsHighByte, value)
    }

    /// L'immédiat d'une instruction, étendu au signe à la largeur de
    /// l'opérande. Un immédiat de quatre octets sur une opération de huit est
    /// **étendu au signe**, pas complété de zéros — c'est pour ça que
    /// `addq $-1, %rax` fonctionne.
    static func immediate(_ instruction: X86Instruction, _ size: Int) -> UInt64 {
        let raw = instruction.immediate
        switch instruction.immediateBytes {
        case 1: return signExtend(raw & 0xFF, 1) & mask(size)
        case 2: return signExtend(raw & 0xFFFF, 2) & mask(size)
        case 4: return signExtend(raw & 0xFFFF_FFFF, 4) & mask(size)
        default: return raw & mask(size)
        }
    }

    // MARK: - Les conditions

    /// Les seize conditions, dans l'ordre du champ `tttn`. Ce sont les mêmes
    /// pour Jcc, SETcc et CMOVcc : une seule table, donc un seul endroit où se
    /// tromper.
    public func condition(_ code: UInt8) -> Bool {
        let overflow = flags & Flag.overflow != 0
        let carryFlag = flags & Flag.carry != 0
        let zero = flags & Flag.zero != 0
        let sign = flags & Flag.sign != 0
        let parity = flags & Flag.parity != 0
        switch code & 0x0F {
        case 0x0: return overflow
        case 0x1: return !overflow
        case 0x2: return carryFlag
        case 0x3: return !carryFlag
        case 0x4: return zero
        case 0x5: return !zero
        case 0x6: return carryFlag || zero
        case 0x7: return !carryFlag && !zero
        case 0x8: return sign
        case 0x9: return !sign
        case 0xA: return parity
        case 0xB: return !parity
        case 0xC: return sign != overflow
        case 0xD: return sign == overflow
        case 0xE: return zero || sign != overflow
        default: return !zero && sign == overflow
        }
    }

    // MARK: - Décalages et rotations

    /// Le compte est masqué à cinq bits, six pour une opération de huit
    /// octets. Un compte nul ne touche **à rien**, pas même aux drapeaux : la
    /// règle qu'on oublie, et qui se voit tout de suite sur l'oracle.
    static func shiftCount(_ raw: UInt64, _ size: Int) -> UInt64 {
        raw & (size == 8 ? 63 : 31)
    }

    mutating func shift(_ kind: Int, _ value: UInt64, _ rawCount: UInt64, _ size: Int) -> UInt64 {
        let count = Self.shiftCount(rawCount, size)
        guard count != 0 else { return value & Self.mask(size) }
        let bits = UInt64(8 * size)
        let mask = Self.mask(size)
        let sign = Self.signBit(size)
        let source = value & mask

        switch kind {
        case 4, 6:  // SHL, et son alias non documenté SAL
            let result = count >= bits ? 0 : (source << count) & mask
            let lastOut = count > bits ? 0 : (count == bits ? source & 1 : (source >> (bits - count)) & 1)
            set(Flag.carry, lastOut != 0)
            if count == 1 { set(Flag.overflow, ((result & sign) != 0) != (lastOut != 0)) }
            setResultFlags(result, size)
            return result
        case 5:  // SHR
            let result = count >= bits ? 0 : source >> count
            let lastOut = count > bits ? 0 : (source >> (count - 1)) & 1
            set(Flag.carry, lastOut != 0)
            if count == 1 { set(Flag.overflow, source & sign != 0) }
            setResultFlags(result, size)
            return result
        default:  // SAR
            let extended = Self.signExtend(source, size)
            let amount = min(count, bits - 1)
            let result = UInt64(bitPattern: Int64(bitPattern: extended) >> Int64(amount)) & mask
            let lastOut = UInt64(bitPattern: Int64(bitPattern: extended) >> Int64(min(count - 1, bits - 1))) & 1
            set(Flag.carry, lastOut != 0)
            if count == 1 { set(Flag.overflow, false) }
            setResultFlags(result, size)
            return result
        }
    }

    mutating func rotate(_ kind: Int, _ value: UInt64, _ rawCount: UInt64, _ size: Int) -> UInt64 {
        let bits = UInt64(8 * size)
        let mask = Self.mask(size)
        let sign = Self.signBit(size)
        let masked = Self.shiftCount(rawCount, size)
        let source = value & mask

        switch kind {
        case 0, 1:  // ROL, ROR — le compte se réduit encore modulo la largeur.
            let count = masked % bits
            if masked == 0 { return source }
            let result: UInt64
            if count == 0 {
                result = source
            } else if kind == 0 {
                result = ((source << count) | (source >> (bits - count))) & mask
            } else {
                result = ((source >> count) | (source << (bits - count))) & mask
            }
            // La retenue prend le bit qui a fait le tour.
            set(Flag.carry, kind == 0 ? (result & 1 != 0) : (result & sign != 0))
            if masked == 1 {
                set(Flag.overflow, kind == 0
                    ? ((result & sign != 0) != (result & 1 != 0))
                    : ((result & sign != 0) != (result & (sign >> 1) != 0)))
            }
            return result
        default:  // RCL, RCR — la retenue fait partie du tour, d'où le +1.
            let count = masked % (bits + 1)
            if count == 0 { return source }
            var result = source
            var carryBit: UInt64 = carry ? 1 : 0
            for _ in 0..<count {
                if kind == 2 {
                    let out = (result & sign) != 0 ? UInt64(1) : 0
                    result = ((result << 1) | carryBit) & mask
                    carryBit = out
                } else {
                    let out = result & 1
                    result = ((result >> 1) | (carryBit << (bits - 1))) & mask
                    carryBit = out
                }
            }
            set(Flag.carry, carryBit != 0)
            if masked == 1 {
                set(Flag.overflow, kind == 2
                    ? ((result & sign != 0) != (carryBit != 0))
                    : ((result & sign != 0) != (result & (sign >> 1) != 0)))
            }
            return result
        }
    }

    // MARK: - Multiplication

    /// MUL : le produit ne tient pas dans un registre, donc il en occupe deux —
    /// AX pour une opération d'un octet, DX:AX au-delà.
    mutating func multiplyUnsigned(_ operand: UInt64, _ size: Int) {
        let mask = Self.mask(size)
        let a = read(0, size, highByte: false)
        let (high, low) = Self.wideMultiply(a, operand, size)
        if size == 1 {
            write(0, 2, highByte: false, (high << 8) | low)
        } else {
            write(0, size, highByte: false, low)
            write(2, size, highByte: false, high)
        }
        let upperUsed = high & mask != 0
        set(Flag.carry, upperUsed)
        set(Flag.overflow, upperUsed)
        // Les quatre autres sont indéfinis ; le processeur les pose depuis le
        // résultat bas, et c'est ce que l'oracle a figé.
        setResultFlags(low, size)
        set(Flag.auxiliary, false)
    }

    static func wideMultiply(_ a: UInt64, _ b: UInt64, _ size: Int) -> (UInt64, UInt64) {
        if size == 8 {
            let product = a.multipliedFullWidth(by: b)
            return (product.high, product.low)
        }
        let product = (a & mask(size)) &* (b & mask(size))
        return ((product >> UInt64(8 * size)) & mask(size), product & mask(size))
    }
}

// Multiplication signée, division, et les décalages à double précision : les
// quatre opérations dont les drapeaux ne ressemblent à aucune autre.
extension X86Core {
    /// IMUL à un opérande : le produit signé occupe deux registres.
    ///
    /// La retenue et le débordement disent la même chose et une seule : « la
    /// moitié haute n'est pas seulement le signe de la moitié basse », donc
    /// « le résultat ne tenait pas ».
    mutating func multiplySigned(_ operand: UInt64, _ size: Int) {
        let a = Self.signExtend(read(0, size, highByte: false), size)
        let b = Self.signExtend(operand, size)
        let (high, low) = Self.wideMultiplySigned(a, b, size)
        if size == 1 {
            write(0, 2, highByte: false, ((high & 0xFF) << 8) | (low & 0xFF))
        } else {
            write(0, size, highByte: false, low)
            write(2, size, highByte: false, high)
        }
        let fits = high & Self.mask(size) == (Self.signExtend(low, size) >> UInt64(8 * size - 1)
            & 1 == 1 ? Self.mask(size) : 0)
        set(Flag.carry, !fits)
        set(Flag.overflow, !fits)
        setResultFlags(low, size)
        set(Flag.auxiliary, false)
    }

    /// IMUL à deux ou trois opérandes : seule la moitié basse est gardée, et
    /// les drapeaux disent si c'était une perte.
    mutating func multiplyTruncating(_ a: UInt64, _ b: UInt64, _ size: Int) -> UInt64 {
        let (high, low) = Self.wideMultiplySigned(
            Self.signExtend(a, size), Self.signExtend(b, size), size)
        let expected = (low & Self.signBit(size)) != 0 ? Self.mask(size) : 0
        let fits = high & Self.mask(size) == expected
        set(Flag.carry, !fits)
        set(Flag.overflow, !fits)
        setResultFlags(low, size)
        set(Flag.auxiliary, false)
        return low
    }

    static func wideMultiplySigned(_ a: UInt64, _ b: UInt64, _ size: Int) -> (UInt64, UInt64) {
        if size == 8 {
            let product = Int64(bitPattern: a).multipliedFullWidth(by: Int64(bitPattern: b))
            return (UInt64(bitPattern: Int64(product.high)), product.low)
        }
        let product = UInt64(bitPattern: Int64(bitPattern: a) &* Int64(bitPattern: b))
        return ((product >> UInt64(8 * size)) & mask(size), product & mask(size))
    }

    /// DIV : le dividende occupe deux registres, et le quotient un seul. Quand
    /// il n'y tient pas, le processeur lève une exception plutôt que de rendre
    /// un nombre faux — c'est la seule instruction arithmétique qui refuse.
    mutating func divideUnsigned(_ divisor: UInt64, _ size: Int) throws {
        guard divisor & Self.mask(size) != 0 else { throw Fault.divideError }
        let mask = Self.mask(size)
        let low = read(0, size, highByte: false)
        let high = size == 1 ? (read(0, 2, highByte: false) >> 8) : read(2, size, highByte: false)
        if size == 8 {
            guard high < divisor else { throw Fault.divideError }
            let (quotient, remainder) = divisor.dividingFullWidth((high: high, low: low))
            registers[0] = quotient
            registers[2] = remainder
            return
        }
        let dividend = (high & mask) << UInt64(8 * size) | (low & mask)
        let quotient = dividend / (divisor & mask)
        guard quotient <= mask else { throw Fault.divideError }
        let remainder = dividend % (divisor & mask)
        if size == 1 {
            write(0, 2, highByte: false, ((remainder & 0xFF) << 8) | (quotient & 0xFF))
        } else {
            write(0, size, highByte: false, quotient)
            write(2, size, highByte: false, remainder)
        }
    }

    /// IDIV : la même chose en signé. Le reste porte le signe du **dividende**,
    /// pas celui du diviseur — c'est ce que fait la division tronquée, et c'est
    /// aussi ce que fait Swift.
    mutating func divideSigned(_ divisor: UInt64, _ size: Int) throws {
        guard divisor & Self.mask(size) != 0 else { throw Fault.divideError }
        let mask = Self.mask(size)
        let low = read(0, size, highByte: false)
        let high = size == 1 ? (read(0, 2, highByte: false) >> 8) : read(2, size, highByte: false)
        let divisorValue = Int64(bitPattern: Self.signExtend(divisor, size))
        let dividend: Int64
        if size == 8 {
            // Un dividende de 128 bits ne rentre pas dans un Int64 : seule la
            // moitié qui est le signe de l'autre est acceptée ici, le reste
            // débordera de toute façon.
            let expected = (low & Self.signBit(8)) != 0 ? UInt64.max : 0
            guard high == expected else { throw Fault.divideError }
            dividend = Int64(bitPattern: low)
        } else {
            let combined = (high & mask) << UInt64(8 * size) | (low & mask)
            dividend = Int64(bitPattern: Self.signExtend(combined, 2 * size))
        }
        guard !(dividend == Int64.min && divisorValue == -1) else { throw Fault.divideError }
        let quotient = dividend / divisorValue
        let remainder = dividend % divisorValue
        // La borne ne se pose qu'en dessous de huit octets : à huit, le quotient
        // est un Int64 et tient forcément, et écrire la borne quand même la
        // ferait déborder — `-Int64.min` n'existe pas.
        if size < 8 {
            let limit = Int64(1) << Int64(8 * size - 1)
            guard quotient >= -limit && quotient <= limit - 1 else { throw Fault.divideError }
        }
        if size == 1 {
            write(0, 2, highByte: false,
                  ((UInt64(bitPattern: remainder) & 0xFF) << 8)
                      | (UInt64(bitPattern: quotient) & 0xFF))
        } else {
            write(0, size, highByte: false, UInt64(bitPattern: quotient) & mask)
            write(2, size, highByte: false, UInt64(bitPattern: remainder) & mask)
        }
    }

    /// SHLD et SHRD : les bits qui entrent viennent d'un autre registre plutôt
    /// que de zéro ou du signe.
    ///
    /// Rend `nil` quand il n'y a **rien à changer** : un compte nul, ou un
    /// compte plus grand que la largeur, que le manuel laisse indéfini. Les
    /// drapeaux ne bougent alors pas — mais l'appelant écrit quand même la
    /// valeur d'origine, parce qu'une écriture de 32 bits met à zéro le haut du
    /// registre et que le processeur le fait aussi.
    mutating func doubleShift(
        left: Bool, _ destination: UInt64, _ source: UInt64, _ rawCount: UInt64, _ size: Int
    ) -> UInt64? {
        let count = Self.shiftCount(rawCount, size)
        guard count != 0 else { return nil }
        let bits = UInt64(8 * size)
        guard count < bits else { return nil }
        let mask = Self.mask(size)
        let sign = Self.signBit(size)
        let value = destination & mask
        let other = source & mask
        let result: UInt64
        let lastOut: UInt64
        if left {
            result = ((value << count) | (other >> (bits - count))) & mask
            lastOut = (value >> (bits - count)) & 1
        } else {
            result = ((value >> count) | (other << (bits - count))) & mask
            lastOut = (value >> (count - 1)) & 1
        }
        set(Flag.carry, lastOut != 0)
        if count == 1 { set(Flag.overflow, ((value ^ result) & sign) != 0) }
        setResultFlags(result, size)
        return result
    }
}
