import Foundation

// **Le MMX** : les instructions entières sur soixante-quatre bits, sans préfixe.
//
// CPUID l'annonçait (bit 23 de la feuille 1) parce que la glibc refuse de
// charger un programme sans le socle x86-64, MMX compris, et aucune de ses
// instructions n'existait ici. Une sonde de la table `0F` en a compté environ
// soixante-dix ; depuis #664 un programme qui s'en servait mourait seul d'un
// « Illegal instruction » au lieu d'emporter la machine — il mourait quand même.
//
// **Les registres MMX sont la pile x87.** MMn est la mantisse du registre
// physique n. Toute instruction MMX, sauf EMMS, remet le sommet de la pile à
// zéro et marque les huit étiquettes valides ; écrire MMn met son exposant à
// tout-un. C'est ce que fait le processeur, et ce que `FXSAVE` rend ensuite :
// un programme qui mélange les deux sans EMMS lit les mêmes octets ici que là.
//
// La référence est `Tests/Fixtures/x86-mmx-oracle.tsv`, produite par le vrai
// processeur (`scripts/build-x86-mmx-oracle.py`).
extension X86Core {
    /// MMn.
    func mmx(_ index: Int) -> UInt64 { x87[index & 7].significand }

    /// Écrit MMn : la mantisse, et l'exposant à tout-un.
    mutating func setMMX(_ index: Int, _ value: UInt64) {
        x87[index & 7] = X86Extended(significand: value, signExponent: 0xFFFF)
    }

    /// Ce que fait toute instruction MMX avant le reste : sommet à zéro,
    /// étiquettes valides.
    mutating func enterMMX() {
        x87TopIndex = 0
        x87Tags = 0
    }

    /// Le r/m d'une instruction MMX : un registre MMX, ou soixante-quatre bits
    /// de mémoire.
    mutating func readMMXRM(_ fields: Fields) throws -> UInt64 {
        fields.mod == 0b11 ? mmx(fields.rm) : try readRMMemory(8)
    }

