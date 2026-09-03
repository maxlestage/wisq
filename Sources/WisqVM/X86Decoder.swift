import Foundation

/// Où finit une instruction x86-64, et de quelles pièces elle est faite.
///
/// C'est la tranche 2 du lot 7 (`docs/ROADMAP.md`), et c'est délibérément le
/// premier morceau : sur une architecture à longueur variable, **tout** dépend
/// de savoir où finit l'instruction courante. Un cœur qui se trompe d'un octet
/// ne décode pas mal la suivante, il décode du bruit, et il le fait
/// silencieusement.
///
/// Rien ne s'exécute ici. On lit la forme : préfixes, REX ou VEX ou EVEX,
/// octet(s) d'opcode, ModRM, SIB, déplacement, immédiat. Ce qu'une
/// instruction *fait* viendra après ; où elle finit se prouve maintenant,
/// contre un désassembleur de référence sur un vrai corpus.
public struct X86Instruction: Equatable, Sendable {
    /// Les préfixes hérités, dans l'ordre où ils ont été lus.
    public let legacyPrefixes: [UInt8]
    /// L'octet REX, quand il y en a un.
    public let rex: UInt8?
    /// Les octets VEX ou EVEX au complet (2, 3 ou 4), vides sans eux.
    public let vex: [UInt8]
    /// Dans quelle table l'opcode se lit.
    public let map: OpcodeMap
    /// L'octet d'opcode lui-même, sans les échappements qui l'ont désigné.
    public let opcode: UInt8
    public let modrm: UInt8?
    public let sib: UInt8?
    public let displacementBytes: Int
    public let immediateBytes: Int
    /// Le nombre d'octets que l'instruction occupe en tout.
    public let length: Int

    /// La table où l'opcode se lit. Les échappements hérités (`0F`, `0F 38`,
    /// `0F 3A`) et le champ `mmmmm` d'un VEX ou d'un EVEX désignent les mêmes
    /// tables ; c'est pour ça qu'un préfixe vectoriel ne double pas le travail.
    public enum OpcodeMap: Equatable, Sendable {
        case oneByte
        case twoByte
        case threeByte38
        case threeByte3A
        /// Une table que ce décodeur ne connaît pas — un `mmmmm` réservé.
        case unknown(UInt8)
    }

    /// Une instruction x86 ne peut pas dépasser quinze octets ; le processeur
    /// lui-même refuse au-delà. C'est la borne qui empêche une suite de
    /// préfixes de faire tourner la boucle indéfiniment.
    public static let maximumLength = 15
}

public enum X86DecodeError: Error, Equatable {
    /// Les octets s'arrêtent au milieu de l'instruction.
    case truncated
    /// Un opcode qui n'existe pas en mode 64 bits, ou que ce décodeur ne
    /// connaît pas encore. Nommé, avec sa table.
    case unsupportedOpcode(map: X86Instruction.OpcodeMap, opcode: UInt8)
    /// Plus de quinze octets : le processeur refuserait aussi.
    case tooLong
}

/// Le décodeur de forme. Sans état, donc utilisable de partout.
public enum X86Decoder {
    /// Les préfixes hérités, par groupe. Un préfixe peut être répété et les
    /// groupes peuvent venir dans n'importe quel ordre : seule la borne des
    /// quinze octets les limite.
    static let legacyPrefixes: Set<UInt8> = [
        0xF0, 0xF2, 0xF3,  // LOCK, REPNE, REP
        0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65,  // segments
        0x66,  // taille d'opérande
        0x67,  // taille d'adresse
    ]

    /// Ce qu'un immédiat pèse. La distinction qui compte est entre une taille
    /// fixe et une taille qui suit l'opérande — c'est là que `0x66` et `REX.W`
    /// entrent en jeu, et c'est la source d'erreur classique.
    enum Immediate: Equatable {
        case none
        /// `ib` — un octet, toujours.
        case byte
        /// `iw` — deux octets, toujours.
        case word
        /// `id` — quatre octets, toujours. Les sauts proches en font partie :
        /// en mode 64 bits, `0x66` ne les raccourcit pas.
        case dword
        /// `iz` — quatre octets, deux avec `0x66`. Jamais huit : un immédiat
        /// de 32 bits est étendu au signe, il ne grandit pas avec `REX.W`.
        case operandSized
        /// `io` — huit octets avec `REX.W`, sinon la règle `iz`. Le seul cas
        /// est `movabs`.
        case operandSizedOrEight
        /// `ENTER` : un mot puis un octet.
        case wordThenByte
        /// Une adresse absolue (`moffs`) : huit octets en mode 64 bits,
        /// quatre avec le préfixe de taille d'adresse.
        case absoluteAddress
    }

