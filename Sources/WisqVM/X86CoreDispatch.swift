import Foundation

// Quelle instruction fait quoi. La forme est déjà lue par `X86Decoder` ; ici on
// ne fait que choisir l'opération et lui donner ses opérandes.
extension X86Core {
    /// La table d'un octet.
    mutating func oneByte(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        switch opcode {
        // Les huit opérations arithmétiques, six formes chacune, six fois.
        case 0x00...0x3D where opcode & 0x07 <= 5:
            let index = Int(opcode >> 3)
            let form = Int(opcode & 0x07)
            let byteForm = form == 0 || form == 2 || form == 4
            let size = Self.operandSize(instruction, byteForm: byteForm)
            switch form {
            case 0, 1:  // r/m ← r/m op reg
                let fields = try Self.fields(instruction, size: size)
                let result = arithmetic(index, try readRM(fields, size), readReg(fields, size), size)
                if let result { try writeRM(fields, size, result) }
            case 2, 3:  // reg ← reg op r/m
                let fields = try Self.fields(instruction, size: size)
                let result = arithmetic(index, readReg(fields, size), try readRM(fields, size), size)
                if let result { writeReg(fields, size, result) }
            default:  // l'accumulateur et un immédiat
                let value = read(0, size, highByte: false)
                let result = arithmetic(index, value, Self.immediate(instruction, size), size)
                if let result { write(0, size, highByte: false, result) }
            }

        // MOVSXD : la seule instruction dont le nom dit ce que fait la moitié
        // du jeu d'instructions x86-64 sans le dire.
        case 0x63:
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, Self.signExtend(try readRM(fields, 4), 4) & Self.mask(size))

        case 0x69, 0x6B:  // IMUL à trois opérandes
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, multiplyTruncating(
                try readRM(fields, size), Self.immediate(instruction, size), size))

        // Le groupe 1 : la même arithmétique, avec un immédiat.
        case 0x80, 0x81, 0x83:
            let size = Self.operandSize(instruction, byteForm: opcode == 0x80)
            let fields = try Self.fields(instruction, size: size)
            let result = arithmetic(
                Int((instruction.modrm! >> 3) & 0x07), try readRM(fields, size),
                Self.immediate(instruction, size), size)
            if let result { try writeRM(fields, size, result) }

        case 0x84, 0x85:  // TEST : un ET dont personne ne garde le résultat.
            let size = Self.operandSize(instruction, byteForm: opcode == 0x84)
            let fields = try Self.fields(instruction, size: size)
            _ = logic(try readRM(fields, size) & readReg(fields, size), size)

        case 0x86, 0x87:  // XCHG
            let size = Self.operandSize(instruction, byteForm: opcode == 0x86)
            let fields = try Self.fields(instruction, size: size)
            let first = try readRM(fields, size)
            let second = readReg(fields, size)
            try writeRM(fields, size, second)
            writeReg(fields, size, first)

        case 0x88, 0x89:  // MOV r/m ← r
            let size = Self.operandSize(instruction, byteForm: opcode == 0x88)
            let fields = try Self.fields(instruction, size: size)
            try writeRM(fields, size, readReg(fields, size))

