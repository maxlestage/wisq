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
public struct X86Core: @unchecked Sendable {
    /// Les seize registres, dans l'ordre de l'encodage : RAX, RCX, RDX, RBX,
    /// RSP, RBP, RSI, RDI, puis R8 à R15.
    ///
    /// **Un tableau, et c'est mesuré.** Il paraît évident qu'un tableau Swift
    /// coûte cher sur le chemin chaud d'un interprète : il vit sur le tas, il
    /// vérifie ses bornes, il vérifie son unicité avant d'écrire. J'ai donc
    /// essayé de le remplacer par les seize valeurs en ligne dans la
    /// structure, sous forme de tuple. Résultat : **16,5 → 15,4 MIPS**, puis
    /// 15,5 avec une seconde variante. Les deux façons d'atteindre un tuple
    /// depuis Swift passent par un pointeur temporaire, et ça coûte plus que
    /// la vérification de bornes qu'on croyait éviter. Revenu au tableau ; la
    /// prochaine tentative devra commencer par une mesure, pas par une
    /// intuition.
    public var registers: [UInt64]
    /// RFLAGS, dont seuls les six de l'arithmétique nous occupent ici.
    public var flags: UInt64
    /// Où le cœur en est.
    public var rip: UInt64
    /// La mémoire de l'invité. Absente, toute forme mémoire est refusée plutôt
    /// qu'approximée.
    public var memory: X86Memory?
    /// Les octets sortis par le port série, dans l'ordre.
    public var serialOutput: [UInt8] = []
    /// Combien d'instructions ont été exécutées. C'est ce compteur qui donne
    /// le chiffre de vitesse.
    public var retired: UInt64 = 0
    /// Vrai quand l'invité a exécuté `HLT`.
    public var halted = false
    /// Les registres de contrôle, les MSR, et de quoi traduire une adresse.
    public var system = X86SystemState()
    /// Les six sélecteurs de segment : ES, CS, SS, DS, FS, GS. En mode long
    /// leurs bases valent zéro sauf pour FS et GS, qui les prennent dans des
    /// MSR ; le sélecteur lui-même ne sert plus qu'aux privilèges. Un noyau les
    /// charge quand même dès son entrée, et refuser l'instruction l'arrêterait
    /// là.
    public var segments = [UInt16](repeating: 0, count: 6)
    /// La pagination est-elle allumée ? Gardé à part, et pas relu dans `system`
    /// à chaque accès mémoire : la question se pose plusieurs fois par
    /// instruction et la réponse ne change qu'à l'écriture de CR0. La lire
    /// depuis le tableau des registres de contrôle coûtait **13 %** du débit,
    /// pagination éteinte comprise.
    var pagingActive = false
    /// Où le noyau a dit que ses tables de descripteurs se trouvent : GDT puis
    /// IDT. Le **contenu** du pseudo-descripteur, pas son adresse — c'est ce
    /// que fait un vrai processeur, qui recopie base et limite dans un
    /// registre au moment du `LGDT`/`LIDT` et ne relit jamais la mémoire
    /// d'où ils viennent. La première version notait l'adresse de l'opérande,
    /// ce qui suffisait tant que personne ne s'en servait ; la livraison
    /// d'exception, elle, s'en sert.
    public var descriptorBases = [UInt64](repeating: 0, count: 2)
    /// Les limites qui vont avec, en octets moins un. Une IDT dont la limite
    /// ne couvre pas un vecteur ne le livre pas.
    public var descriptorLimits = [UInt64](repeating: 0, count: 2)
    /// Les deux seuls mots d'état x87 qui existent ici : ceux que la séquence
    /// de détection de Linux range et relit. Voir `minimalX87`.
    public var x87Status: UInt16 = 0
    public var x87Control: UInt16 = 0x037F
    /// Le cache de traduction : étiquettes et cadres, côte à côte.
    var translationTags = [UInt64](repeating: 0, count: X86Core.translationSlots)
    var translationFrames = [UInt64](repeating: 0, count: X86Core.translationSlots)

    public init(registers: [UInt64] = [UInt64](repeating: 0, count: 16),
                flags: UInt64 = X86Core.Flag.reserved, rip: UInt64 = 0,
                memory: X86Memory? = nil) {
        precondition(registers.count == 16, "un x86-64 a seize registres généraux")
        self.registers = registers
        self.flags = flags
        self.rip = rip
        self.memory = memory
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
        /// Le pas-à-pas. Aucune instruction ne le pose ici ; l'entrée dans un
        /// gestionnaire l'éteint, comme sur la machine.
        public static let trap: UInt64 = 1 << 8
        /// Le masque d'interruption. Ce cœur n'interrompt rien encore, mais un
        /// noyau pose et lit ce bit dès sa première ligne.
        public static let interrupt: UInt64 = 1 << 9
        /// La tâche imbriquée, héritage du 286, éteinte à l'entrée d'une
        /// exception.
        public static let nested: UInt64 = 1 << 14
        /// La reprise, qui inhibe les points d'arrêt d'instruction. Éteinte
        /// pour la même raison.
        public static let resume: UInt64 = 1 << 16
        /// La direction des opérations sur chaînes : vers le haut ou vers le
        /// bas. `CLD` est très souvent la toute première instruction d'un
        /// noyau, parce qu'il ne peut pas faire confiance à ce que le chargeur
        /// a laissé.
        public static let direction: UInt64 = 1 << 10
        public static let overflow: UInt64 = 1 << 11
        /// Les six que l'arithmétique touche, réunis.
        public static let arithmetic: UInt64 = carry | parity | auxiliary | zero | sign | overflow
    }