    /// La forme d'un opcode : porte-t-il un ModRM, et que traîne-t-il derrière.
    struct Shape: Equatable {
        let hasModRM: Bool
        let immediate: Immediate
        init(_ hasModRM: Bool, _ immediate: Immediate = .none) {
            self.hasModRM = hasModRM
            self.immediate = immediate
        }
    }

    /// L'instruction qui commence à `offset`, ou l'erreur qui dit pourquoi
    /// non.
    public static func decode(_ bytes: [UInt8], at offset: Int = 0) throws -> X86Instruction {
        var index = offset
        func next() throws -> UInt8 {
            guard index < bytes.count else { throw X86DecodeError.truncated }
            guard index - offset < X86Instruction.maximumLength else {
                throw X86DecodeError.tooLong
            }
            defer { index += 1 }
            return bytes[index]
        }
        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        // 1. Les préfixes hérités.
        var prefixes: [UInt8] = []
        while let byte = peek(), legacyPrefixes.contains(byte) {
            prefixes.append(try next())
        }

        // 2. Un préfixe vectoriel, ou REX, ou rien. Les trois s'excluent : REX
        // doit être le dernier octet avant l'opcode, et VEX/EVEX portent
        // eux-mêmes ce que REX dirait.
        var rex: UInt8?
        var vexBytes: [UInt8] = []
        var map = X86Instruction.OpcodeMap.oneByte
        var wideOperand = false

        switch peek() {
        case 0xC5:  // VEX à deux octets : la table est toujours 0F.
            vexBytes = [try next(), try next()]
            map = .twoByte
        case 0xC4:  // VEX à trois octets : `mmmmm` désigne la table.
            let escape = try next()
            let second = try next()
            let third = try next()
            vexBytes = [escape, second, third]
            map = mapFor(mmmmm: second & 0x1F)
            wideOperand = third & 0x80 != 0  // VEX.W
        case 0x62:  // EVEX : quatre octets, `mmm` sur les mêmes tables.
            let escape = try next()
            let p0 = try next()
            let p1 = try next()
            let p2 = try next()
            vexBytes = [escape, p0, p1, p2]
            map = mapFor(mmmmm: p0 & 0x07)
            wideOperand = p1 & 0x80 != 0  // EVEX.W
        case .some(let byte) where 0x40...0x4F ~= byte:
            _ = try next()
            rex = byte
            wideOperand = (byte & 0x08) != 0  // REX.W
        default:
            break
        }

        // 3. L'opcode. Sans préfixe vectoriel, les échappements se lisent ici.
        let opcode: UInt8
        if vexBytes.isEmpty {
            var byte = try next()
            if byte == 0x0F {
                byte = try next()
                switch byte {
                case 0x38:
                    map = .threeByte38
                    byte = try next()
                case 0x3A:
                    map = .threeByte3A
                    byte = try next()
                default:
                    map = .twoByte
                }
            }
            opcode = byte
        } else {
            opcode = try next()
        }

        // 4. La forme de cet opcode dans cette table.
        let shape = try self.shape(map: map, opcode: opcode, vector: !vexBytes.isEmpty)

        // 5. ModRM, et ce qu'il entraîne.
        var modrm: UInt8?
        var sib: UInt8?
        var displacementBytes = 0
        if shape.hasModRM {
            let byte = try next()
            modrm = byte
            let mod = byte >> 6
            let rm = byte & 0x07
            if mod != 0b11 {
                if rm == 0b100 {
                    let sibByte = try next()
                    sib = sibByte
                    // Une base à 101 sans déplacement dans ModRM veut dire
                    // « pas de base, un déplacement de quatre octets ».
                    if mod == 0 && (sibByte & 0x07) == 0b101 {
                        displacementBytes = 4
                    }
                }
                switch mod {
                case 0b00:
                    // rm = 101 est le relatif à RIP en mode 64 bits : quatre
                    // octets, et pas un registre de base.
                    if rm == 0b101 { displacementBytes = 4 }
                case 0b01: displacementBytes = 1
                case 0b10: displacementBytes = 4
                default: break
                }
            }
            for _ in 0..<displacementBytes { _ = try next() }
        }

        // 6. L'immédiat.
        let hasOperandSizePrefix = prefixes.contains(0x66)
        let hasAddressSizePrefix = prefixes.contains(0x67)
        var immediateBytes = 0
        switch immediate(for: shape, opcode: opcode, map: map, modrm: modrm) {
        case .none: immediateBytes = 0
        case .byte: immediateBytes = 1
        case .word: immediateBytes = 2
        case .dword: immediateBytes = 4
        case .operandSized: immediateBytes = hasOperandSizePrefix ? 2 : 4
        case .operandSizedOrEight:
            immediateBytes = wideOperand ? 8 : (hasOperandSizePrefix ? 2 : 4)
        case .wordThenByte: immediateBytes = 3
        case .absoluteAddress: immediateBytes = hasAddressSizePrefix ? 4 : 8
        }
        for _ in 0..<immediateBytes { _ = try next() }

        let length = index - offset
        guard length <= X86Instruction.maximumLength else { throw X86DecodeError.tooLong }
        return X86Instruction(
            legacyPrefixes: prefixes, rex: rex, vex: vexBytes, map: map, opcode: opcode,
            modrm: modrm, sib: sib, displacementBytes: displacementBytes,
            immediateBytes: immediateBytes, length: length)
    }

