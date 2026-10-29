import Foundation

// **Les formes VEX.128 de SSE**, exécutées par les instructions SSE que ce
// cœur a déjà.
//
// Compilé pour x86-64-v3, le code de RHEL 10 emploie l'encodage VEX partout
// où il touche aux registres vectoriels — `vmovdqa`, `vpxor`, `vaddsd` —, même
// sur cent vingt-huit bits. Ce sont les opérations de SSE, à deux différences
// près : un opérande de plus, `vvvv`, qui sert de première source sans être
// écrasé ; et le haut du registre YMM de destination remis à zéro, qui
// n'existe pas encore ici.
//
// **Une seule exécution, pas deux.** Plutôt que de récrire chaque opération,
// la forme VEX est traduite en sa forme héritée : le préfixe implicite (`pp`)
// redevient 66, F3 ou F2, les bits R, X, B et W redeviennent un REX, et la
// première source est recopiée dans la destination avant l'opération — ce
// que SSE suppose. Le seul piège est la seconde source quand c'est la
// destination elle-même (`vaddps %xmm0, %xmm2, %xmm0`) : la recopie
// l'écraserait. Elle passe alors par un registre libre, rendu ensuite.
//
// La référence est le processeur : `Tests/Fixtures/x86-avx128-oracle.tsv`,
// tiré des quatre corpus SSE.
extension X86Core {
    /// Ce qu'une forme VEX fait de ses opérandes.
    enum VEXForm {
        /// `reg` ← `vvvv` op `r/m`.
        case threeOperands
        /// La même, quand `r/m` est un registre général ou la mémoire —
        /// jamais un registre XMM qui pourrait être la destination.
        case threeOperandsGeneral
        /// `reg` ← op `r/m`, et `vvvv` doit valoir 1111.
        case twoOperands
        /// Les décalages par un immédiat : `vvvv` ← `r/m` décalé.
        case shiftByImmediate
        /// `VZEROUPPER`.
        case zeroUpper
    }