    public enum Fault: Error, Equatable {
        /// Une forme que ce cœur ne sait pas encore exécuter, nommée.
        case unsupported(String)
        /// Une division par zéro, ou dont le quotient ne tient pas.
        case divideError
        /// Une adresse virtuelle qu'aucune table de pages ne traduit.
        case pageFault(UInt64)
        /// Une adresse **physique** en dehors de la mémoire de l'invité. Ce
        /// n'est pas la même chose qu'une faute de page, et les confondre fait
        /// chercher au mauvais endroit.
        case outsideMemory(UInt64)
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

    /// Lire l'instruction à RIP, l'exécuter, et recommencer — jusqu'à `budget`
    /// instructions, ou jusqu'à un `HLT`, ou jusqu'à une faute.
    ///
    /// C'est cette boucle qui sera mesurée : elle ne fait rien d'autre que
    /// décoder et exécuter, donc le chiffre qui en sort est celui de
    /// l'interprète.
    @discardableResult
    public mutating func run(budget: UInt64) throws -> UInt64 {
        guard let memory else { throw Fault.unsupported("une exécution sans mémoire") }
        var executed: UInt64 = 0
        while executed < budget && !halted {
            do {
                let physical = try translate(rip, .fetch)
                guard let start = memory.offset(physical, 1) else {
                    throw Fault.outsideMemory(physical)
                }
                let available = min(X86Instruction.maximumLength, memory.size - start)
                let instruction = try X86Decoder.decode(memory.bytes + start, available: available)
                try execute(instruction)
            } catch let fault as Fault {
                // Une faute que le noyau a dit savoir traiter lui revient ;
                // les autres sortent d'ici, parce qu'un cœur qui avale une
                // faute qu'il ne sait pas livrer ment sur ce qu'il fait.
                guard try deliver(fault) else { throw fault }
            }
            executed += 1
        }
        return executed
    }

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
        // Un branchement a déjà posé RIP où il fallait ; il le signale en
        // laissant `jumped` à vrai plutôt qu'en renvoyant une valeur, pour que
        // le chemin normal — l'écrasante majorité — ne coûte rien.
        if jumped {
            jumped = false
        } else {
            rip &+= UInt64(instruction.length)
        }
        retired &+= 1
    }

    /// Vrai le temps d'une instruction qui a posé RIP elle-même.
    var jumped = false
    /// Le code d'erreur de la dernière faute de page : ce que le gestionnaire
    /// du noyau trouve empilé sous l'adresse de retour. Posé par la
    /// traduction, qui est la seule à savoir si l'accès était une lecture,
    /// une écriture ou une lecture d'instruction.
    var pageFaultErrorCode: UInt64 = 0
    /// L'adresse que le dernier ModRM a désignée, calculée une seule fois.
    var lastAddress: UInt64 = 0

    /// La largeur des opérandes : un octet pour les opcodes qui le disent,
    /// sinon huit avec `REX.W`, deux avec le préfixe de taille, quatre sinon.
    static func operandSize(_ instruction: X86Instruction, byteForm: Bool) -> Int {
        if byteForm { return 1 }
        if let rex = instruction.rex, rex & 0x08 != 0 { return 8 }
        return instruction.hasPrefix(0x66) ? 2 : 4
    }

    struct Fields {
        let reg: Int
        let rm: Int
        let mod: UInt8
        /// Vrai quand un index de 4 à 7 désigne l'octet **haut** d'un registre.
        let regIsHighByte: Bool
        let rmIsHighByte: Bool
    }

    /// Les champs du ModRM, **et** l'adresse qu'ils désignent quand ce n'est
    /// pas un registre. Les deux ensemble parce que l'adresse dépend de l'état
    /// d'avant l'instruction : la calculer plus tard, après une écriture,
    /// donnerait autre chose.
    mutating func decodeFields(_ instruction: X86Instruction, size: Int) throws -> Fields {
        let fields = try X86Core.fields(instruction, size: size)
        if fields.mod != 0b11 { lastAddress = try effectiveAddress(instruction, fields) }
        return fields
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
        guard instruction.vexCount == 0 else {
            throw Fault.unsupported("une instruction vectorielle")
        }
        let opcode = instruction.opcode

        switch instruction.map {
        case .oneByte: try oneByte(instruction, opcode)
        case .twoByte:
            // Les instructions système d'abord : elles occupent des octets que
            // la table ordinaire ne connaît pas.
            if try systemInstruction(instruction, opcode) { return }
            try twoByte(instruction, opcode)
        default: throw Fault.unsupported("la table \(instruction.map)")
        }
    }
}
