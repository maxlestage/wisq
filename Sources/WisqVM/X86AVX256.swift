import Foundation

// **Les formes VEX.256 qui calculent par moitiés de cent vingt-huit bits.**
//
// AVX et AVX2 n'ont pas inventé des opérations de 256 bits : presque toutes
// font deux fois l'opération de SSE, une par moitié (*lane*), sans que rien
// ne passe de l'une à l'autre. `vpaddd %ymm1, %ymm2, %ymm0` est `vpaddd` sur
// les bas, puis sur les hauts ; `vpshufb` mélange dans chaque moitié, jamais
// à travers. C'est ce que fait ce fichier : la moitié basse par la forme
// VEX.128 (`X86AVX.swift`), puis la haute par la même, après avoir posé le
// haut de chaque registre nommé à la place de son bas, et seize octets plus
// loin en mémoire.
//
// **Trois écarts à la règle, tenus ici.**
// - Les décalages par un registre (`vpsrld %xmm1, %ymm2, %ymm0`) prennent
//   leur compte dans un XMM entier, le même pour les deux moitiés.
// - L'immédiat de `vshufpd` a deux bits par moitié : la moitié haute lit les
//   deux suivants.
// - `vpmovmskb`, `vmovmskps`, `vmovmskpd` et `vptest` rassemblent les deux
//   moitiés en un registre général ou en drapeaux.
//
// Ce qui traverse les moitiés — `vperm2i128`, `vpermq`, `vinserti128`,
// `vpbroadcast*`, les élargissements — est dans `X86AVX2.swift` ; les
// conversions qui changent de largeur restent refusées par leur nom.
//
// La référence est le processeur : `Tests/Fixtures/x86-avx256-oracle.tsv`.
extension X86Core {
    /// Comment une forme VEX.256 se partage entre ses deux moitiés.
    enum LaneSplit: Equatable {
        /// Deux fois la même opération.
        case independent
        /// La moitié haute lit l'immédiat décalé de tant de bits.
        case immediateShift(Int)
        /// Le compte d'un décalage, un XMM entier, sert aux deux moitiés.
        case sharedCount
        /// Un masque de signes : la moitié haute au-dessus de tant de bits.
        case mask(Int)
        /// `vptest` : ZF et CF valent pour les deux moitiés ensemble.
        case test
    }