    /// Les octets `0F xx` sans préfixe qui sont du MMX.
    static func isMMXOpcode(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x60...0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x7E, 0x7F, 0xC4, 0xC5,
             0xD1...0xDF, 0xE0...0xEF, 0xF1...0xFF:
            return true
        default:
            return false
        }
    }

    /// Exécute `0F opcode` s'il est du MMX, et dit si c'était le cas.
    mutating func mmxInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws -> Bool {
        guard instruction.vexCount == 0, !instruction.hasPrefix(0x66) else { return false }
        // MOVDQ2Q et MOVQ2DQ : le pont entre XMM et MMX, sous F2 et F3.
        if opcode == 0xD6, instruction.hasPrefix(0xF2) || instruction.hasPrefix(0xF3) {
            let fields = try decodeFields(instruction)
            guard fields.mod == 0b11 else { return false }
            enterMMX()
            if instruction.hasPrefix(0xF2) {
                setMMX(fields.reg, vector(fields.rm).low)  // MOVDQ2Q mm, xmm
            } else {
                setVector(fields.reg, mmx(fields.rm), 0)   // MOVQ2DQ xmm, mm
            }
            return true
        }
        guard !instruction.hasPrefix(0xF2), !instruction.hasPrefix(0xF3), Self.isMMXOpcode(opcode)
        else { return false }
        let fields = try decodeFields(instruction)

        switch opcode {
        // Les déplacements.
        case 0x6E:  // MOVD/MOVQ mm, r/m32 ou r/m64
            let wide = (instruction.rex ?? 0) & 0x08 != 0
            let value = try readRM(fields, wide ? 8 : 4)
            enterMMX()
            setMMX(fields.reg, value)
        case 0x7E:  // MOVD/MOVQ r/m32 ou r/m64, mm
            let wide = (instruction.rex ?? 0) & 0x08 != 0
            try probeWrite(fields, wide ? 8 : 4)
            enterMMX()
            let value = mmx(fields.reg)
            try writeRM(fields, wide ? 8 : 4, wide ? value : value & 0xFFFF_FFFF)
        case 0x6F:  // MOVQ mm, mm/m64
            let value = try readMMXRM(fields)
            enterMMX()
            setMMX(fields.reg, value)
        case 0x7F, 0xE7:  // MOVQ mm/m64, mm ; MOVNTQ m64, mm
            if opcode == 0xE7, fields.mod == 0b11 { return false }
            try probeWrite(fields, 8)
            enterMMX()
            if fields.mod == 0b11 {
                setMMX(fields.rm, mmx(fields.reg))
            } else {
                try writeRMMemory(8, mmx(fields.reg))
            }

        // Les décalages par immédiat : 71 mots, 72 doubles mots, 73 quadruple.
        case 0x71, 0x72, 0x73:
            guard fields.mod == 0b11 else { return false }
            let count = instruction.immediate & 0xFF
            let bytes = opcode == 0x71 ? 2 : opcode == 0x72 ? 4 : 8
            let kind = (instruction.modrm! >> 3) & 7
            guard kind == 2 || kind == 6 || (kind == 4 && opcode != 0x73) else { return false }
            enterMMX()
            setMMX(fields.rm, Self.mmxShift(mmx(fields.rm), count, bytes, kind))

        // PMOVMSKB r32, mm : le bit de poids fort de chaque octet.
        case 0xD7:
            guard fields.mod == 0b11 else { return false }
            enterMMX()
            let value = mmx(fields.rm)
            var mask: UInt64 = 0
            for byte in 0..<8 where (value >> (8 * byte + 7)) & 1 != 0 { mask |= 1 << byte }
            write(fields.reg, 4, highByte: false, mask)

        // PINSRW mm, r32/m16, imm8 et PEXTRW r32, mm, imm8.
        case 0xC4:
            let position = Int(instruction.immediate & 3)
            let word = try readRM(fields, 2) & 0xFFFF
            enterMMX()
            let shift = UInt64(16 * position)
            setMMX(fields.reg, mmx(fields.reg) & ~(0xFFFF << shift) | word << shift)
        case 0xC5:
            guard fields.mod == 0b11 else { return false }
            let position = Int(instruction.immediate & 3)
            enterMMX()
            write(fields.reg, 4, highByte: false, (mmx(fields.rm) >> UInt64(16 * position)) & 0xFFFF)

        // PSHUFW mm, mm/m64, imm8.
        case 0x70:
            let control = instruction.immediate & 0xFF
            let source = try readMMXRM(fields)
            enterMMX()
            var result: UInt64 = 0
            for lane in 0..<4 {
                let pick = (control >> UInt64(2 * lane)) & 3
                result |= ((source >> (16 * pick)) & 0xFFFF) << UInt64(16 * lane)
            }
            setMMX(fields.reg, result)

        // MASKMOVQ mm, mm : les octets choisis par le bit fort du masque,
        // rangés à [RDI].
        case 0xF7:
            guard fields.mod == 0b11 else { return false }
            enterMMX()
            let data = mmx(fields.reg)
            let mask = mmx(fields.rm)
            for byte in 0..<8 where (mask >> UInt64(8 * byte + 7)) & 1 != 0 {
                try writeMemory(registers[7] &+ UInt64(byte), 1, (data >> UInt64(8 * byte)) & 0xFF)
            }

        // Le reste : un calcul de deux opérandes, destination MMn.
        default:
            let source = try readMMXRM(fields)
            enterMMX()
            guard let result = Self.mmxArithmetic(opcode, mmx(fields.reg), source) else { return false }
            setMMX(fields.reg, result)
        }
        return true
    }

    // MARK: - Les calculs, sur soixante-quatre bits

    /// `operation` voie par voie, sur des voies de `bytes` octets.
    static func mmxLanes(
        _ a: UInt64, _ b: UInt64, _ bytes: Int, _ operation: (UInt64, UInt64) -> UInt64
    ) -> UInt64 {
        let bits = 8 * bytes
        let mask: UInt64 = bits == 64 ? ~0 : (1 << UInt64(bits)) - 1
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: bits) {
            let lane = operation((a >> UInt64(shift)) & mask, (b >> UInt64(shift)) & mask) & mask
            result |= lane << UInt64(shift)
        }
        return result
    }

    /// Une voie de `bits` bits, lue signée.
    static func mmxSigned(_ value: UInt64, _ bits: Int) -> Int64 {
        Int64(bitPattern: value << UInt64(64 - bits)) >> Int64(64 - bits)
    }

    /// Une valeur ramenée dans `[low, high]`.
    static func mmxClamp(_ value: Int64, _ low: Int64, _ high: Int64) -> UInt64 {
        UInt64(bitPattern: min(max(value, low), high))
    }

    /// Un décalage de chaque voie : `kind` 2 logique à droite, 4 arithmétique
    /// à droite, 6 à gauche. Un compte au-delà de la largeur rend zéro — ou le
    /// signe étalé pour l'arithmétique.
    static func mmxShift(_ value: UInt64, _ count: UInt64, _ bytes: Int, _ kind: UInt8) -> UInt64 {
        let bits = UInt64(8 * bytes)
        return mmxLanes(value, 0, bytes) { lane, _ in
            switch kind {
            case 2: return count >= bits ? 0 : lane >> count
            case 6: return count >= bits ? 0 : lane << count
            default:
                let signed = mmxSigned(lane, Int(bits))
                return UInt64(bitPattern: signed >> Int64(min(count, bits - 1)))
            }
        }
    }

    /// Entrelace les voies de `bytes` octets des moitiés basses (ou hautes) de
    /// `a` et `b`.
    static func mmxUnpack(_ a: UInt64, _ b: UInt64, _ bytes: Int, high: Bool) -> UInt64 {
        let bits = 8 * bytes
        let mask: UInt64 = (1 << UInt64(bits)) - 1
        let half = 32 / bits
        var result: UInt64 = 0
        for index in 0..<half {
            let from = UInt64((high ? half + index : index) * bits)
            result |= ((a >> from) & mask) << UInt64(2 * index * bits)
            result |= ((b >> from) & mask) << UInt64((2 * index + 1) * bits)
        }
        return result
    }

    /// Les voies de `bytes` octets de `a` puis de `b`, saturées en voies deux
    /// fois plus étroites, signées ou non.
    static func mmxPack(_ a: UInt64, _ b: UInt64, _ bytes: Int, unsigned: Bool) -> UInt64 {
        let bits = 8 * bytes
        let narrow = bits / 2
        let low: Int64 = unsigned ? 0 : -(1 << Int64(narrow - 1))
        let high: Int64 = unsigned ? (1 << Int64(narrow)) - 1 : (1 << Int64(narrow - 1)) - 1
        let mask: UInt64 = (1 << UInt64(narrow)) - 1
        var result: UInt64 = 0
        let count = 64 / bits
        for (part, value) in [a, b].enumerated() {
            for index in 0..<count {
                let lane = mmxSigned(value >> UInt64(index * bits), bits)
                let packed = mmxClamp(lane, low, high) & mask
                result |= packed << UInt64((part * count + index) * narrow)
            }
        }
        return result
    }

    /// Les instructions à deux opérandes, ou `nil` pour un octet qui n'en est
    /// pas une.
    static func mmxArithmetic(_ opcode: UInt8, _ a: UInt64, _ b: UInt64) -> UInt64? {
        switch opcode {
        case 0x60: return mmxUnpack(a, b, 1, high: false)  // PUNPCKLBW
        case 0x61: return mmxUnpack(a, b, 2, high: false)  // PUNPCKLWD
        case 0x62: return mmxUnpack(a, b, 4, high: false)  // PUNPCKLDQ
        case 0x68: return mmxUnpack(a, b, 1, high: true)   // PUNPCKHBW
        case 0x69: return mmxUnpack(a, b, 2, high: true)   // PUNPCKHWD
        case 0x6A: return mmxUnpack(a, b, 4, high: true)   // PUNPCKHDQ
        case 0x63: return mmxPack(a, b, 2, unsigned: false)  // PACKSSWB
        case 0x6B: return mmxPack(a, b, 4, unsigned: false)  // PACKSSDW
        case 0x67: return mmxPack(a, b, 2, unsigned: true)   // PACKUSWB

        // Les comparaisons : un masque de tout-un ou de tout-zéro par voie.
        case 0x74, 0x75, 0x76:
            let bytes = 1 << Int(opcode - 0x74)
            return mmxLanes(a, b, bytes) { $0 == $1 ? ~0 : 0 }
        case 0x64, 0x65, 0x66:
            let bytes = 1 << Int(opcode - 0x64)
            return mmxLanes(a, b, bytes) { mmxSigned($0, 8 * bytes) > mmxSigned($1, 8 * bytes) ? ~0 : 0 }

        // Les décalages par registre : le compte est le r/m entier.
        case 0xD1: return mmxShift(a, b, 2, 2)
        case 0xD2: return mmxShift(a, b, 4, 2)
        case 0xD3: return mmxShift(a, b, 8, 2)
        case 0xE1: return mmxShift(a, b, 2, 4)
        case 0xE2: return mmxShift(a, b, 4, 4)
        case 0xF1: return mmxShift(a, b, 2, 6)
        case 0xF2: return mmxShift(a, b, 4, 6)
        case 0xF3: return mmxShift(a, b, 8, 6)

        // L'addition et la soustraction, qui enveloppent.
        case 0xFC: return mmxLanes(a, b, 1) { $0 &+ $1 }
        case 0xFD: return mmxLanes(a, b, 2) { $0 &+ $1 }
        case 0xFE: return mmxLanes(a, b, 4) { $0 &+ $1 }
        case 0xD4: return a &+ b
        case 0xF8: return mmxLanes(a, b, 1) { $0 &- $1 }
        case 0xF9: return mmxLanes(a, b, 2) { $0 &- $1 }
        case 0xFA: return mmxLanes(a, b, 4) { $0 &- $1 }
        case 0xFB: return a &- b

        // Les mêmes, saturées.
        case 0xEC: return mmxLanes(a, b, 1) { mmxClamp(mmxSigned($0, 8) + mmxSigned($1, 8), -128, 127) }
        case 0xED: return mmxLanes(a, b, 2) {
            mmxClamp(mmxSigned($0, 16) + mmxSigned($1, 16), -32768, 32767)
        }
        case 0xE8: return mmxLanes(a, b, 1) { mmxClamp(mmxSigned($0, 8) - mmxSigned($1, 8), -128, 127) }
        case 0xE9: return mmxLanes(a, b, 2) {
            mmxClamp(mmxSigned($0, 16) - mmxSigned($1, 16), -32768, 32767)
        }
        case 0xDC: return mmxLanes(a, b, 1) { min($0 + $1, 0xFF) }
        case 0xDD: return mmxLanes(a, b, 2) { min($0 + $1, 0xFFFF) }
        case 0xD8: return mmxLanes(a, b, 1) { $0 > $1 ? $0 - $1 : 0 }
        case 0xD9: return mmxLanes(a, b, 2) { $0 > $1 ? $0 - $1 : 0 }

        // Les produits.
        case 0xD5: return mmxLanes(a, b, 2) { $0 &* $1 }  // PMULLW
        case 0xE5: return mmxLanes(a, b, 2) {             // PMULHW
            UInt64(bitPattern: (mmxSigned($0, 16) * mmxSigned($1, 16)) >> 16)
        }
        case 0xE4: return mmxLanes(a, b, 2) { ($0 * $1) >> 16 }  // PMULHUW
        case 0xF4: return (a & 0xFFFF_FFFF) &* (b & 0xFFFF_FFFF)  // PMULUDQ
        case 0xF5:  // PMADDWD : deux produits signés de mots, sommés par double mot.
            return mmxLanes(a, b, 4) { x, y in
                let sum = mmxSigned(x, 16) * mmxSigned(y, 16)
                    + mmxSigned(x >> 16, 16) * mmxSigned(y >> 16, 16)
                return UInt64(bitPattern: sum)
            }

        // Les extrêmes et les moyennes.
        case 0xDA: return mmxLanes(a, b, 1) { min($0, $1) }  // PMINUB
        case 0xDE: return mmxLanes(a, b, 1) { max($0, $1) }  // PMAXUB
        case 0xEA: return mmxLanes(a, b, 2) {                // PMINSW
            mmxSigned($0, 16) < mmxSigned($1, 16) ? $0 : $1
        }
        case 0xEE: return mmxLanes(a, b, 2) {                // PMAXSW
            mmxSigned($0, 16) > mmxSigned($1, 16) ? $0 : $1
        }
        case 0xE0: return mmxLanes(a, b, 1) { ($0 + $1 + 1) >> 1 }  // PAVGB
        case 0xE3: return mmxLanes(a, b, 2) { ($0 + $1 + 1) >> 1 }  // PAVGW
        case 0xF6:  // PSADBW : la somme des écarts absolus, dans le mot bas.
            var sum: UInt64 = 0
            for byte in 0..<8 {
                let x = (a >> UInt64(8 * byte)) & 0xFF
                let y = (b >> UInt64(8 * byte)) & 0xFF
                sum += x > y ? x - y : y - x
            }
            return sum

        // La logique.
        case 0xDB: return a & b
        case 0xDF: return ~a & b
        case 0xEB: return a | b
        case 0xEF: return a ^ b
        default: return nil
        }
    }
}
