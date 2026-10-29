import Foundation

// **SSE4.1, l'entier.** La deuxième tranche de x86-64-v2 (voir
// `X86SSSE3.swift` pour la raison et le comptage) : ce que les binaires
// d'AlmaLinux 9.8 emploient de SSE4.1 hors arrondi — `pinsrq` (9 490 fois),
// `pinsrd` (1 582), `pmaxsd` (493), `pminud` (450), `pextrq` (371),
// `pblendvb` (344), `pmaxud` (300), `pblendw` (261), `pminsd` (236), les
// élargissements `pmovzx*` et `pmovsx*`, `packusdw` (187), `ptest` (93),
// `pcmpeqq` (78), les mélanges `blendvp*`, `pmulld`, `insertps`, `pmuldq`,
// `pmaxsb`, `extractps`. `pminuw`, `pmaxuw` et `pminsb` les accompagnent :
// ce sont les mêmes à la largeur ou au signe près.
//
// `roundss`, `roundsd`, `roundps` et `roundpd` attendent la tranche de la
// virgule flottante : arrondir demande le mode de MXCSR, que rien ici ne lit.
extension X86Core {
    /// Les opérations de `0F 38` faites d'une destination et d'une source.
    /// `mask` est xmm0, que les mélanges lisent sans le nommer. `nil` : pas
    /// une instruction de SSE4.1.
    static func sse41(
        _ opcode: UInt8, _ destination: (low: UInt64, high: UInt64),
        _ source: (low: UInt64, high: UInt64), mask: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64)? {
        func signed(_ width: Int, _ value: UInt64) -> Int64 {
            let bits = UInt64(width * 8)
            return Int64(bitPattern: value << (64 - bits)) >> Int64(64 - bits)
        }
        func choose(_ width: Int, smaller: Bool, signed isSigned: Bool) -> (UInt64, UInt64) {
            elementwise(width, destination, source) { left, right, _ in
                let less = isSigned ? signed(width, left) < signed(width, right) : left < right
                return less == smaller ? left : right
            }
        }
        switch opcode {
        case 0x38: return choose(1, smaller: true, signed: true)    // PMINSB
        case 0x3C: return choose(1, smaller: false, signed: true)   // PMAXSB
        case 0x3A: return choose(2, smaller: true, signed: false)   // PMINUW
        case 0x3E: return choose(2, smaller: false, signed: false)  // PMAXUW
        case 0x39: return choose(4, smaller: true, signed: true)    // PMINSD
        case 0x3D: return choose(4, smaller: false, signed: true)   // PMAXSD
        case 0x3B: return choose(4, smaller: true, signed: false)   // PMINUD
        case 0x3F: return choose(4, smaller: false, signed: false)  // PMAXUD
        case 0x37:  // PCMPGTQ, signé (SSE4.2)
            return elementwise(8, destination, source) {
                Int64(bitPattern: $0) > Int64(bitPattern: $1) ? $2 : 0
            }
        case 0x29:  // PCMPEQQ
            return elementwise(8, destination, source) { $0 == $1 ? $2 : 0 }
        case 0x40:  // PMULLD : les trente-deux bits bas de chaque produit
            return elementwise(4, destination, source) { ($0 &* $1) & $2 }
        case 0x28:  // PMULDQ : les mots pairs, signés, en produits de 64 bits
            func product(_ left: UInt64, _ right: UInt64) -> UInt64 {
                UInt64(bitPattern: signed(4, left & 0xFFFF_FFFF) &* signed(4, right & 0xFFFF_FFFF))
            }
            return (product(destination.low, source.low), product(destination.high, source.high))
        case 0x2B:  // PACKUSDW : mots doubles signés en mots sans signe, saturés
            func narrow(_ half: UInt64) -> [UInt16] {
                [half & 0xFFFF_FFFF, half >> 32].map {
                    UInt16(min(max(signed(4, $0), 0), 0xFFFF))
                }
            }
            let words = narrow(destination.low) + narrow(destination.high)
                + narrow(source.low) + narrow(source.high)
            return packWords(words.map { Int32($0) })
        // Les mélanges par xmm0 : un élément vient de la source quand le bit
        // de signe de l'élément correspondant de xmm0 est levé.
        case 0x10: return blend(1, destination, source, by: mask)  // PBLENDVB
        case 0x14: return blend(4, destination, source, by: mask)  // BLENDVPS
        case 0x15: return blend(8, destination, source, by: mask)  // BLENDVPD
        default: return nil
        }
    }