    /// La longueur seule, quand c'est tout ce qu'on veut savoir.
    public static func length(of bytes: [UInt8], at offset: Int = 0) throws -> Int {
        try decode(bytes, at: offset).length
    }

    static func mapFor(mmmmm: UInt8) -> X86Instruction.OpcodeMap {
        switch mmmmm {
        case 1: return .twoByte
        case 2: return .threeByte38
        case 3: return .threeByte3A
        default: return .unknown(mmmmm)
        }
    }

    /// Les immédiats qui dépendent du champ `reg` de ModRM plutôt que du seul
    /// opcode. Il y en a peu, et ils sont exactement les pièges : `F6` et `F7`
    /// portent un immédiat pour `TEST` et rien pour les six autres opérations
    /// du même octet.
    static func immediate(
        for shape: Shape, opcode: UInt8, map: X86Instruction.OpcodeMap, modrm: UInt8?
    ) -> Immediate {
        guard map == .oneByte, let modrm else { return shape.immediate }
        let reg = (modrm >> 3) & 0x07
        switch opcode {
        case 0xF6: return reg <= 1 ? .byte : .none
        case 0xF7: return reg <= 1 ? .operandSized : .none
        default: return shape.immediate
        }
    }

    static func shape(
        map: X86Instruction.OpcodeMap, opcode: UInt8, vector: Bool
    ) throws -> Shape {
        switch map {
        case .oneByte:
            guard let shape = oneByteMap[Int(opcode)] else {
                throw X86DecodeError.unsupportedOpcode(map: map, opcode: opcode)
            }
            return shape
        case .twoByte:
            guard let shape = twoByteMap[Int(opcode)] else {
                throw X86DecodeError.unsupportedOpcode(map: map, opcode: opcode)
            }
            return shape
        case .threeByte38:
            // Toute la table `0F 38` porte un ModRM et rien derrière.
            return Shape(true)
        case .threeByte3A:
            // Toute la table `0F 3A` porte un ModRM et un octet immédiat.
            return Shape(true, .byte)
        case .unknown:
            throw X86DecodeError.unsupportedOpcode(map: map, opcode: opcode)
        }
    }