    /// Le partage d'une forme VEX.256, ou `nil` quand elle n'en a pas ici.
    static func laneSplit(_ map: X86Instruction.OpcodeMap, _ opcode: UInt8, _ prefix: Int) -> LaneSplit? {
        switch map {
        case .twoByte:
            switch opcode {
            case 0x10, 0x11, 0x14, 0x15, 0x28, 0x29, 0x2B, 0x51, 0x52, 0x53, 0x54...0x59, 0x5C...0x5F, 0xC2:
                return prefix <= 1 ? .independent : nil
            case 0x12: return prefix >= 2 ? .independent : nil  // movsldup, movddup
            case 0x16: return prefix == 2 ? .independent : nil  // movshdup
            case 0x5B: return .independent  // cvtdq2ps, cvtps2dq, cvttps2dq : même largeur
            case 0xC6: return prefix == 1 ? .immediateShift(2) : prefix == 0 ? .independent : nil
            case 0x50: return prefix <= 1 ? .mask(prefix == 0 ? 4 : 2) : nil
            case 0x7C, 0x7D, 0xD0: return prefix == 1 || prefix == 3 ? .independent : nil
            case 0x6F, 0x7F: return prefix == 1 || prefix == 2 ? .independent : nil
            case 0x70: return prefix != 0 ? .independent : nil
            case 0xF0: return prefix == 3 ? .independent : nil
            default: break
            }
            guard prefix == 1 else { return nil }
            switch opcode {
            case 0xD1, 0xD2, 0xD3, 0xE1, 0xE2, 0xF1, 0xF2, 0xF3: return .sharedCount
            case 0xD7: return .mask(16)
            case 0x60...0x6D, 0x71...0x76, 0xD4, 0xD5, 0xD8...0xE0, 0xE3...0xE5, 0xE7, 0xE8...0xEF, 0xF4...0xF6,
                 0xF8...0xFE:
                return .independent
            default: return nil
            }
        case .threeByte38:
            guard prefix == 1 else { return nil }
            switch opcode {
            case 0x00...0x0B, 0x1C...0x1E, 0x28, 0x29, 0x2A, 0x2B, 0x37...0x40: return .independent
            case 0x17: return .test
            default: return nil
            }
        case .threeByte3A:
            guard prefix == 1 else { return nil }
            switch opcode {
            // `vblendps`, `vblendpd` et `vdpps` attendent leur forme SSE, que
            // ce cœur n'a pas encore.
            case 0x08, 0x09, 0x0E, 0x0F: return .independent
            // `vmpsadbw` : la moitié haute choisit ses blocs dans les bits 3
            // à 5 de l'immédiat, la basse dans les bits 0 à 2.
            case 0x42: return .immediateShift(3)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Une forme VEX.256 : `vzeroall`, ou une opération par moitiés.
    mutating func wideVEXInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        let prefix = instruction.vexImpliedPrefix
        if instruction.map == .twoByte, opcode == 0x77, prefix == 0 {
            // `VZEROALL` : les seize registres YMM entiers.
            for index in vectors.indices { vectors[index] = 0 }
            for index in upperVectors.indices { upperVectors[index] = 0 }
            return
        }
        let modrm = instruction.modrm ?? 0
        let register = modrm >> 6 == 0b11
        guard let split = Self.laneSplit(instruction.map, opcode, prefix),
              let form = Self.vexForm(instruction.map, opcode, prefix, register: register)
        else {
            // Ce qui traverse les moitiés (`X86AVX2.swift`), ou le refus.
            guard try crossLaneInstruction(instruction, opcode) else { throw Self.vectorRefusal() }
            return
        }

        // Les registres XMM que l'instruction nomme : ceux dont la moitié
        // haute prend la place du bas pendant le second passage.
        var named = [Int(instruction.regField)]
        if instruction.vexRegister != 0 || form != .twoOperands { named.append(instruction.vexRegister) }
        if register { named.append(Int(instruction.rmField)) }
        let target: Int?
        switch form {
        case .shiftByImmediate: target = instruction.vexRegister
        case .twoOperands: target = Self.vexTwoOperandTarget(instruction, opcode, register: register)
        default: target = Int(instruction.regField)
        }

        let before = vectors
        let flagsBefore = flags
        let generalBefore = registers.read(Int(instruction.regField))
        do {
            try executeVEX128(instruction, form, modrm: modrm, register: register)
            let lowFlags = flags
            let lowGeneral = registers.read(Int(instruction.regField))
            let lowResult = target.map { vector($0) }

            // La moitié haute : les hauts à la place des bas, seize octets
            // plus loin, l'immédiat de la moitié haute.
            let kept = vectors
            for index in named { setVector(index, upperVectors[2 * index], upperVectors[2 * index + 1]) }
            var immediate = instruction.immediate
            if case .immediateShift(let bits) = split { immediate >>= UInt64(bits) }
            let shift: Int64 = register || split == .sharedCount ? 0 : 16
            var half = Self.withHalf(instruction, displacement: shift, immediate: immediate)
            var halfModRM = modrm
            // Le compte d'un décalage vient d'être remplacé par son haut,
            // comme tout registre nommé : il passe par un registre libre, de
            // xmm0 à xmm7 pour que le bit B de VEX puisse valoir zéro, avec
            // sa valeur d'avant — la moitié basse a pu l'écraser, quand il
            // est aussi la destination (`vpsrld %xmm0, %ymm0, %ymm0`).
            if split == .sharedCount, register,
               let spare = (0..<8).first(where: { !named.contains($0) && $0 != Int(instruction.rmField) }) {
                let count = before[2 * Int(instruction.rmField)...2 * Int(instruction.rmField) + 1]
                setVector(spare, count.first!, count.last!)
                halfModRM = modrm & 0xF8 | UInt8(spare)
                half = Self.withHalf(half, modrm: halfModRM)
            }
            try executeVEX128(half, form, modrm: halfModRM, register: register)
            if let target {
                let high = vector(target)
                upperVectors[2 * target] = high.low
                upperVectors[2 * target + 1] = high.high
            }
            vectors = kept
            if let target, let lowResult { setVector(target, lowResult.low, lowResult.high) }

            switch split {
            case .mask(let bits):
                // Le registre général de destination : le bas d'abord, le haut
                // au-dessus. La forme de 32 bits a déjà effacé le reste.
                let high = registers.read(Int(instruction.regField))
                write(Int(instruction.regField), 4, highByte: false, lowGeneral | high << UInt64(bits))
            case .test:
                // ZF : les deux moitiés à zéro ; CF de même pour l'autre ET.
                let both = lowFlags & flags & (Flag.zero | Flag.carry)
                flags = flags & ~(Flag.zero | Flag.carry) | both
            default:
                break
            }
        } catch {
            // Une faute — la moitié haute qui touche une page absente — laisse
            // tout comme avant la première moitié.
            vectors = before
            flags = flagsBefore
            write(Int(instruction.regField), 8, highByte: false, generalBefore)
            throw error
        }
    }

    /// La même instruction, un autre ModRM dont `r/m` est un registre de
    /// xmm0 à xmm7 : le bit B de VEX à zéro (inversé dans l'octet).
    static func withHalf(_ instruction: X86Instruction, modrm: UInt8) -> X86Instruction {
        var bytes = instruction.vexBytes
        if instruction.vexCount == 3 { bytes.0 |= 0x20 }
        return X86Instruction(
            prefixMask: instruction.prefixMask, rex: instruction.rex, vexBytes: bytes,
            vexCount: instruction.vexCount, map: instruction.map, opcode: instruction.opcode,
            modrm: modrm, sib: instruction.sib, displacementBytes: instruction.displacementBytes,
            displacement: instruction.displacement, immediateBytes: instruction.immediateBytes,
            immediate: instruction.immediate, length: instruction.length)
    }

    /// La même instruction, pour la moitié haute : un déplacement augmenté,
    /// un autre immédiat. Le reste — préfixe, ModRM, longueur — ne bouge pas.
    static func withHalf(_ instruction: X86Instruction, displacement: Int64, immediate: UInt64) -> X86Instruction {
        X86Instruction(
            prefixMask: instruction.prefixMask, rex: instruction.rex, vexBytes: instruction.vexBytes,
            vexCount: instruction.vexCount, map: instruction.map, opcode: instruction.opcode,
            modrm: instruction.modrm, sib: instruction.sib, displacementBytes: instruction.displacementBytes,
            displacement: instruction.displacement &+ displacement, immediateBytes: instruction.immediateBytes,
            immediate: immediate, length: instruction.length)
    }
}
