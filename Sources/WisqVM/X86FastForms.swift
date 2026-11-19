import Foundation

/// **Les formes courtes** : les instructions les plus fréquentes d'un noyau
/// et de ses programmes, reconnues au décodage et exécutées sans passer par
/// les tables générales.
///
/// Mesuré avant d'écrire une ligne, sur le démarrage d'Alpine 6.18 jusqu'à son
/// shell (1,9 milliard d'instructions) : une trentaine de formes font les
/// trois quarts des instructions exécutées — `mov` entre registres ou avec la
/// mémoire, les sauts conditionnels, l'arithmétique entre registres ou avec un
/// immédiat, `lea`, `movzx`, `push`, `pop`, `call`, `ret`. Sous callgrind,
/// chacune coûtait environ deux cent vingt instructions de l'hôte, dont
/// cent trente dans `oneByte` et ses aides : la largeur à retrouver, les
/// champs à redéplier, la forme registre ou mémoire à redécider.
///
/// Une forme courte ne redécide rien : le décodeur a déjà dit laquelle c'est.
/// **Elle ne calcule rien autrement** : les drapeaux sortent des mêmes
/// `arithmetic` et `logic`, la mémoire des mêmes `readRMMemory` et
/// `writeRMMemory`, la pile des mêmes `push` et `pop`. Un test compare, forme
/// par forme et sur des états tirés au hasard, ce chemin et le chemin général
/// (`X86Instruction.generic`) ; et les corpus matériels passent par ici,
/// puisque `perform` y envoie toute instruction qui en porte le code.
///
/// **Seulement le cas simple** : mode 64 bits, aucun préfixe hérité (ni
/// taille, ni adresse, ni segment, ni répétition, ni verrou), pas de VEX.
/// Tout le reste garde son code de table et le chemin d'avant.
extension X86Instruction {
    /// Les codes de `dispatchCode` au-dessus des tables (0 à 5).
    enum FastForm {
        static var base: UInt8 { 16 }
        static var moveToRM: UInt8 { 16 }          // 89 /r, registre ← registre
        static var moveToRegister: UInt8 { 17 }    // 8B /r, registre ← registre
        static var load: UInt8 { 18 }              // 8B /r, registre ← mémoire
        static var store: UInt8 { 19 }             // 89 /r, mémoire ← registre
        static var jumpIf: UInt8 { 20 }            // 70–7F, 0F 80–8F
        static var jump: UInt8 { 21 }              // EB, E9
        static var arithmeticToRM: UInt8 { 22 }    // 01, 09 … 39, entre registres
        static var arithmeticToRegister: UInt8 { 23 }  // 03, 0B … 3B, entre registres
        static var arithmeticFromMemory: UInt8 { 24 }  // 03, 0B … 3B, registre op mémoire
        static var arithmeticImmediate: UInt8 { 25 }   // 81, 83, registre op immédiat
        static var test: UInt8 { 26 }              // 85, entre registres
        static var loadAddress: UInt8 { 27 }       // 8D
        static var zeroExtendByte: UInt8 { 28 }    // 0F B6, depuis un registre
        static var zeroExtendWord: UInt8 { 29 }    // 0F B7, depuis un registre
        static var loadByte: UInt8 { 30 }          // 0F B6, depuis la mémoire
        static var loadWord: UInt8 { 31 }          // 0F B7, depuis la mémoire
        static var push: UInt8 { 32 }              // 50–57
        static var pop: UInt8 { 33 }               // 58–5F
        static var call: UInt8 { 34 }              // E8
        static var ret: UInt8 { 35 }               // C3
        static var compareMemory: UInt8 { 36 }     // 39 /r, mémoire comparée à un registre
    }

