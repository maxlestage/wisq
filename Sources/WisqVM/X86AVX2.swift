import Foundation

// **Ce qui traverse les moitiés d'un YMM** : diffusions, insertions et
// extractions de 128 bits, permutations, mélanges par masque, décalages par
// élément, élargissements sur 256 bits.
//
// `X86AVX256.swift` exécute ce qui calcule par moitiés en passant par SSE.
// Ici, rien n'a de forme SSE : ces opérations n'existent que sous VEX, et
// elles sont écrites directement, sur les quatre mots d'un YMM — le bas
// (`vectors`) puis le haut (`upperVectors`). Une forme VEX.128 rend deux mots
// et efface le haut de sa destination, comme toutes les autres.
//
// La référence est le processeur : `Tests/Fixtures/x86-avx2-oracle.tsv`.
extension X86Core {
    /// Les quatre mots d'un YMM, du bas vers le haut.
    func ymmWords(_ index: Int) -> [UInt64] {
        [vectors[2 * index], vectors[2 * index + 1], upperVectors[2 * index], upperVectors[2 * index + 1]]
    }

    /// Range quatre mots — ou deux, le haut alors effacé.
    mutating func setYMMWords(_ index: Int, _ words: [UInt64]) {
        vectors[2 * index] = words[0]
        vectors[2 * index + 1] = words[1]
        upperVectors[2 * index] = words.count > 2 ? words[2] : 0
        upperVectors[2 * index + 1] = words.count > 2 ? words[3] : 0
    }

    /// L'opérande `r/m` : un YMM entier, ou `bytes` octets de mémoire,
    /// complétés de zéros jusqu'à quatre mots.
    private mutating func vexSource(_ instruction: X86Instruction, _ fields: Fields, bytes: Int) throws -> [UInt64] {
        if fields.mod == 0b11 { return ymmWords(fields.rm) }
        var words = [UInt64](repeating: 0, count: 4)
        let address = lastAddress
        if bytes < 8 {
            words[0] = try readMemory(address, bytes)
        } else {
            for index in 0..<bytes / 8 { words[index] = try readMemory(address &+ UInt64(8 * index), 8) }
        }
        return words
    }

    /// Un élément de `bits` bits, rangé dans des mots de soixante-quatre.
    static func element(_ words: [UInt64], _ index: Int, _ bits: Int) -> UInt64 {
        let perWord = 64 / bits
        let mask: UInt64 = bits == 64 ? ~0 : (1 << UInt64(bits)) - 1
        return words[index / perWord] >> UInt64(bits * (index % perWord)) & mask
    }

    static func setElement(_ words: inout [UInt64], _ index: Int, _ bits: Int, _ value: UInt64) {
        let perWord = 64 / bits
        let mask: UInt64 = bits == 64 ? ~0 : (1 << UInt64(bits)) - 1
        let shift = UInt64(bits * (index % perWord))
        words[index / perWord] = words[index / perWord] & ~(mask << shift) | (value & mask) << shift
    }