        case 0x8A, 0x8B:  // MOV r ← r/m
            let size = Self.operandSize(instruction, byteForm: opcode == 0x8A)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, try readRM(fields, size))

        case 0x8D:  // LEA : calcule une adresse et ne la lit pas.
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, try effectiveAddress(instruction, fields) & Self.mask(size))

        case 0x90...0x97:  // XCHG rAX, r — dont 0x90, qui est NOP.
            let size = Self.operandSize(instruction, byteForm: false)
            let rex = instruction.rex ?? 0
            let other = Int((rex & 0x01) << 3 | (opcode & 0x07))
            guard other != 0 else { break }  // xchg rax, rax ne fait rien
            let first = read(0, size, highByte: false)
            write(0, size, highByte: false, read(other, size, highByte: false))
            write(other, size, highByte: false, first)

        case 0x98:  // CBW / CWDE / CDQE : l'accumulateur étendu au signe.
            let size = Self.operandSize(instruction, byteForm: false)
            write(0, size, highByte: false,
                  Self.signExtend(read(0, size / 2, highByte: false), size / 2) & Self.mask(size))

        case 0x99:  // CWD / CDQ / CQO : le signe de l'accumulateur rempli dans DX.
            let size = Self.operandSize(instruction, byteForm: false)
            let negative = read(0, size, highByte: false) & Self.signBit(size) != 0
            write(2, size, highByte: false, negative ? Self.mask(size) : 0)

        case 0xA8, 0xA9:  // TEST accumulateur, immédiat
            let size = Self.operandSize(instruction, byteForm: opcode == 0xA8)
            _ = logic(read(0, size, highByte: false) & Self.immediate(instruction, size), size)

        case 0xB0...0xB7:  // MOV r8, imm8
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            let high = instruction.rex == nil && (4...7).contains(Int(opcode & 0x07))
            write(high ? index : index, 1, highByte: high, instruction.immediate & 0xFF)

        case 0xB8...0xBF:  // MOV r, imm — le seul immédiat de huit octets.
            let size = Self.operandSize(instruction, byteForm: false)
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            write(index, size, highByte: false, instruction.immediate & Self.mask(size))

        case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:  // décalages et rotations
            let byteForm = opcode == 0xC0 || opcode == 0xD0 || opcode == 0xD2
            let size = Self.operandSize(instruction, byteForm: byteForm)
            let fields = try Self.fields(instruction, size: size)
            let count: UInt64
            switch opcode {
            case 0xC0, 0xC1: count = instruction.immediate & 0xFF
            case 0xD0, 0xD1: count = 1
            default: count = registers[1] & 0xFF  // CL
            }
            let kind = Int((instruction.modrm! >> 3) & 0x07)
            let value = try readRM(fields, size)
            let result = kind <= 3
                ? rotate(kind, value, count, size)
                : shift(kind, value, count, size)
            try writeRM(fields, size, result)

        case 0xC6, 0xC7:  // MOV r/m, imm
            let size = Self.operandSize(instruction, byteForm: opcode == 0xC6)
            let fields = try Self.fields(instruction, size: size)
            try writeRM(fields, size, Self.immediate(instruction, size))

        case 0xF5: flags ^= Flag.carry            // CMC
        case 0xF8: set(Flag.carry, false)         // CLC
        case 0xF9: set(Flag.carry, true)          // STC

        case 0xF6, 0xF7:  // le groupe 3 : TEST, NOT, NEG, et les quatre longues
            let size = Self.operandSize(instruction, byteForm: opcode == 0xF6)
            let fields = try Self.fields(instruction, size: size)
            let value = try readRM(fields, size)
            switch (instruction.modrm! >> 3) & 0x07 {
            case 0, 1: _ = logic(value & Self.immediate(instruction, size), size)
            case 2: try writeRM(fields, size, ~value & Self.mask(size))  // NOT : aucun drapeau
            case 3: try writeRM(fields, size, subtract(0, value, size))  // NEG
            case 4: multiplyUnsigned(value, size)
            case 5: multiplySigned(value, size)
            case 6: try divideUnsigned(value, size)
            default: try divideSigned(value, size)
            }

        case 0xFE, 0xFF:  // INC et DEC, qui ne touchent pas à la retenue
            let size = Self.operandSize(instruction, byteForm: opcode == 0xFE)
            let fields = try Self.fields(instruction, size: size)
            let value = try readRM(fields, size)
            let kept = flags & Flag.carry
            let result = (instruction.modrm! >> 3) & 0x07 == 0
                ? add(value, 1, size)
                : subtract(value, 1, size)
            flags = (flags & ~Flag.carry) | kept
            try writeRM(fields, size, result)

        default:
            throw Fault.unsupported("l'opcode \(String(format: "%02X", opcode))")
        }
    }

    /// La table `0F`.
    mutating func twoByte(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        switch opcode {
        case 0x40...0x4F:  // CMOVcc : une écriture qui n'a peut-être pas lieu
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            // Le mouvement conditionnel écrit **toujours** en 32 bits, même
            // quand la condition est fausse : le haut du registre est mis à
            // zéro dans les deux cas. C'est une conséquence de la règle
            // d'écriture 32 bits, pas une exception à elle.
            let value = condition(opcode) ? try readRM(fields, size) : readReg(fields, size)
            writeReg(fields, size, value)

        case 0x90...0x9F:  // SETcc
            let fields = try Self.fields(instruction, size: 1)
            try writeRM(fields, 1, condition(opcode) ? 1 : 0)

        case 0xA3, 0xAB, 0xB3, 0xBB:  // BT, BTS, BTR, BTC — le bit est nommé par un registre
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let offset = readReg(fields, size) & UInt64(8 * size - 1)
            try bit(Int((opcode >> 3) & 0x03), fields, size, offset)

        case 0xBA:  // le groupe 8 : les mêmes, avec un immédiat
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let offset = (instruction.immediate & 0xFF) & UInt64(8 * size - 1)
            try bit(Int((instruction.modrm! >> 3) & 0x07) - 4, fields, size, offset)

        case 0xA4, 0xA5, 0xAC, 0xAD:  // SHLD et SHRD
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let count = (opcode == 0xA4 || opcode == 0xAC)
                ? (instruction.immediate & 0xFF)
                : (registers[1] & 0xFF)
            let destination = try readRM(fields, size)
            let result = doubleShift(
                left: opcode < 0xAC, destination, readReg(fields, size), count, size)
            // Un compte nul ne change ni la valeur ni les drapeaux — et pourtant
            // l'écriture a lieu. Sur une opération de 32 bits, elle met à zéro
            // les 32 bits du haut, ce qui **est** un changement. Le processeur
            // le fait ; le sauter était le dernier désaccord de l'oracle.
            try writeRM(fields, size, result ?? destination)

        case 0xAF:  // IMUL r, r/m — la forme qui ne garde que la moitié basse
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, multiplyTruncating(readReg(fields, size),
                                                      try readRM(fields, size), size))

        case 0xB6, 0xB7:  // MOVZX
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            writeReg(fields, size, try readRM(fields, opcode == 0xB6 ? 1 : 2))

        case 0xBE, 0xBF:  // MOVSX
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let source = opcode == 0xBE ? 1 : 2
            writeReg(fields, size, Self.signExtend(try readRM(fields, source), source)
                & Self.mask(size))

        case 0xB8 where instruction.legacyPrefixes.contains(0xF3):  // POPCNT
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let source = try readRM(fields, size)
            writeReg(fields, size, UInt64(source.nonzeroBitCount))
            flags &= ~Flag.arithmetic
            set(Flag.zero, source == 0)

        case 0xBC, 0xBD:  // BSF et BSR : le premier bit à un, par un bout ou l'autre
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try Self.fields(instruction, size: size)
            let source = try readRM(fields, size)
            set(Flag.zero, source == 0)
            // Quand la source est nulle, la destination est *indéfinie* et le
            // processeur la laisse telle quelle. On fait pareil.
            if source != 0 {
                let index = opcode == 0xBC
                    ? source.trailingZeroBitCount
                    : (8 * size - 1 - source.leadingZeroBitCount + (64 - 8 * size))
                writeReg(fields, size, UInt64(index))
            }

        default:
            throw Fault.unsupported("l'opcode 0F \(String(format: "%02X", opcode))")
        }
    }

    /// L'adresse qu'un ModRM désigne, pour `LEA` seulement — rien ne la lit.
    func effectiveAddress(_ instruction: X86Instruction, _ fields: Fields) throws -> UInt64 {
        guard let modrm = instruction.modrm, fields.mod != 0b11 else {
            throw Fault.unsupported("LEA sur un registre")
        }
        let rex = instruction.rex ?? 0
        let displacement = UInt64(bitPattern: instruction.displacement)
        if modrm & 0x07 == 0b100, let sib = instruction.sib {
            let index = Int((rex & 0x02) << 2 | ((sib >> 3) & 0x07))
            let base = Int((rex & 0x01) << 3 | (sib & 0x07))
            // L'index 100 sans REX.X veut dire « pas d'index » : c'est ainsi
            // qu'on écrit une adresse sans registre d'échelle.
            let scaled = index == 4 ? 0 : registers[index] << UInt64((sib >> 6) & 0x03)
            let baseValue = (fields.mod == 0 && (sib & 0x07) == 0b101) ? 0 : registers[base]
            return baseValue &+ scaled &+ displacement
        }
        if fields.mod == 0 && modrm & 0x07 == 0b101 {
            // Relatif à RIP : l'adresse suit l'instruction entière.
            return rip &+ UInt64(instruction.length) &+ displacement
        }
        return registers[fields.rm] &+ displacement
    }

    /// BT, BTS, BTR, BTC : lire le bit, puis éventuellement le changer.
    mutating func bit(_ kind: Int, _ fields: Fields, _ size: Int, _ offset: UInt64) throws {
        let value = try readRM(fields, size)
        let selected = (value >> offset) & 1
        set(Flag.carry, selected != 0)
        switch kind {
        case 1: try writeRM(fields, size, value | (1 << offset))    // BTS
        case 2: try writeRM(fields, size, value & ~(1 << offset))   // BTR
        case 3: try writeRM(fields, size, value ^ (1 << offset))    // BTC
        default: break                                              // BT ne change rien
        }
    }
}