    /// La table d'un octet, en mode 64 bits. `nil` veut dire « pas d'opcode
    /// ici » — les octets que le mode 64 bits a repris (les anciens `PUSH ES`,
    /// le BCD) ne sont pas décodés en silence.
    static let oneByteMap: [Shape?] = {
        var table = [Shape?](repeating: nil, count: 256)
        // Les huit opérations arithmétiques partagent exactement la même
        // disposition sur six octets consécutifs, six fois de suite.
        for base in stride(from: 0x00, through: 0x38, by: 0x08) {
            table[base + 0] = Shape(true)  // /r  r/m8, r8
            table[base + 1] = Shape(true)  // /r  r/m, r
            table[base + 2] = Shape(true)  // /r  r8, r/m8
            table[base + 3] = Shape(true)  // /r  r, r/m
            table[base + 4] = Shape(false, .byte)  // AL, ib
            table[base + 5] = Shape(false, .operandSized)  // eAX, iz
        }
        for opcode in 0x50...0x5F { table[opcode] = Shape(false) }  // PUSH/POP r
        table[0x63] = Shape(true)  // MOVSXD
        table[0x68] = Shape(false, .operandSized)  // PUSH iz
        table[0x69] = Shape(true, .operandSized)  // IMUL /r iz
        table[0x6A] = Shape(false, .byte)  // PUSH ib
        table[0x6B] = Shape(true, .byte)  // IMUL /r ib
        for opcode in 0x6C...0x6F { table[opcode] = Shape(false) }  // INS/OUTS
        for opcode in 0x70...0x7F { table[opcode] = Shape(false, .byte) }  // Jcc rel8
        table[0x80] = Shape(true, .byte)
        table[0x81] = Shape(true, .operandSized)
        table[0x83] = Shape(true, .byte)
        for opcode in 0x84...0x8F { table[opcode] = Shape(true) }  // TEST…LEA…POP
        for opcode in 0x90...0x9F { table[opcode] = Shape(false) }  // XCHG, drapeaux
        for opcode in 0xA0...0xA3 { table[opcode] = Shape(false, .absoluteAddress) }
        for opcode in 0xA4...0xA7 { table[opcode] = Shape(false) }  // MOVS/CMPS
        table[0xA8] = Shape(false, .byte)  // TEST AL, ib
        table[0xA9] = Shape(false, .operandSized)  // TEST eAX, iz
        for opcode in 0xAA...0xAF { table[opcode] = Shape(false) }  // STOS/LODS/SCAS
        for opcode in 0xB0...0xB7 { table[opcode] = Shape(false, .byte) }  // MOV r8, ib
        for opcode in 0xB8...0xBF { table[opcode] = Shape(false, .operandSizedOrEight) }
        table[0xC0] = Shape(true, .byte)  // décalages, ib
        table[0xC1] = Shape(true, .byte)
        table[0xC2] = Shape(false, .word)  // RET iw
        table[0xC3] = Shape(false)  // RET
        table[0xC6] = Shape(true, .byte)  // MOV r/m8, ib
        table[0xC7] = Shape(true, .operandSized)  // MOV r/m, iz
        table[0xC8] = Shape(false, .wordThenByte)  // ENTER
        table[0xC9] = Shape(false)  // LEAVE
        table[0xCA] = Shape(false, .word)  // RETF iw
        table[0xCB] = Shape(false)  // RETF
        table[0xCC] = Shape(false)  // INT3
        table[0xCD] = Shape(false, .byte)  // INT ib
        table[0xCF] = Shape(false)  // IRET
        for opcode in 0xD0...0xD3 { table[opcode] = Shape(true) }  // décalages par 1 ou CL
        table[0xD7] = Shape(false)  // XLAT
        // Le x87 : huit octets qui portent tous un ModRM et rien derrière. Que
        // le second octet prolonge l'opcode quand mod vaut 11 ne change pas la
        // longueur, qui est tout ce qui se décide ici.
        for opcode in 0xD8...0xDF { table[opcode] = Shape(true) }
        for opcode in 0xE0...0xE3 { table[opcode] = Shape(false, .byte) }  // LOOP/JrCXZ
        for opcode in 0xE4...0xE7 { table[opcode] = Shape(false, .byte) }  // IN/OUT ib
        table[0xE8] = Shape(false, .dword)  // CALL rel32
        table[0xE9] = Shape(false, .dword)  // JMP rel32
        table[0xEB] = Shape(false, .byte)  // JMP rel8
        for opcode in 0xEC...0xEF { table[opcode] = Shape(false) }  // IN/OUT DX
        table[0xF1] = Shape(false)  // INT1
        table[0xF4] = Shape(false)  // HLT
        table[0xF5] = Shape(false)  // CMC
        // F6 et F7 : l'immédiat dépend du champ reg, décidé dans `immediate`.
        table[0xF6] = Shape(true, .byte)
        table[0xF7] = Shape(true, .operandSized)
        for opcode in 0xF8...0xFD { table[opcode] = Shape(false) }  // drapeaux
        table[0xFE] = Shape(true)  // INC/DEC r/m8
        table[0xFF] = Shape(true)  // INC/DEC/CALL/JMP/PUSH r/m
        return table
    }()

    /// La table `0F`. Presque tout y porte un ModRM ; ce qui compte est la
    /// petite liste de ceux qui n'en portent pas, et celle de ceux qui traînent
    /// un octet immédiat.
    static let twoByteMap: [Shape?] = {
        var table = [Shape?](repeating: Shape(true), count: 256)
        // Sans ModRM : les instructions système qui n'ont pas d'opérande.
        for opcode in [0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0E, 0x77, 0xA2, 0xAA] {
            table[opcode] = Shape(false)
        }
        for opcode in 0x30...0x37 { table[opcode] = Shape(false) }  // RDTSC etc.
        for opcode in [0xA0, 0xA1, 0xA8, 0xA9] { table[opcode] = Shape(false) }  // PUSH/POP FS,GS
        for opcode in 0xC8...0xCF { table[opcode] = Shape(false) }  // BSWAP
        // Jcc en rel32 : quatre octets, que `0x66` ne raccourcit pas.
        for opcode in 0x80...0x8F { table[opcode] = Shape(false, .dword) }
        // ModRM plus un octet immédiat.
        for opcode in [0x0F, 0x70, 0x71, 0x72, 0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4, 0xC5, 0xC6] {
            table[opcode] = Shape(true, .byte)
        }
        // Ce que le mode 64 bits ne décode pas.
        for opcode in [0x04, 0x0A, 0x0C, 0x24, 0x25, 0x26, 0x27, 0x36, 0x39, 0x3B, 0x3C, 0x3D,
                       0x3E, 0x3F] {
            table[opcode] = nil
        }
        return table
    }()
}