    /// Une forme VEX qui traverse les moitiés, exécutée ; `false` quand ce
    /// n'en est pas une — l'appelant refuse alors.
    mutating func crossLaneInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws -> Bool {
        // FMA, F16C et les conversions de largeur : `X86FMA.swift`.
        if try extendedFloatInstruction(instruction, opcode) { return true }
        guard instruction.vexImpliedPrefix == 1, instruction.modrm != nil else { return false }
        let wide = instruction.vexLength == 1
        let wordCount = wide ? 4 : 2
        let w1 = instruction.wideOperandSize == 8
        switch (instruction.map, opcode) {
        // Les diffusions : un élément, ou cent vingt-huit bits, partout.
        case (.threeByte38, 0x18) where !w1, (.threeByte38, 0x58) where !w1:
            try broadcast(instruction, bits: 32, wordCount)
        case (.threeByte38, 0x19) where !w1 && wide, (.threeByte38, 0x59) where !w1:
            try broadcast(instruction, bits: 64, wordCount)
        case (.threeByte38, 0x78) where !w1: try broadcast(instruction, bits: 8, wordCount)
        case (.threeByte38, 0x79) where !w1: try broadcast(instruction, bits: 16, wordCount)
        case (.threeByte38, 0x1A) where !w1 && wide, (.threeByte38, 0x5A) where !w1 && wide:
            let fields = try decodeFields(instruction)
            guard fields.mod != 0b11 else { return false }
            let half = try vexSource(instruction, fields, bytes: 16)
            setYMMWords(fields.reg, [half[0], half[1], half[0], half[1]])

        // Insérer et extraire une moitié.
        case (.threeByte3A, 0x18) where !w1 && wide, (.threeByte3A, 0x38) where !w1 && wide:
            let fields = try decodeFields(instruction)
            let half = try vexSource(instruction, fields, bytes: 16)
            var words = ymmWords(instruction.vexRegister)
            let at = Int(instruction.immediate & 1) * 2
            words[at] = half[0]
            words[at + 1] = half[1]
            setYMMWords(fields.reg, words)
        case (.threeByte3A, 0x19) where !w1 && wide, (.threeByte3A, 0x39) where !w1 && wide:
            guard instruction.vexRegister == 0 else { return false }
            let fields = try decodeFields(instruction)
            let words = ymmWords(fields.reg)
            let at = Int(instruction.immediate & 1) * 2
            if fields.mod == 0b11 {
                setYMMWords(fields.rm, [words[at], words[at + 1]])
            } else {
                try writeMemory(lastAddress, 8, words[at])
                try writeMemory(lastAddress &+ 8, 8, words[at + 1])
            }

        // `vperm2f128`, `vperm2i128` : chaque moitié choisie parmi quatre, ou zéro.
        case (.threeByte3A, 0x06) where !w1 && wide, (.threeByte3A, 0x46) where !w1 && wide:
            let fields = try decodeFields(instruction)
            let second = try vexSource(instruction, fields, bytes: 32)
            let first = ymmWords(instruction.vexRegister)
            var words = [UInt64](repeating: 0, count: 4)
            for half in 0..<2 {
                let select = Int(instruction.immediate >> UInt64(4 * half)) & 0xF
                guard select & 8 == 0 else { continue }
                let source = select & 2 != 0 ? second : first
                words[2 * half] = source[2 * (select & 1)]
                words[2 * half + 1] = source[2 * (select & 1) + 1]
            }
            setYMMWords(fields.reg, words)

        // `vpermq`, `vpermpd` : quatre mots choisis par l'immédiat.
        case (.threeByte3A, 0x00) where w1 && wide, (.threeByte3A, 0x01) where w1 && wide:
            guard instruction.vexRegister == 0 else { return false }
            let fields = try decodeFields(instruction)
            let source = try vexSource(instruction, fields, bytes: 32)
            setYMMWords(fields.reg, (0..<4).map { source[Int(instruction.immediate >> UInt64(2 * $0)) & 3] })

        // `vpermd`, `vpermps` : huit mots de trente-deux bits, choisis par `vvvv`.
        case (.threeByte38, 0x36) where !w1 && wide, (.threeByte38, 0x16) where !w1 && wide:
            let fields = try decodeFields(instruction)
            let source = try vexSource(instruction, fields, bytes: 32)
            let control = ymmWords(instruction.vexRegister)
            var words = [UInt64](repeating: 0, count: 4)
            for index in 0..<8 {
                let pick = Int(Self.element(control, index, 32) & 7)
                Self.setElement(&words, index, 32, Self.element(source, pick, 32))
            }
            setYMMWords(fields.reg, words)

        // `vpermilps`, `vpermilpd` : dans chaque moitié, par un registre ou
        // par l'immédiat.
        case (.threeByte38, 0x0C) where !w1, (.threeByte38, 0x0D) where !w1:
            let fields = try decodeFields(instruction)
            let control = try vexSource(instruction, fields, bytes: 8 * wordCount)
            let source = ymmWords(instruction.vexRegister)
            setYMMWords(fields.reg, Self.permuteInHalves(source, wordCount, double: opcode == 0x0D) { index in
                opcode == 0x0D ? Int(Self.element(control, index, 64) >> 1) & 1 : Int(Self.element(control, index, 32)) & 3
            })
        case (.threeByte3A, 0x04) where !w1, (.threeByte3A, 0x05) where !w1:
            guard instruction.vexRegister == 0 else { return false }
            let fields = try decodeFields(instruction)
            let source = try vexSource(instruction, fields, bytes: 8 * wordCount)
            let immediate = Int(instruction.immediate)
            setYMMWords(fields.reg, Self.permuteInHalves(source, wordCount, double: opcode == 0x05) { index in
                opcode == 0x05 ? immediate >> index & 1 : immediate >> (2 * (index % 4)) & 3
            })

        // `vpblendd` : chaque mot de trente-deux bits de `vvvv` ou de `r/m`.
        case (.threeByte3A, 0x02) where !w1:
            let fields = try decodeFields(instruction)
            let second = try vexSource(instruction, fields, bytes: 8 * wordCount)
            var words = Array(ymmWords(instruction.vexRegister).prefix(wordCount))
            for index in 0..<2 * wordCount where instruction.immediate >> UInt64(index) & 1 != 0 {
                Self.setElement(&words, index, 32, Self.element(second, index, 32))
            }
            setYMMWords(fields.reg, words)

        // `vblendvps`, `vblendvpd`, `vpblendvb` : le masque dans un quatrième
        // registre, nommé par les quatre bits hauts de l'immédiat.
        case (.threeByte3A, 0x4A) where !w1, (.threeByte3A, 0x4B) where !w1, (.threeByte3A, 0x4C) where !w1:
            let fields = try decodeFields(instruction)
            let second = try vexSource(instruction, fields, bytes: 8 * wordCount)
            let mask = ymmWords(Int(instruction.immediate >> 4) & 0xF)
            var words = Array(ymmWords(instruction.vexRegister).prefix(wordCount))
            let bits = opcode == 0x4A ? 32 : opcode == 0x4B ? 64 : 8
            for index in 0..<(64 * wordCount / bits) where Self.element(mask, index, bits) >> UInt64(bits - 1) != 0 {
                Self.setElement(&words, index, bits, Self.element(second, index, bits))
            }
            setYMMWords(fields.reg, words)

        // Les décalages par élément : `vpsllv*`, `vpsrlv*`, `vpsravd`.
        case (.threeByte38, 0x45), (.threeByte38, 0x47), (.threeByte38, 0x46) where !w1:
            let fields = try decodeFields(instruction)
            let counts = try vexSource(instruction, fields, bytes: 8 * wordCount)
            let values = ymmWords(instruction.vexRegister)
            let bits = w1 ? 64 : 32
            var words = [UInt64](repeating: 0, count: wordCount)
            for index in 0..<(64 * wordCount / bits) {
                let value = Self.element(values, index, bits)
                let count = Self.element(counts, index, bits)
                let result: UInt64
                switch opcode {
                case 0x47: result = count >= UInt64(bits) ? 0 : value << count
                case 0x45: result = count >= UInt64(bits) ? 0 : value >> count
                default:
                    let signed = Int64(Int32(truncatingIfNeeded: value))
                    result = UInt64(bitPattern: signed >> Int64(min(count, 31)))
                }
                Self.setElement(&words, index, bits, result)
            }
            setYMMWords(fields.reg, words)

        // Les élargissements sur 256 bits : `vpmovsx*`, `vpmovzx*`.
        case (.threeByte38, 0x20...0x25) where wide, (.threeByte38, 0x30...0x35) where wide:
            guard instruction.vexRegister == 0 else { return false }
            let (from, to) = [(8, 16), (8, 32), (8, 64), (16, 32), (16, 64), (32, 64)][Int(opcode & 0x0F)]
            let count = 256 / to
            let fields = try decodeFields(instruction)
            let source = try vexSource(instruction, fields, bytes: count * from / 8)
            let signed = opcode < 0x30
            var words = [UInt64](repeating: 0, count: 4)
            for index in 0..<count {
                var value = Self.element(source, index, from)
                if signed, value >> UInt64(from - 1) != 0 { value |= ~0 << UInt64(from) }
                Self.setElement(&words, index, to, value)
            }
            setYMMWords(fields.reg, words)

        default:
            return false
        }
        return true
    }

    private mutating func broadcast(_ instruction: X86Instruction, bits: Int, _ wordCount: Int) throws {
        guard instruction.vexRegister == 0 else { throw Self.vectorRefusal() }
        let fields = try decodeFields(instruction)
        let source = try vexSource(instruction, fields, bytes: bits / 8)
        let value = Self.element(source, 0, bits)
        var words = [UInt64](repeating: 0, count: wordCount)
        for index in 0..<(64 * wordCount / bits) { Self.setElement(&words, index, bits, value) }
        setYMMWords(fields.reg, words)
    }

    /// Chaque élément pris dans **sa** moitié, à l'indice que `pick` donne.
    private static func permuteInHalves(_ source: [UInt64], _ wordCount: Int, double: Bool,
                                        _ pick: (Int) -> Int) -> [UInt64] {
        let bits = double ? 64 : 32
        let perHalf = 128 / bits
        var words = [UInt64](repeating: 0, count: wordCount)
        for index in 0..<(64 * wordCount / bits) {
            let half = index / perHalf
            setElement(&words, index, bits, element(source, half * perHalf + pick(index), bits))
        }
        return words
    }
}