    /// La forme courte d'une instruction **sans préfixe hérité, en mode
    /// 64 bits et hors VEX**, ou `nil` si elle n'en a pas.
    static func fastForm(mapCode: UInt8, opcode: UInt8, modrm: UInt8?) -> UInt8? {
        if mapCode == 0 {
            switch opcode {
            case 0x70...0x7F: return FastForm.jumpIf
            case 0xEB, 0xE9: return FastForm.jump
            case 0xE8: return FastForm.call
            case 0xC3: return FastForm.ret
            case 0x50...0x57: return FastForm.push
            case 0x58...0x5F: return FastForm.pop
            default: break
            }
            guard let modrm else { return nil }
            let register = modrm >= 0xC0
            switch opcode {
            case 0x89: return register ? FastForm.moveToRM : FastForm.store
            case 0x8B: return register ? FastForm.moveToRegister : FastForm.load
            case 0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31:
                return register ? FastForm.arithmeticToRM : nil
            case 0x39: return register ? FastForm.arithmeticToRM : FastForm.compareMemory
            case 0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B:
                return register ? FastForm.arithmeticToRegister : FastForm.arithmeticFromMemory
            case 0x81, 0x83: return register ? FastForm.arithmeticImmediate : nil
            case 0x85: return register ? FastForm.test : nil
            // `lea` d'un registre n'existe pas : la table générale le refuse.
            case 0x8D: return register ? nil : FastForm.loadAddress
            default: return nil
            }
        }
        guard mapCode == 1 else { return nil }
        switch opcode {
        case 0x80...0x8F: return FastForm.jumpIf
        case 0xB6: return modrm.map { $0 >= 0xC0 ? FastForm.zeroExtendByte : FastForm.loadByte }
        case 0xB7: return modrm.map { $0 >= 0xC0 ? FastForm.zeroExtendWord : FastForm.loadWord }
        default: return nil
        }
    }

    /// Le code de la table générale : celui que l'instruction portait avant
    /// les formes courtes.
    var tableCode: UInt8 { vexCount != 0 ? 4 : mapCode < 4 ? mapCode : 5 }

    /// **La même instruction, par le chemin général.** Pour le test qui
    /// compare les deux chemins, et pour lui seul : rien d'autre ne doit
    /// avoir à choisir.
    var generic: X86Instruction {
        var copy = self
        copy.dispatchCode = tableCode
        return copy
    }

    /// Vrai si cette instruction s'exécute par une forme courte.
    var isFastForm: Bool { dispatchCode >= FastForm.base }
}

extension X86Core {
    /// L'adresse d'un opérande en mémoire d'une forme courte : celle de
    /// `memoryAddress`, sans segment (aucun préfixe) ni repli à trente-deux
    /// bits (mode 64 bits), lue dans l'instruction là où elle est rangée.
    @inline(__always)
    mutating func fastAddress(_ instruction: UnsafePointer<X86Instruction>) -> UInt64 {
        var address = UInt64(bitPattern: instruction.pointee.displacement)
        let base = instruction.pointee.baseField
        if base < 16 {
            address &+= registers.read(Int(base))
        } else if base == X86Instruction.ripRelative {
            address &+= rip &+ UInt64(instruction.pointee.lengthByte)
        }
        let index = instruction.pointee.indexAndScale & 0x1F
        if index < 16 {
            address &+= registers.read(Int(index)) &<< UInt64(instruction.pointee.indexAndScale >> 5)
        }
        return address
    }