    /// La famille d'une forme VEX.128, ou `nil` pour une forme que ce cœur
    /// n'exécute pas. Les tables suivent celles de SSE : une opération
    /// entière sans préfixe 66 serait du MMX, que VEX n'a pas.
    static func vexForm(_ map: X86Instruction.OpcodeMap, _ opcode: UInt8, _ prefix: Int, register: Bool)
        -> VEXForm? {
        switch map {
        case .twoByte:
            let scalar = prefix >= 2
            switch opcode {
            // `vmovss`/`vmovsd` entre registres fusionnent avec `vvvv` ;
            // chargés de la mémoire, ils effacent le reste.
            case 0x10: return scalar && register ? .threeOperands : .twoOperands
            case 0x11: return scalar && register ? nil : .twoOperands
            // `vmovlps`, `vmovhlps`, `vmovlpd` ; `vmovsldup`, `vmovddup`.
            case 0x12, 0x16: return scalar ? .twoOperands : .threeOperands
            case 0x13, 0x17, 0x28, 0x29, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x50: return .twoOperands
            case 0x14, 0x15: return prefix <= 1 ? .threeOperands : nil
            case 0x2A: return scalar ? .threeOperandsGeneral : nil
            case 0x51, 0x52, 0x53, 0x5A: return scalar ? .threeOperands : .twoOperands
            case 0x54...0x59, 0x5C...0x5F, 0xC2, 0xC6: return .threeOperands
            case 0x5B: return .twoOperands
            case 0x77: return prefix == 0 ? .zeroUpper : nil
            default: break
            }
            // Le reste de la table n'a de forme vectorielle que sous un préfixe.
            guard prefix != 0 else { return nil }
            switch opcode {
            case 0x60...0x6D, 0x74...0x76, 0x7C, 0x7D, 0xD0...0xD5, 0xD8...0xE5, 0xE8...0xEF,
                 0xF1...0xF6, 0xF8...0xFE:
                return .threeOperands
            case 0x6E, 0x6F, 0x70, 0x7E, 0x7F, 0xC5, 0xD6, 0xD7, 0xE6, 0xE7, 0xF0, 0xF7: return .twoOperands
            case 0x71, 0x72, 0x73: return register ? .shiftByImmediate : nil
            case 0xC4: return .threeOperandsGeneral
            default: return nil
            }
        case .threeByte38:
            guard prefix == 1 else { return nil }
            switch opcode {
            case 0x00...0x0B, 0x28, 0x29, 0x2B, 0x37...0x40, 0xDC...0xDF: return .threeOperands
            case 0x17, 0x1C...0x1E, 0x20...0x25, 0x2A, 0x30...0x35, 0x41, 0xDB: return .twoOperands
            default: return nil
            }
        case .threeByte3A:
            guard prefix == 1 else { return nil }
            switch opcode {
            case 0x0A...0x0F, 0x21, 0x40...0x42, 0x44: return .threeOperands
            case 0x20, 0x22: return .threeOperandsGeneral
            case 0x08, 0x09, 0x14...0x17, 0x60...0x63, 0xDF: return .twoOperands
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Une forme VEX.128 de SSE, ou le refus.
    mutating func vex128Instruction(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        let modrm = instruction.modrm ?? 0
        let register = modrm >> 6 == 0b11
        guard let form = Self.vexForm(instruction.map, opcode, instruction.vexImpliedPrefix, register: register)
        else { throw Self.vectorRefusal() }
        let destination = Int(instruction.regField)
        let source = instruction.vexRegister
        switch form {
        case .zeroUpper:
            // Le haut des registres YMM n'existe pas encore : rien à effacer.
            return
        case .twoOperands:
            // `vvvv` sans emploi doit valoir 1111 ; autre chose est #UD.
            guard source == 0 else { throw Self.vectorRefusal() }
            try perform(Self.legacy(instruction, modrm: modrm))
        case .shiftByImmediate:
            // L'opération héritée décale `r/m` sur place : on y met `vvvv`.
            let shifted = Int(instruction.rmField)
            let saved = vector(source)
            let value = vector(shifted)
            setVector(source, value.low, value.high)
            do {
                try perform(Self.legacy(instruction, modrm: modrm & 0xF8 | UInt8(source & 7),
                                        base: UInt8(source >> 3)))
            } catch {
                setVector(source, saved.low, saved.high)
                throw error
            }
        case .threeOperands, .threeOperandsGeneral:
            guard destination != source else { return try perform(Self.legacy(instruction, modrm: modrm)) }
            let saved = vector(destination)
            let first = vector(source)
            // La seconde source est la destination : elle passe par un
            // registre que l'instruction ne nomme pas, et qui est rendu.
            if form == .threeOperands, register, Int(instruction.rmField) == destination {
                let spare = (0..<16).first { $0 != destination && $0 != source } ?? 0
                let kept = vector(spare)
                setVector(spare, saved.low, saved.high)
                setVector(destination, first.low, first.high)
                defer { setVector(spare, kept.low, kept.high) }
                do {
                    try perform(Self.legacy(instruction, modrm: modrm & 0xF8 | UInt8(spare & 7),
                                            base: UInt8(spare >> 3)))
                } catch {
                    setVector(destination, saved.low, saved.high)
                    throw error
                }
                return
            }
            setVector(destination, first.low, first.high)
            do {
                try perform(Self.legacy(instruction, modrm: modrm))
            } catch {
                // Une faute laisse la destination comme elle était.
                setVector(destination, saved.low, saved.high)
                throw error
            }
        }
    }

    /// VEX.L à 1 : 256 bits. Seul `VZEROALL` est exécuté — sans haut des
    /// registres YMM, il efface les seize registres XMM.
    mutating func wideVEXInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        guard instruction.map == .twoByte, opcode == 0x77, instruction.vexImpliedPrefix == 0 else {
            throw Self.vectorRefusal()
        }
        for index in vectors.indices { vectors[index] = 0 }
    }

    /// La forme héritée d'une forme VEX : le préfixe implicite remis en
    /// préfixe, R, X, B et W remis en REX — `base` remplace le bit B quand le
    /// ModRM a été récrit. Même longueur, pour que RIP avance pareil.
    static func legacy(_ instruction: X86Instruction, modrm: UInt8, base: UInt8? = nil) -> X86Instruction {
        let implied: UInt16
        switch instruction.vexImpliedPrefix {
        case 1: implied = 1 << 9   // 66
        case 2: implied = 1 << 2   // F3
        case 3: implied = 1 << 1   // F2
        default: implied = 0
        }
        let first = instruction.vexBytes.0
        var rex: UInt8 = 0x40 | (~first >> 5) & 0x04
        if instruction.vexCount == 3 {
            rex = 0x40 | (~first >> 5) & 0x07 | (instruction.vexBytes.1 >> 4) & 0x08
        }
        if let base { rex = rex & ~0x01 | base }
        return X86Instruction(
            prefixMask: instruction.prefixMask | implied, rex: rex, vexBytes: (0, 0, 0), vexCount: 0,
            map: instruction.map, opcode: instruction.opcode, modrm: modrm, sib: instruction.sib,
            displacementBytes: instruction.displacementBytes, displacement: instruction.displacement,
            immediateBytes: instruction.immediateBytes, immediate: instruction.immediate,
            length: instruction.length)
    }
}