    static func blend(
        _ width: Int, _ destination: (low: UInt64, high: UInt64),
        _ source: (low: UInt64, high: UInt64), by mask: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let bits = UInt64(width * 8)
        func half(_ left: UInt64, _ right: UInt64, _ selector: UInt64) -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                let element = bits == 64 ? UInt64.max : ((1 << bits) - 1) << shift
                let chosen = selector >> (shift + bits - 1) & 1 != 0 ? right : left
                result |= chosen & element
                shift += bits
            }
            return result
        }
        return (half(destination.low, source.low, mask.low), half(destination.high, source.high, mask.high))
    }

    /// **`PTEST`** : rien n'est écrit que des drapeaux. ZF quand la
    /// conjonction est nulle, CF quand la source privée de la destination
    /// l'est ; OF, AF, PF et SF à zéro.
    mutating func testBits(_ fields: Fields) throws {
        let destination = vector(fields.reg)
        let source = try readVectorRM(fields, 16)
        let zero = destination.low & source.0 == 0 && destination.high & source.1 == 0
        let carry = ~destination.low & source.0 == 0 && ~destination.high & source.1 == 0
        flags &= ~Flag.arithmetic
        if zero { flags |= Flag.zero }
        if carry { flags |= Flag.carry }
    }

    /// Un élargissement : la largeur de départ, celle d'arrivée, le signe.
    struct Widening {
        let from: Int
        let to: Int
        let signed: Bool
    }

    /// `66 0F 38 20…25` avec signe, `30…35` sans : de l'octet au mot, au mot
    /// double, au mot quadruple ; du mot au mot double et au quadruple ; du
    /// mot double au quadruple.
    static func widening(_ opcode: UInt8) -> Widening? {
        let shapes = [(1, 2), (1, 4), (1, 8), (2, 4), (2, 8), (4, 8)]
        switch opcode {
        case 0x20...0x25: return Widening(from: shapes[Int(opcode - 0x20)].0, to: shapes[Int(opcode - 0x20)].1, signed: true)
        case 0x30...0x35: return Widening(from: shapes[Int(opcode - 0x30)].0, to: shapes[Int(opcode - 0x30)].1, signed: false)
        default: return nil
        }
    }

    /// **Ne lit que ce qu'il élargit** : seize octets divisés par le rapport
    /// des largeurs, depuis la mémoire.
    mutating func widen(_ fields: Fields, _ shape: Widening) throws {
        let count = 16 / shape.to
        let read = try readVectorRM(fields, count * shape.from)
        let source = (low: read.0, high: read.1)
        let bits = UInt64(shape.from * 8)
        var halves: [UInt64] = [0, 0]
        for index in 0..<count {
            let offset = UInt64(index * shape.from * 8)
            var element = (offset < 64 ? source.low >> offset : source.high >> (offset - 64))
            element = bits == 64 ? element : element & ((1 << bits) - 1)
            if shape.signed, element >> (bits - 1) & 1 != 0, bits < 64 {
                element |= UInt64.max << bits
            }
            let place = index * shape.to * 8
            let width = UInt64(shape.to * 8)
            let kept = width == 64 ? element : element & ((1 << width) - 1)
            halves[place / 64] |= kept << UInt64(place % 64)
        }
        setVector(fields.reg, halves[0], halves[1])
    }

    /// Les insertions, les extractions et `PBLENDW` de `0F 3A`.
    mutating func insertOrExtract(
        _ instruction: X86Instruction, _ fields: Fields, _ opcode: UInt8, _ control: UInt8
    ) throws {
        let wide = (instruction.rex ?? 0) & 0x08 != 0
        let fromRegister = fields.mod == 0b11
        switch opcode {
        case 0x0E:  // PBLENDW : le mot i vient de la source quand le bit i est levé
            let read = try readVectorRM(fields, 16)
            var words = Self.signedWords(vector(fields.reg))
            let source = Self.signedWords((low: read.0, high: read.1))
            for index in 0..<8 where control >> index & 1 != 0 { words[index] = source[index] }
            let result = Self.packWords(words)
            setVector(fields.reg, result.0, result.1)

        // Les extractions : vers un registre, la valeur est élargie à zéro
        // sur trente-deux bits (soixante-quatre avec REX.W) ; vers la
        // mémoire, seule la largeur de l'élément est écrite. `PEXTRW` (`15`)
        // est la forme de SSE4.1, qui peut écrire la mémoire.
        case 0x14, 0x15, 0x16, 0x17:
            let width = opcode == 0x14 ? 1 : opcode == 0x15 ? 2 : (opcode == 0x16 && wide ? 8 : 4)
            let lanes = 16 / width
            let lane = Int(control) % lanes
            let bytes = Self.bytes(vector(fields.reg))
            var value: UInt64 = 0
            for index in 0..<width { value |= UInt64(bytes[lane * width + index]) << (8 * UInt64(index)) }
            try writeRM(fields, fromRegister ? (wide ? 8 : 4) : width, value)

        // Les insertions, depuis un registre général ou la mémoire.
        case 0x20, 0x22:
            let width = opcode == 0x20 ? 1 : (wide ? 8 : 4)
            let lanes = 16 / width
            let lane = Int(control) % lanes
            let value = try readRM(fields, fromRegister ? max(width, 4) : width)
            var bytes = Self.bytes(vector(fields.reg))
            for index in 0..<width { bytes[lane * width + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
            let result = Self.pack(bytes)
            setVector(fields.reg, result.0, result.1)

        case 0x21:  // INSERTPS
            var words = Self.doublewords(vector(fields.reg))
            let inserted: UInt64
            if fromRegister {
                inserted = Self.doublewords(vector(fields.rm))[Int(control >> 6)]
            } else {
                inserted = try readMemory(lastAddress, 4)
            }
            words[Int(control >> 4 & 3)] = inserted
            for index in 0..<4 where control >> index & 1 != 0 { words[index] = 0 }
            setVector(fields.reg, words[0] | words[1] << 32, words[2] | words[3] << 32)

        default:
            throw Fault.unsupported(String(format: "l'opcode 66 0F 3A %02X", opcode))
        }
    }

    /// **L'arrondi de SSE4.1.** Bits 1-0 de l'immédiat : au plus proche
    /// (pair en cas d'égalité), vers -∞, vers +∞, vers zéro ; le bit 2 prend
    /// à la place le mode de MXCSR (bits 13-14, dans le même ordre). Le
    /// bit 3 ne fait que taire l'exception de précision, que ce cœur ne lève
    /// pas. Un NaN ressort silencieux : l'instruction d'arrondi d'un hôte x86
    /// le fait déjà d'elle-même — le sabotage qui retire `quiet` ne casse rien
    /// ici —, et c'est écrit pour ne pas dépendre de l'hôte, que la CI Apple
    /// fait tourner sur le même corpus en arm64. Les formes scalaires ne lisent que
    /// leur élément et gardent le reste de la destination.
    mutating func round(_ fields: Fields, _ opcode: UInt8, _ control: UInt8) throws {
        let mode = control & 4 != 0 ? UInt8(mxcsr >> 13 & 3) : control & 3
        let rule: FloatingPointRoundingRule
        switch mode {
        case 0: rule = .toNearestOrEven
        case 1: rule = .down
        case 2: rule = .up
        default: rule = .towardZero
        }
        func double(_ bits: UInt64) -> UInt64 {
            let value = Self.asDouble(bits)
            return (value.isNaN ? Self.quiet(value) : value.rounded(rule)).bitPattern
        }
        func single(_ bits: UInt64) -> UInt64 {
            let value = Self.asSingle(bits)
            return UInt64((value.isNaN ? Self.quiet(value) : value.rounded(rule)).bitPattern)
        }
        func singles(_ half: UInt64) -> UInt64 { single(half) | single(half >> 32) << 32 }
        let destination = vector(fields.reg)
        switch opcode {
        case 0x08:  // ROUNDPS
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, singles(source.0), singles(source.1))
        case 0x09:  // ROUNDPD
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, double(source.0), double(source.1))
        case 0x0A:  // ROUNDSS
            let source = try readVectorRM(fields, 4)
            setVector(fields.reg, destination.low & ~0xFFFF_FFFF | single(source.0), destination.high)
        default:  // ROUNDSD
            let source = try readVectorRM(fields, 8)
            setVector(fields.reg, double(source.0), destination.high)
        }
    }

    static func doublewords(_ value: (low: UInt64, high: UInt64)) -> [UInt64] {
        [value.low & 0xFFFF_FFFF, value.low >> 32, value.high & 0xFFFF_FFFF, value.high >> 32]
    }
}
