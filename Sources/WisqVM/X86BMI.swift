import Foundation

// **x86-64-v3, la part des registres généraux** : BMI1, BMI2, LZCNT, TZCNT et
// MOVBE.
//
// RHEL 10 et ses dérivés — CentOS Stream 10, AlmaLinux 10, Rocky 10 — sont
// compilés pour x86-64-v3. Leur noyau ne touche pas aux registres
// vectoriels, mais il emploie ces instructions-ci sans rien demander :
// CentOS Stream 10 s'arrêtait à sa 13 441ᵉ instruction, sur `andn`. BMI1 et
// BMI2 sont encodées en VEX — le premier préfixe VEX que ce cœur exécute —,
// LZCNT et TZCNT sont BSR et BSF sous le préfixe F3, MOVBE un `mov` qui
// retourne ses octets.
//
// La référence est le processeur : `Tests/Fixtures/x86-v3-gpr-oracle.tsv`.
extension X86Core {
    /// Les instructions VEX que ce cœur exécute : celles des registres
    /// généraux, puis les formes VEX.128 de SSE (`X86AVX.swift`). Les autres
    /// — AVX sur 256 bits, AVX2, FMA, F16C — sont refusées par leur nom
    /// générique, comme avant.
    mutating func vexInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        // EVEX n'est pas VEX.
        guard instruction.vexCount != 4 else { throw Self.vectorRefusal() }
        guard instruction.vexLength == 0 else { return try wideVEXInstruction(instruction, opcode) }
        switch (instruction.map, opcode, instruction.vexImpliedPrefix) {
        case (.threeByte38, 0xF2, 0): try andNot(instruction)
        case (.threeByte38, 0xF3, 0): try lowestBitGroup(instruction)
        case (.threeByte38, 0xF5, 0): try zeroHighBits(instruction)
        case (.threeByte38, 0xF5, 2): try parallelBits(instruction, deposit: false)
        case (.threeByte38, 0xF5, 3): try parallelBits(instruction, deposit: true)
        case (.threeByte38, 0xF6, 3): try multiplyNoFlags(instruction)
        case (.threeByte38, 0xF7, 0): try bitFieldExtract(instruction)
        case (.threeByte38, 0xF7, let prefix): try shiftNoFlags(instruction, kind: prefix)
        case (.threeByte3A, 0xF0, 3): try rotateRightNoFlags(instruction)
        case (.twoByte, 0xAE, 0): try vexControlStatus(instruction)
        default: try vex128Instruction(instruction, opcode)
        }
    }

    /// **`VLDMXCSR` et `VSTMXCSR`** (`VEX.LZ.0F AE /2` et `/3`) : le registre
    /// de contrôle et d'état SSE, chargé depuis la mémoire ou écrit en
    /// mémoire, exactement comme `LDMXCSR` et `STMXCSR` sans VEX.
    ///
    /// La `libm` de la glibc les emploie dans ses variantes FMA, choisies
    /// d'après `CPUID` : `sincos` sauve et rétablit l'arrondi par
    /// `vstmxcsr`. `libinput` l'appelle pour l'accélération du pointeur, et
    /// Xorg mourait au démarrage d'un « Illegal instruction », relancé en
    /// boucle par `lightdm` — le bureau de Void Linux Xfce ne s'ouvrait pas.
    ///
    /// Seule la forme mémoire existe ; `vvvv` doit valoir 1111 (aucun
    /// registre), sinon l'instruction est indéfinie.
    private mutating func vexControlStatus(_ instruction: X86Instruction) throws {
        let modrm = instruction.modrm ?? 0
        let extension_ = modrm >> 3 & 0x07
        guard modrm >> 6 != 0b11, instruction.vexRegister == 0,
              extension_ == 2 || extension_ == 3 else {
            throw Self.vectorRefusal()
        }
        let fields = try decodeFields(instruction)
        guard memory != nil else { throw Fault.unsupported("VEX 0F AE sans mémoire") }
        if extension_ == 2 {
            mxcsr = UInt32(truncatingIfNeeded: try readRM(fields, 4))
        } else {
            try writeRM(fields, 4, UInt64(mxcsr))
        }
    }

    /// La largeur d'une forme VEX : huit octets sous VEX.W, quatre sinon.
    /// Il n'y a pas de forme de seize bits.
    private static func vexSize(_ instruction: X86Instruction) -> Int {
        instruction.wideOperandSize == 8 ? 8 : 4
    }

    /// `SF`, `ZF`, et `CF` donnée ; `OF` effacé. `AF` et `PF` sont indéfinis
    /// pour toutes ces formes : effacés ici, et l'oracle ne les compare pas.
    private mutating func setLogicFlags(_ result: UInt64, _ size: Int, carry: Bool) {
        let signBit = Self.signBit(size)
        var computed: UInt64 = 0
        if result & Self.mask(size) == 0 { computed |= Flag.zero }
        if result & signBit != 0 { computed |= Flag.sign }
        if carry { computed |= Flag.carry }
        setArithmeticFlags(computed)
    }

    /// `ANDN` : `¬vvvv ∧ r/m`, dans `reg`.
    private mutating func andNot(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let result = ~read(instruction.vexRegister, size, highByte: false) & (try readRM(fields, size))
            & Self.mask(size)
        writeReg(fields, size, result)
        setLogicFlags(result, size, carry: false)
    }

    /// `BLSR` (`/1`), `BLSMSK` (`/2`), `BLSI` (`/3`) : le bit à un le plus
    /// bas, effacé, en masque ou isolé, dans `vvvv`.
    private mutating func lowestBitGroup(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let mask = Self.mask(size)
        let source = try readRM(fields, size) & mask
        let result: UInt64
        switch fields.reg & 7 {
        case 1:
            result = (source &- 1) & source & mask
            setLogicFlags(result, size, carry: source == 0)
        case 2:
            result = ((source &- 1) ^ source) & mask
            setLogicFlags(result, size, carry: source == 0)
            // `BLSMSK` efface ZF quoi qu'il arrive : son résultat n'est
            // jamais nul.
            set(Flag.zero, false)
        case 3:
            result = (0 &- source) & source & mask
            setLogicFlags(result, size, carry: source != 0)
        default:
            throw Self.vectorRefusal()
        }
        write(instruction.vexRegister, size, highByte: false, result)
    }

    /// `BZHI` : `r/m` dont les bits à partir du rang `vvvv[7:0]` sont mis à
    /// zéro. Un rang au-delà de la largeur garde tout, et lève CF.
    private mutating func zeroHighBits(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let index = read(instruction.vexRegister, size, highByte: false) & 0xFF
        let source = try readRM(fields, size) & Self.mask(size)
        let bits = UInt64(8 * size)
        let result = index < bits ? source & ((UInt64(1) << index) &- 1) : source
        writeReg(fields, size, result)
        setLogicFlags(result, size, carry: index > bits - 1)
    }

    /// `PDEP` et `PEXT` : les bits de `vvvv` déposés aux places des bits à un
    /// du masque `r/m`, ou ceux de `vvvv` qui sont à ces places, recueillis
    /// en bas. Aucun drapeau.
    private mutating func parallelBits(_ instruction: X86Instruction, deposit: Bool) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let source = read(instruction.vexRegister, size, highByte: false) & Self.mask(size)
        var mask = try readRM(fields, size) & Self.mask(size)
        var result: UInt64 = 0
        var bit: UInt64 = 1
        while mask != 0 {
            let lowest = mask & (0 &- mask)
            if deposit {
                if source & bit != 0 { result |= lowest }
            } else if source & lowest != 0 {
                result |= bit
            }
            mask &= mask &- 1
            bit <<= 1
        }
        writeReg(fields, size, result)
    }

    /// `MULX` : RDX fois `r/m`, sans signe ; le haut dans `reg`, le bas dans
    /// `vvvv`. Aucun drapeau. Si les deux désignent le même registre, c'est
    /// le haut qui reste.
    private mutating func multiplyNoFlags(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let right = try readRM(fields, size)
        let left = read(2, size, highByte: false)
        let high: UInt64
        let low: UInt64
        if size == 8 {
            (high, low) = left.multipliedFullWidth(by: right)
        } else {
            let product = (left & 0xFFFF_FFFF) * (right & 0xFFFF_FFFF)
            (high, low) = (product >> 32, product & 0xFFFF_FFFF)
        }
        write(instruction.vexRegister, size, highByte: false, low)
        writeReg(fields, size, high)
    }

    /// `BEXTR` : les `vvvv[15:8]` bits de `r/m` à partir du rang
    /// `vvvv[7:0]`. Un départ au-delà de la largeur rend zéro ; une longueur
    /// au-delà, tout ce qui reste.
    private mutating func bitFieldExtract(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let control = read(instruction.vexRegister, size, highByte: false)
        let start = control & 0xFF
        let length = control >> 8 & 0xFF
        let source = try readRM(fields, size) & Self.mask(size)
        let bits = UInt64(8 * size)
        var result = start < bits ? source >> start : 0
        if length < 64 { result &= (UInt64(1) << length) &- 1 }
        writeReg(fields, size, result)
        setLogicFlags(result, size, carry: false)
        // SF est indéfini pour `BEXTR` : effacé comme AF et PF.
        set(Flag.sign, false)
    }

    /// `SHLX` (66), `SARX` (F3), `SHRX` (F2) : `r/m` décalé de `vvvv`,
    /// masqué à la largeur, dans `reg`. Aucun drapeau.
    private mutating func shiftNoFlags(_ instruction: X86Instruction, kind: Int) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let count = read(instruction.vexRegister, size, highByte: false) & (size == 8 ? 63 : 31)
        let source = try readRM(fields, size) & Self.mask(size)
        let result: UInt64
        switch kind {
        case 1: result = source << count & Self.mask(size)
        case 2:
            // Arithmétique : le signe, étendu à soixante-quatre bits, suit
            // le décalage.
            let signed = Int64(bitPattern: Self.signExtend(source, size))
            result = UInt64(bitPattern: signed >> Int64(count)) & Self.mask(size)
        default: result = source >> count
        }
        writeReg(fields, size, result)
    }

    /// `RORX` : `r/m` tourné à droite de l'immédiat, masqué à la largeur.
    /// Aucun drapeau.
    private mutating func rotateRightNoFlags(_ instruction: X86Instruction) throws {
        let size = Self.vexSize(instruction)
        let fields = try decodeFields(instruction)
        let bits = UInt64(8 * size)
        let count = instruction.immediate & (bits - 1)
        let source = try readRM(fields, size) & Self.mask(size)
        let result = count == 0 ? source : (source >> count | source << (bits - count)) & Self.mask(size)
        writeReg(fields, size, result)
    }

    // MARK: - Sans VEX

    /// `TZCNT` (F3 0F BC) et `LZCNT` (F3 0F BD) : le nombre de zéros par un
    /// bout, la largeur entière pour une source nulle. CF dit la source
    /// nulle, ZF le résultat nul ; les autres sont indéfinis et restent.
    mutating func countZeros(_ instruction: X86Instruction, leading: Bool) throws {
        let size = Self.operandSize(instruction, byteForm: false)
        let fields = try decodeFields(instruction)
        let source = try readRM(fields, size) & Self.mask(size)
        let bits = 8 * size
        let count = source == 0 ? bits
            : leading ? source.leadingZeroBitCount - (64 - bits) : source.trailingZeroBitCount
        writeReg(fields, size, UInt64(count))
        set(Flag.carry, source == 0)
        set(Flag.zero, count == 0)
    }

    /// **`ADCX` (66 0F 38 F6) et `ADOX` (F3 0F 38 F6)** : une addition avec
    /// retenue qui ne lit et ne pose **qu'un** drapeau — CF pour l'une, OF
    /// pour l'autre — et laisse tous les autres. Deux chaînes de retenues
    /// peuvent ainsi courir côte à côte, entrelacées avec `MULX` qui n'en
    /// touche aucun : c'est la boucle de multiplication d'OpenSSL quand le
    /// processeur annonce BMI2 et ADX, avec moins d'instructions par mot
    /// que sa boucle `MUL`/`ADC` — ce que paie un interpréteur.
    ///
    /// 32 bits, ou 64 avec REX.W. Le préfixe 66 fait partie de l'opcode et
    /// ne raccourcit rien.
    mutating func addWithOneCarry(_ instruction: X86Instruction, overflow: Bool) throws {
        let size = instruction.wideOperandSize == 8 ? 8 : 4
        let fields = try decodeFields(instruction)
        let flag = overflow ? Flag.overflow : Flag.carry
        let carryIn: UInt64 = flags & flag != 0 ? 1 : 0
        let left = readReg(fields, size)
        let right = try readRM(fields, size)
        let result: UInt64
        let carryOut: Bool
        if size == 8 {
            let (first, overflow1) = left.addingReportingOverflow(right)
            let (second, overflow2) = first.addingReportingOverflow(carryIn)
            result = second
            carryOut = overflow1 || overflow2
        } else {
            let sum = (left & 0xFFFF_FFFF) &+ (right & 0xFFFF_FFFF) &+ carryIn
            result = sum & 0xFFFF_FFFF
            carryOut = sum >> 32 != 0
        }
        writeReg(fields, size, result)
        set(flag, carryOut)
    }

    /// `MOVBE` (0F 38 F0 et F1) : un `mov` entre registre et mémoire dont les
    /// octets sont retournés. La mémoire seulement ; entre registres, c'est
    /// une autre instruction.
    mutating func moveSwappingBytes(_ instruction: X86Instruction, toMemory: Bool) throws {
        let size = Self.operandSize(instruction, byteForm: false)
        let fields = try decodeFields(instruction)
        guard fields.mod != 0b11 else {
            throw Fault.unsupported("MOVBE entre deux registres")
        }
        func swapped(_ value: UInt64) -> UInt64 {
            switch size {
            case 2: return UInt64(UInt16(truncatingIfNeeded: value).byteSwapped)
            case 4: return UInt64(UInt32(truncatingIfNeeded: value).byteSwapped)
            default: return value.byteSwapped
            }
        }
        if toMemory {
            try writeRM(fields, size, swapped(readReg(fields, size)))
        } else {
            writeReg(fields, size, swapped(try readRM(fields, size)))
        }
    }
}
