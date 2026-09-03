import Foundation

/// Ce qu'une instruction x86-64 **fait** aux registres et aux drapeaux.
///
/// Tranche 3 du lot 7 (`docs/ROADMAP.md`), premier morceau : le calcul. La
/// tranche 2 a établi où une instruction finit ; celle-ci établit ce qu'elle
/// laisse derrière elle.
///
/// **La référence est le processeur lui-même.** Ce conteneur est un x86-64,
/// donc `scripts/build-x86-oracle.py` fait exécuter chaque instruction par la
/// vraie machine, avec des états d'entrée choisis, et fige sa réponse. Un
/// document se lit de travers ; un processeur, non.
///
/// **Là où le manuel dit « indéfini ».** Après une multiplication, après un
/// décalage de plusieurs bits, certains drapeaux n'ont pas de valeur garantie
/// par l'architecture — et pourtant le processeur en pose une. Ce cœur
/// reproduit celle-là, parce que c'est ce qu'un vrai noyau verra. Chaque
/// endroit où ce choix est fait le dit.
///
/// **Pas encore de mémoire.** Seules les formes registre à registre et à
/// immédiat s'exécutent ici ; `LEA` est la seule à calculer une adresse, et
/// justement elle ne la lit pas. Une forme mémoire est **refusée**, pas
/// approximée.
public struct X86Core: Equatable, Sendable {
    /// Les seize registres, dans l'ordre de l'encodage : RAX, RCX, RDX, RBX,
    /// RSP, RBP, RSI, RDI, puis R8 à R15.
    public var registers: [UInt64]
    /// RFLAGS, dont seuls les six de l'arithmétique nous occupent ici.
    public var flags: UInt64
    /// Où le cœur en est.
    public var rip: UInt64

    public init(registers: [UInt64] = [UInt64](repeating: 0, count: 16),
                flags: UInt64 = X86Core.Flag.reserved, rip: UInt64 = 0) {
        precondition(registers.count == 16, "un x86-64 a seize registres généraux")
        self.registers = registers
        self.flags = flags
        self.rip = rip
    }

    /// Les bits de RFLAGS que ce cœur pose ou lit.
    public enum Flag {
        public static let carry: UInt64 = 1 << 0
        /// Le bit 1 vaut toujours un ; ce n'est pas un drapeau, c'est la forme
        /// du registre.
        public static let reserved: UInt64 = 1 << 1
        public static let parity: UInt64 = 1 << 2
        /// La retenue auxiliaire : celle qui sort du bit 3. Elle ne sert qu'à
        /// l'arithmétique décimale, que le mode 64 bits a supprimée — et elle
        /// est pourtant posée, donc un cœur qui l'oublie diverge.
        public static let auxiliary: UInt64 = 1 << 4
        public static let zero: UInt64 = 1 << 6
        public static let sign: UInt64 = 1 << 7
        public static let overflow: UInt64 = 1 << 11
        /// Les six que l'arithmétique touche, réunis.
        public static let arithmetic: UInt64 = carry | parity | auxiliary | zero | sign | overflow
    }

    public enum Fault: Error, Equatable {
        /// Une forme que ce cœur ne sait pas encore exécuter, nommée.
        case unsupported(String)
        /// Une division par zéro, ou dont le quotient ne tient pas.
        case divideError
    }

    // MARK: - Les registres, et les quatre largeurs

    /// La valeur d'un registre à la largeur demandée.
    ///
    /// Le cas à huit bits porte le piège : sans REX, les index 4 à 7 désignent
    /// AH, CH, DH et BH — les **octets hauts** de RAX à RBX — et avec REX ils
    /// désignent SPL, BPL, SIL et DIL. Le même champ de trois bits nomme deux
    /// choses selon un octet qui se trouve ailleurs dans l'instruction.
    func read(_ index: Int, _ size: Int, highByte: Bool) -> UInt64 {
        if size == 1 && highByte { return (registers[index - 4] >> 8) & 0xFF }
        let value = registers[index]
        switch size {
        case 1: return value & 0xFF
        case 2: return value & 0xFFFF
        case 4: return value & 0xFFFF_FFFF
        default: return value
        }
    }