    /// Exécute une forme courte. **Rend vrai si elle a posé RIP elle-même** ;
    /// sinon c'est à l'appelant d'avancer de la longueur de l'instruction,
    /// comme après `perform`.
    ///
    /// L'instruction est lue **là où elle est** — dans sa case du cache de
    /// décodage — et pas recopiée : la passer par valeur coûtait quarante
    /// octets copiés à chaque instruction de l'invité.
    mutating func performFast(_ instruction: UnsafePointer<X86Instruction>) throws -> Bool {
        typealias Form = X86Instruction.FastForm
        let size = Int(instruction.pointee.wideOperandSize)
        let reg = Int(instruction.pointee.regField)
        let rm = Int(instruction.pointee.rmField)
        switch instruction.pointee.dispatchCode {
        case Form.moveToRM:
            registers[rm] = registers.read(reg) & Self.mask(size)
        case Form.moveToRegister:
            registers[reg] = registers.read(rm) & Self.mask(size)
        case Form.load:
            lastAddress = fastAddress(instruction)
            // Le masque est celui de `write` pour quatre et huit octets : la
            // mémoire vive ne rend jamais plus large, un périphérique le pourrait.
            registers[reg] = try readRMMemory(size) & Self.mask(size)
        case Form.store:
            lastAddress = fastAddress(instruction)
            try writeRMMemory(size, registers.read(reg) & Self.mask(size))
        case Form.jumpIf:
            guard condition(instruction.pointee.opcode) else { return false }
            rip = rip &+ UInt64(instruction.pointee.lengthByte)
                &+ Self.signExtend(instruction.pointee.immediate, Int(instruction.pointee.immediateByteCount))
            return true
        case Form.jump:
            rip = rip &+ UInt64(instruction.pointee.lengthByte)
                &+ Self.signExtend(instruction.pointee.immediate, Int(instruction.pointee.immediateByteCount))
            return true
        case Form.arithmeticToRM:
            let index = Int(instruction.pointee.opcode >> 3)
            let result = arithmetic(index, read(rm, size, highByte: false),
                                    read(reg, size, highByte: false), size)
            if let result { write(rm, size, highByte: false, result) }
        case Form.arithmeticToRegister:
            let index = Int(instruction.pointee.opcode >> 3)
            let result = arithmetic(index, read(reg, size, highByte: false),
                                    read(rm, size, highByte: false), size)
            if let result { write(reg, size, highByte: false, result) }
        case Form.arithmeticFromMemory:
            lastAddress = fastAddress(instruction)
            let index = Int(instruction.pointee.opcode >> 3)
            let result = arithmetic(index, read(reg, size, highByte: false),
                                    try readRMMemory(size), size)
            if let result { write(reg, size, highByte: false, result) }
        case Form.compareMemory:
            lastAddress = fastAddress(instruction)
            _ = arithmetic(7, try readRMMemory(size), read(reg, size, highByte: false), size)
        case Form.arithmeticImmediate:
            let operand = Self.immediate(instruction.pointee.immediate,
                                         bytes: Int(instruction.pointee.immediateByteCount), size)
            let result = arithmetic(reg & 7, read(rm, size, highByte: false), operand, size)
            if let result { write(rm, size, highByte: false, result) }
        case Form.test:
            _ = logic(read(rm, size, highByte: false) & read(reg, size, highByte: false), size)
        case Form.loadAddress:
            let address = fastAddress(instruction)
            lastAddress = address
            registers[reg] = address & Self.mask(size)
        case Form.zeroExtendByte:
            registers[reg] = read(rm, 1, highByte: instruction.pointee.highByteFlags & 2 != 0)
        case Form.zeroExtendWord:
            registers[reg] = registers.read(rm) & 0xFFFF
        case Form.loadByte:
            lastAddress = fastAddress(instruction)
            registers[reg] = try readRMMemory(1) & Self.mask(size)
        case Form.loadWord:
            lastAddress = fastAddress(instruction)
            registers[reg] = try readRMMemory(2) & Self.mask(size)
        case Form.push:
            // Le registre est dans l'opcode ; `rmField` porte déjà REX.B.
            try push(registers.read((rm & 8) | Int(instruction.pointee.opcode & 7)), 8)
        case Form.pop:
            let value = try pop(8)
            registers[(rm & 8) | Int(instruction.pointee.opcode & 7)] = value
        case Form.call:
            let after = rip &+ UInt64(instruction.pointee.lengthByte)
            try push(after, 8)
            rip = after &+ Self.signExtend(instruction.pointee.immediate,
                                           Int(instruction.pointee.immediateByteCount))
            return true
        case Form.ret:
            rip = try pop(8)
            return true
        default:
            throw Self.unsupportedMap(instruction.pointee.map)
        }
        return false
    }

    /// Une forme courte arrivée par valeur — `execute` hors de `run`, les
    /// tests, les corpus matériels. Hors du chemin chaud.
    @inline(never)
    mutating func performFastByValue(_ instruction: X86Instruction) throws {
        var copy = instruction
        if try performFast(&copy) { jumped = true }
    }
}