    /// Écrire à la largeur demandée.
    ///
    /// La règle qui surprend tout le monde : une écriture de **32 bits met à
    /// zéro les 32 bits du haut**, alors qu'une écriture de 8 ou 16 bits laisse
    /// le reste du registre intact. Ce n'est pas une commodité, c'est
    /// l'architecture, et un cœur qui l'ignore fait diverger un noyau au bout
    /// de quelques milliers d'instructions.
    mutating func write(_ index: Int, _ size: Int, highByte: Bool, _ value: UInt64) {
        if size == 1 && highByte {
            let target = index - 4
            registers[target] = (registers[target] & ~0xFF00) | ((value & 0xFF) << 8)
            return
        }
        switch size {
        case 1: registers[index] = (registers[index] & ~0xFF) | (value & 0xFF)
        case 2: registers[index] = (registers[index] & ~0xFFFF) | (value & 0xFFFF)
        case 4: registers[index] = value & 0xFFFF_FFFF  // le haut disparaît
        default: registers[index] = value
        }
    }

    static func mask(_ size: Int) -> UInt64 {
        size == 8 ? UInt64.max : (UInt64(1) << (8 * UInt64(size))) - 1
    }

    static func signBit(_ size: Int) -> UInt64 { UInt64(1) << (8 * UInt64(size) - 1) }

    static func signExtend(_ value: UInt64, _ size: Int) -> UInt64 {
        size == 8 ? value : (value & (signBit(size) &- 1)) &- (value & signBit(size))
    }

    // MARK: - Les drapeaux

    var carry: Bool { flags & Flag.carry != 0 }

    mutating func set(_ flag: UInt64, _ on: Bool) {
        if on { flags |= flag } else { flags &= ~flag }
    }

    /// La parité : celle des **huit bits de poids faible** du résultat, et
    /// d'eux seuls, quelle que soit la largeur de l'opération. Posée quand le
    /// nombre de bits à un est pair.
    static func parity(_ value: UInt64) -> Bool { (value & 0xFF).nonzeroBitCount % 2 == 0 }

    mutating func setResultFlags(_ result: UInt64, _ size: Int) {
        set(Flag.zero, result & Self.mask(size) == 0)
        set(Flag.sign, result & Self.signBit(size) != 0)
        set(Flag.parity, Self.parity(result))
    }

    // MARK: - Exécuter

    /// Exécute l'instruction et avance RIP de ce qui a été lu.
    ///
    /// **Un refus n'avance pas.** La première version avançait dans un
    /// `defer`, donc même quand l'instruction levait — et un test l'a
    /// attrapée. C'est faux, et pas seulement par commodité : sur un vrai
    /// processeur, une faute de division dépose l'adresse de l'instruction
    /// **fautive**, pas de la suivante, parce que c'est celle-là qu'un
    /// gestionnaire doit pouvoir regarder.
    public mutating func execute(_ instruction: X86Instruction) throws {
        try perform(instruction)
        rip &+= UInt64(instruction.length)
    }

    /// La largeur des opérandes : un octet pour les opcodes qui le disent,
    /// sinon huit avec `REX.W`, deux avec le préfixe de taille, quatre sinon.
    static func operandSize(_ instruction: X86Instruction, byteForm: Bool) -> Int {
        if byteForm { return 1 }
        if let rex = instruction.rex, rex & 0x08 != 0 { return 8 }
        return instruction.legacyPrefixes.contains(0x66) ? 2 : 4
    }

    struct Fields {
        let reg: Int
        let rm: Int
        let mod: UInt8
        /// Vrai quand un index de 4 à 7 désigne l'octet **haut** d'un registre.
        let regIsHighByte: Bool
        let rmIsHighByte: Bool
    }

    static func fields(_ instruction: X86Instruction, size: Int) throws -> Fields {
        guard let modrm = instruction.modrm else {
            throw Fault.unsupported("une instruction sans ModRM là où il en faut un")
        }
        let rex = instruction.rex ?? 0
        let reg = Int((rex & 0x04) << 1 | ((modrm >> 3) & 0x07))
        let rm = Int((rex & 0x01) << 3 | (modrm & 0x07))
        let noRex = instruction.rex == nil
        return Fields(
            reg: reg, rm: rm, mod: modrm >> 6,
            regIsHighByte: size == 1 && noRex && (4...7).contains(Int((modrm >> 3) & 0x07)),
            rmIsHighByte: size == 1 && noRex && (4...7).contains(Int(modrm & 0x07)))
    }

    mutating func perform(_ instruction: X86Instruction) throws {
        guard instruction.vex.isEmpty else {
            throw Fault.unsupported("une instruction vectorielle")
        }
        let opcode = instruction.opcode

        switch instruction.map {
        case .oneByte: try oneByte(instruction, opcode)
        case .twoByte: try twoByte(instruction, opcode)
        default: throw Fault.unsupported("la table \(instruction.map)")
        }
    }
}
