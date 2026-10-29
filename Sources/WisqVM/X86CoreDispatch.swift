import Foundation

// Quelle instruction fait quoi. La forme est déjà lue par `X86Decoder` ; ici on
// ne fait que choisir l'opération et lui donner ses opérandes.
extension X86Core {
    /// La table d'un octet.
    mutating func oneByte(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        switch opcode {
        // Les huit opérations arithmétiques, six formes chacune, six fois.
        //
        // **Des octets un par un, et ni `where` ni intervalle.** Un intervalle
        // se compare par `~=` et une clause `where` se teste : l'un comme
        // l'autre empêche le compilateur de faire de cet aiguillage une
        // table de sauts. Chaque instruction de l'invité descendait une
        // chaîne de comparaisons, cas après cas, avant d'atteindre le sien —
        // `MOV`, la plus fréquente, une douzaine de tests plus bas. Les cas
        // de premier niveau de `oneByte` ne portent donc que des littéraux ;
        // `0x06`, `0x07`, `0x0E`… tombent toujours dans `default`.
        case 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
             0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D,
             0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D,
             0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D:
            let index = Int(opcode >> 3)
            let form = Int(opcode & 0x07)
            let byteForm = form == 0 || form == 2 || form == 4
            let size = Self.operandSize(instruction, byteForm: byteForm)
            switch form {
            case 0, 1:  // r/m ← r/m op reg
                let fields = try decodeFields(instruction)
                // CMP ne réécrit rien : le vérifier ferait fauter une
                // comparaison contre une page en lecture seule, ce qu'aucun
                // processeur ne fait.
                if index != 7 { try probeWrite(fields, size) }
                let result = arithmetic(index, try readRM(fields, size), readReg(fields, size), size)
                if let result { try writeRM(fields, size, result) }
            case 2, 3:  // reg ← reg op r/m
                let fields = try decodeFields(instruction)
                let result = arithmetic(index, readReg(fields, size), try readRM(fields, size), size)
                if let result { writeReg(fields, size, result) }
            default:  // l'accumulateur et un immédiat
                let value = read(0, size, highByte: false)
                let result = arithmetic(index, value, Self.immediate(instruction, size), size)
                if let result { write(0, size, highByte: false, result) }
            }

        // MOVSXD : la seule instruction dont le nom dit ce que fait la moitié
        // du jeu d'instructions x86-64 sans le dire.
        // La pile : PUSH et POP font huit octets en mode 64 bits, et **REX.W
        // n'y change rien** — c'est une des rares largeurs qui ne se négocie
        // pas par là. Le préfixe de taille, lui, la négocie : sous `66` le
        // sommet ne descend que de deux octets.
        //
        // Le cœur a longtemps écrit `8` partout ici, avec un commentaire qui
        // disait « toujours huit ». La moitié était vraie — celle sur REX.W —
        // et c'est ce qui l'a rendue crédible. Le vrai processeur a tranché :
        // `pushw %ax` rend RSP à 0x30002ffe, pas à 0x30002ff8.
        case 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57:
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            try push(registers.read(index), Self.stackSize(instruction))
        case 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F:
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            let size = Self.stackSize(instruction)
            // `write` et non une affectation : un dépilement de deux octets ne
            // touche que les seize bits du bas, et laisse le reste tel quel.
            write(index, size, highByte: false, try pop(size))
        case 0x68, 0x6A:
            try push(Self.signExtend(instruction.immediate, instruction.immediateBytes),
                     Self.stackSize(instruction))

        // Les seize sauts conditionnels, courts. La destination se compte
        // depuis la **fin** de l'instruction.
        case 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F:
            if condition(opcode) { branch(instruction, Self.signExtend(instruction.immediate, 1)) }
        case 0xC3:
            rip = try pop(8)
            jumped = true

        case 0xC9:  // LEAVE : RSP ← RBP, puis dépiler RBP
            registers[4] = registers.read(5)
            registers[5] = try pop(8)

        case 0xE8:  // CALL relatif : empiler le retour, puis sauter
            let ret = rip &+ UInt64(instruction.length)
            try push(ret, 8)
            branch(instruction, Self.signExtend(instruction.immediate, 4))
        case 0xE9:
            branch(instruction, Self.signExtend(instruction.immediate, 4))
        case 0xEB:
            branch(instruction, Self.signExtend(instruction.immediate, 1))

        case 0x63:
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            writeReg(fields, size, Self.signExtend(try readRM(fields, 4), 4) & Self.mask(size))

        // Le groupe 1 : la même arithmétique, avec un immédiat.
        case 0x80, 0x81, 0x83:
            let size = Self.operandSize(instruction, byteForm: opcode == 0x80)
            let fields = try decodeFields(instruction)
            if (instruction.modrm! >> 3) & 0x07 != 7 { try probeWrite(fields, size) }
            let result = arithmetic(
                Int((instruction.modrm! >> 3) & 0x07), try readRM(fields, size),
                Self.immediate(instruction, size), size)
            if let result { try writeRM(fields, size, result) }

        case 0x84, 0x85:  // TEST : un ET dont personne ne garde le résultat.
            let size = Self.operandSize(instruction, byteForm: opcode == 0x84)
            let fields = try decodeFields(instruction)
            _ = logic(try readRM(fields, size) & readReg(fields, size), size)

        case 0x86, 0x87:  // XCHG
            let size = Self.operandSize(instruction, byteForm: opcode == 0x86)
            let fields = try decodeFields(instruction)
            let first = try readRM(fields, size)
            let second = readReg(fields, size)
            try writeRM(fields, size, second)
            writeReg(fields, size, first)

        case 0x88, 0x89:  // MOV r/m ← r
            let size = Self.operandSize(instruction, byteForm: opcode == 0x88)
            let fields = try decodeFields(instruction)
            try writeRM(fields, size, readReg(fields, size))

        case 0x8A, 0x8B:  // MOV r ← r/m
            let size = Self.operandSize(instruction, byteForm: opcode == 0x8A)
            let fields = try decodeFields(instruction)
            writeReg(fields, size, try readRM(fields, size))

        case 0x8D:  // LEA : calcule une adresse et ne la lit pas.
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            // **Et qui ne traverse donc pas l'unité de segmentation.** `leaq
            // %gs:0x10, %rax` rend 0x10, pas la base du segment plus 0x10 :
            // rien n'est lu en mémoire, donc aucun segment n'intervient.
            // L'assembleur le dit — il avertit que le préfixe est
            // « ineffectual » — et le corpus matériel le vérifie.
            let address = try effectiveAddress(instruction, fields, segmented: false)
            writeReg(fields, size, address & Self.mask(size))

        case 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97:  // XCHG rAX, r — dont 0x90, qui est NOP.
            let size = Self.operandSize(instruction, byteForm: false)
            let rex = instruction.rex ?? 0
            let other = Int((rex & 0x01) << 3 | (opcode & 0x07))
            guard other != 0 else { break }  // xchg rax, rax ne fait rien
            let first = read(0, size, highByte: false)
            write(0, size, highByte: false, read(other, size, highByte: false))
            write(other, size, highByte: false, first)

        case 0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF:
            try stringOperation(instruction, opcode)

        case 0xA8, 0xA9:  // TEST accumulateur, immédiat
            let size = Self.operandSize(instruction, byteForm: opcode == 0xA8)
            _ = logic(read(0, size, highByte: false) & Self.immediate(instruction, size), size)

        case 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7:  // MOV r8, imm8
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            let high = instruction.rex == nil && (4...7).contains(Int(opcode & 0x07))
            write(high ? index : index, 1, highByte: high, instruction.immediate & 0xFF)

        case 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF:  // MOV r, imm — le seul immédiat de huit octets.
            let size = Self.operandSize(instruction, byteForm: false)
            let rex = instruction.rex ?? 0
            let index = Int((rex & 0x01) << 3 | (opcode & 0x07))
            write(index, size, highByte: false, instruction.immediate & Self.mask(size))

        case 0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3:  // décalages et rotations
            let byteForm = opcode == 0xC0 || opcode == 0xD0 || opcode == 0xD2
            let size = Self.operandSize(instruction, byteForm: byteForm)
            let fields = try decodeFields(instruction)
            let count: UInt64
            switch opcode {
            case 0xC0, 0xC1: count = instruction.immediate & 0xFF
            case 0xD0, 0xD1: count = 1
            default: count = registers.read(1) & 0xFF  // CL
            }
            let kind = Int((instruction.modrm! >> 3) & 0x07)
            try probeWrite(fields, size)
            let value = try readRM(fields, size)
            let result = kind <= 3
                ? rotate(kind, value, count, size)
                : shift(kind, value, count, size)
            try writeRM(fields, size, result)

        case 0xC6, 0xC7:  // MOV r/m, imm
            let size = Self.operandSize(instruction, byteForm: opcode == 0xC6)
            let fields = try decodeFields(instruction)
            try writeRM(fields, size, Self.immediate(instruction, size))

        case 0xF6, 0xF7:  // le groupe 3 : TEST, NOT, NEG, et les quatre longues
            let size = Self.operandSize(instruction, byteForm: opcode == 0xF6)
            let fields = try decodeFields(instruction)
            let value = try readRM(fields, size)
            switch (instruction.modrm! >> 3) & 0x07 {
            case 0, 1: _ = logic(value & Self.immediate(instruction, size), size)
            case 2: try writeRM(fields, size, ~value & Self.mask(size))  // NOT : aucun drapeau
            case 3:
                try probeWrite(fields, size)
                try writeRM(fields, size, subtract(0, value, size))  // NEG
            case 4: multiplyUnsigned(value, size)
            case 5: multiplySigned(value, size)
            case 6: try divideUnsigned(value, size)
            default: try divideSigned(value, size)
            }

        case 0xFE, 0xFF:  // INC et DEC, qui ne touchent pas à la retenue
            // Le groupe 5 partage l'octet `FF` : une clause `where` sur son
            // cas cassait la table de sauts comme celle du premier.
            if opcode == 0xFF, (instruction.modrm ?? 0) >> 3 & 0x07 >= 2 {
                try groupFive(instruction)
                return
            }
            let size = Self.operandSize(instruction, byteForm: opcode == 0xFE)
            let fields = try decodeFields(instruction)
            try probeWrite(fields, size)
            let value = try readRM(fields, size)
            let kept = flags & Flag.carry
            let result = (instruction.modrm! >> 3) & 0x07 == 0
                ? add(value, 1, size)
                : subtract(value, 1, size)
            flags = (flags & ~Flag.carry) | kept
            try writeRM(fields, size, result)

        // Le reste — interruptions, entrées-sorties, segments, drapeaux,
        // x87 — vit dans `oneByteCold` : voir sa note.
        default:
            try oneByteCold(instruction, opcode)
        }
    }

    /// Le groupe 5 : appeler, sauter, empiler — tous par une valeur
    /// qu'on va chercher plutôt que par un déplacement.
    @inline(never)
    mutating func groupFive(_ instruction: X86Instruction) throws {
        let fields = try decodeFields(instruction)
        // `/6` empile, et sa largeur est celle de la pile ; `/2` et `/4`
        // sautent, et une destination de saut fait toujours huit octets.
        let reach = (instruction.modrm! >> 3) & 0x07 == 6
            ? Self.stackSize(instruction) : 8
        let target = try readRM(fields, reach)
        switch (instruction.modrm! >> 3) & 0x07 {
        case 2:
            try push(rip &+ UInt64(instruction.length), 8)
            rip = target
            jumped = true
        case 4:
            rip = target
            jumped = true
        case 6:
            try push(target, Self.stackSize(instruction))
        default:
            throw Fault.unsupported("le groupe 5 /\((instruction.modrm! >> 3) & 0x07)")
        }
    }

    /// **Les octets rares de la table d'un octet, à part.** Leurs cas —
    /// interruptions, `IRETQ`, ports, `HLT`, registres de segment, drapeaux,
    /// x87 — demandaient à `oneByte` un cadre et des registres sauvés que
    /// chaque instruction payait, `mov` et `add` compris : sous callgrind,
    /// les deux accolades de `oneByte` coûtaient 3,7 % des instructions de
    /// l'hôte. Un octet qu'aucune des deux ne connaît finit ici, sur la même
    /// faute qu'avant.
    @inline(never)
    mutating func oneByteCold(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        switch opcode {
        case 0x8F:  // POP r/m
            // **La mémoire d'abord, la pile ensuite.** L'écriture peut fauter
            // — une page qu'un `fork()` vient de rendre lisible seulement —,
            // et le noyau rejoue l'instruction après avoir copié la page. Si
            // RSP avait déjà avancé, le rejeu dépilerait la case suivante.
            //
            // **Et l'adresse se calcule avec RSP déjà avancé.** C'est la règle
            // du manuel pour un `POP` dont l'opérande passe par RSP :
            // `pop 0x28(%rsp)` écrit à l'ancien RSP + 8 + 0x28. Calculée avec
            // l'ancien RSP, l'écriture tombait huit octets trop bas — sur la
            // case que le code relit juste après. Le noyau 5.14 d'AlmaLinux 9
            // y range ses drapeaux (`pushf ; pop 0x28(%rsp)`) dans
            // `__text_poke`, puis relit sa `struct page *` à 0x20(%rsp) : il y
            // trouvait 0x282, en faisait une page, et le premier `memcpy` vers
            // la projection temporaire visait une adresse physique de
            // cinquante et un bits. RSP est avancé le temps du calcul, puis
            // remis, et n'avance pour de bon qu'après l'écriture.
            guard memory != nil else { throw Fault.unsupported("une pile sans mémoire") }
            let size = Self.stackSize(instruction)
            let top = registers.read(4)
            registers[4] = top &+ UInt64(size)
            let decoded = Result { try decodeFields(instruction) }
            registers[4] = top
            let fields = try decoded.get()
            let value = try readMemory(top, size)
            try writeRM(fields, size, value)
            registers[4] = top &+ UInt64(size)

        case 0xC2:  // RET imm16 : dépiler puis jeter des arguments
            let destination = try pop(8)
            registers[4] = registers.read(4) &+ (instruction.immediate & 0xFFFF)
            rip = destination
            jumped = true
        case 0x9B:
            // FWAIT : attendre que le coprocesseur ait fini, et prendre son
            // exception s'il en a une. Ce cœur n'a pas de coprocesseur qui
            // calcule, donc il n'y a jamais rien à attendre ni à prendre.
            break

        case 0xCC, 0xCD:  // INT3 et INT n : une interruption demandée par le code
            let vector: UInt8 = opcode == 0xCC
                ? 3 : UInt8(truncatingIfNeeded: instruction.immediate)
            // Une interruption **logicielle** reprend **après** l'instruction,
            // pas dessus : c'est un appel, pas une faute. Avancer RIP d'abord
            // est donc la seule façon d'empiler la bonne adresse.
            rip &+= UInt64(instruction.length)
            guard try enter(vector, errorCode: 0) else {
                rip &-= UInt64(instruction.length)
                throw Fault.unsupported("INT \(vector) sans porte pour ce vecteur")
            }
            jumped = true

        case 0xCF:  // IRETQ : le retour d'un gestionnaire d'exception
            guard let rex = instruction.rex, rex & 0x08 != 0 else {
                throw Fault.unsupported("IRET hors du mode 64 bits")
            }
            try returnFromInterrupt()

        case 0xCA, 0xCB:  // RETF : dépiler le décalage **puis** le sélecteur
            // La largeur par défaut d'un retour lointain en mode 64 bits est de
            // quatre octets, pas huit : c'est REX.W qui la porte à huit. Un
            // noyau s'en sert pour recharger CS après avoir posé sa GDT.
            let size = Self.operandSize(instruction, byteForm: false)
            let destination = try pop(size)
            segments[1] = UInt16(truncatingIfNeeded: try pop(size))  // CS
            if opcode == 0xCA { registers[4] = registers.read(4) &+ (instruction.immediate & 0xFFFF) }
            rip = destination
            jumped = true

        case 0xE0, 0xE1, 0xE2:  // LOOPNE, LOOPE, LOOP
            registers[1] = registers.read(1) &- 1
            let zero = flags & Flag.zero != 0
            let again = registers.read(1) != 0
                && (opcode == 0xE2 || (opcode == 0xE1 ? zero : !zero))
            if again { branch(instruction, Self.signExtend(instruction.immediate, 1)) }
        case 0xE3:  // JRCXZ
            if registers.read(1) == 0 { branch(instruction, Self.signExtend(instruction.immediate, 1)) }

        case 0xF4:  // HLT : la machine s'arrête et le dit.
            halted = true

        case 0xE4, 0xE5, 0xEC, 0xED:  // IN
            let port = (opcode <= 0xE5) ? UInt16(instruction.immediate & 0xFF)
                : UInt16(registers.read(2) & 0xFFFF)
            let size = Self.portSize(instruction, byteForm: opcode == 0xE4 || opcode == 0xEC)
            write(0, size, highByte: false, portRead(port, size))
        case 0xE6, 0xE7, 0xEE, 0xEF:  // OUT
            let port = (opcode <= 0xE7) ? UInt16(instruction.immediate & 0xFF)
                : UInt16(registers.read(2) & 0xFFFF)
            let size = Self.portSize(instruction, byteForm: opcode == 0xE6 || opcode == 0xEE)
            portWrite(port, size, read(0, size, highByte: false))

        case 0x69, 0x6B:  // IMUL à trois opérandes
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            writeReg(fields, size, multiplyTruncating(
                try readRM(fields, size), Self.immediate(instruction, size), size))

        case 0x8C:  // MOV r/m16, Sreg
            let fields = try decodeFields(instruction)
            try writeRM(fields, 2, UInt64(segments[fields.reg & 0x07]))
        case 0x8E:  // MOV Sreg, r/m16
            let fields = try decodeFields(instruction)
            let selector = UInt16(truncatingIfNeeded: try readRM(fields, 2))
            let which = fields.reg & 0x07
            segments[which] = selector
            // **Un sélecteur nul dans FS ou GS efface la base**, et c'est
            // mesuré : sur le processeur de ce conteneur, par un programme à
            // syscalls bruts — passer par la libc entre les deux relevés
            // toucherait `errno`, qui vit dans le TLS pointé par FS, donc
            // l'instrument aurait cassé ce qu'il mesure.
            //
            //     FS.base avant = 0x7f7da625f740
            //     xorl %eax,%eax ; movl %eax,%fs
            //     FS.base apres = 0x0
            //
            // Ce cœur gardait l'ancienne, et `segmentBase()` la relit à chaque
            // accès préfixé : un `%fs:` suivant aurait lu à la mauvaise
            // adresse. Latent tant que Linux met ses segments à zéro alors que
            // les bases valent déjà zéro — mais latent n'est pas juste.
            //
            // **Un sélecteur non nul ne touche à rien**, et c'est délibéré :
            // le silicium irait chercher la base dans un descripteur, cette
            // machine n'a pas de table globale, et inventer une base serait
            // pire que garder celle qu'on a. Ce qui est corrigé est le cas nul,
            // qui ne lit aucun descripteur — pas la segmentation entière.
            //
            // **Un seul processeur ne fait pas une architecture**, et ce dépôt
            // n'a pas d'autre silicium sous la main : c'est écrit pour que la
            // prochaine mesure sache ce qu'elle corrige.
            if selector == 0, which == 4 || which == 5 {
                let base = which == 4 ? X86SystemState.fsBase : X86SystemState.gsBase
                system.modelSpecific[base] = 0
            }

        // `LAHF` et `SAHF` : SF, ZF, AF, PF et CF vers AH et retour. Les
        // premiers x86-64 ne les avaient pas en mode long, d'où un bit de
        // CPUID à part, que x86-64-v2 exige. `LAHF` copie l'octet bas tel
        // quel : le bit 1 y vaut toujours un, et 3 et 5 toujours zéro, parce
        // que `SAHF` et `POPF` ne les laissent pas passer — un masque ici ne
        // changerait rien, et un sabotage l'a montré.
        case 0x9F:  // LAHF
            registers[0] = registers.read(0) & ~0xFF00 | (flags & 0xFF) << 8
        case 0x9E:  // SAHF
            flags = flags & ~0xD5 | (registers.read(0) >> 8) & 0xD5
        case 0x9C:  // PUSHF : les drapeaux sur la pile, huit octets en mode long
            try push(flags | Flag.reserved, 8)
        case 0x9D:  // POPF
            // Les bits réservés ne se laissent pas écrire, et le bit 1 vaut
            // toujours un : un noyau qui relit ce qu'il a empilé doit retrouver
            // la même chose.
            flags = (try pop(8) & 0x0000_0000_003F_7FD5) | Flag.reserved

        case 0x98:  // CBW / CWDE / CDQE : l'accumulateur étendu au signe.
            let size = Self.operandSize(instruction, byteForm: false)
            write(0, size, highByte: false,
                  Self.signExtend(read(0, size / 2, highByte: false), size / 2) & Self.mask(size))

        case 0x99:  // CWD / CDQ / CQO : le signe de l'accumulateur rempli dans DX.
            let size = Self.operandSize(instruction, byteForm: false)
            let negative = read(0, size, highByte: false) & Self.signBit(size) != 0
            write(2, size, highByte: false, negative ? Self.mask(size) : 0)

        case 0xF5: flags ^= Flag.carry            // CMC
        case 0xF8: set(Flag.carry, false)         // CLC
        case 0xF9: set(Flag.carry, true)          // STC
        // Le drapeau d'interruption et celui de direction. Ce cœur n'a pas
        // encore d'interruptions, mais un noyau les masque **avant** tout le
        // reste : refuser l'instruction l'arrêterait à sa première ligne.
        case 0xFA: set(Flag.interrupt, false)     // CLI
        case 0xFB: set(Flag.interrupt, true)      // STI
        case 0xFC: set(Flag.direction, false)     // CLD
        case 0xFD: set(Flag.direction, true)      // STD

        case 0xD8...0xDF:
            try x87Instruction(instruction, opcode)
        default:
            throw Fault.unsupported("l'opcode \(String(format: "%02X", opcode))")
        }
    }

    /// La table `0F`.
    mutating func twoByte(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        // Des octets littéraux seulement, comme dans `oneByte` : un intervalle
        // ou une clause `where` ferait de l'aiguillage une chaîne de
        // comparaisons. Une forme qui ne convient pas lève, dans son cas, la
        // faute que `default` lèverait.
        switch opcode {
        case 0x01:  // le groupe 7 : les tables de descripteurs, et le reste
            let group = try decodeFields(instruction)
            // XGETBV et XSETBV : la forme registre de /2, que LGDT n'a pas.
            if (instruction.modrm! >> 3) & 0x07 == 2, group.mod == 0b11 {
                guard group.rm <= 1 else {
                    throw Fault.unsupported("0f 01 \(String(format: "%02x", instruction.modrm!)) n'est pas décidée")
                }
                return try extendedControlInstruction(Int(group.rm))
            }
            // SWAPGS et INVLPG ne touchent pas à la mémoire de l'invité ; les
            // ranger avant la garde évite d'exiger ce dont ils n'ont pas
            // besoin.
            if (instruction.modrm! >> 3) & 0x07 == 7 {
                if group.mod == 0b11 {
                    // **`rm` sépare `SWAPGS` de ses voisins, et il se lit.**
                    //
                    // Ce bras ne regardait que `reg == 7` et `mod == 3`, donc
                    // toute la famille en forme registre tombait sur `SWAPGS` —
                    // `f9` (RDTSCP) compris. Le noyau demandait l'heure et
                    // repartait avec ses deux bases de GS interverties : sa
                    // zone par processeur pointait sur celle de l'espace
                    // utilisateur, et le prochain accès `%gs:` lisait ailleurs.
                    //
                    // Ce n'était pas un refus, c'était une **réponse fausse**,
                    // et une réponse fausse ne se signale pas. Les voisins non
                    // décidés sont donc refusés par leur nom plutôt que servis
                    // par celui d'à côté.
                    switch group.rm {
                    case 0:
                        // SWAPGS : échanger la base de GS avec celle que le
                        // noyau garde de côté. C'est ainsi qu'un noyau bascule
                        // entre sa zone par processeur et celle de l'espace
                        // utilisateur, à chaque entrée et chaque sortie.
                        let aside = system.modelSpecific[X86SystemState.kernelGSBase] ?? 0
                        system.modelSpecific[X86SystemState.kernelGSBase] =
                            system.modelSpecific[X86SystemState.gsBase] ?? 0
                        system.modelSpecific[X86SystemState.gsBase] = aside
                    case 1:
                        // RDTSCP : le compteur d'horodatage dans EDX:EAX, et
                        // `IA32_TSC_AUX` dans ECX. Aucun `wrmsr` de cette
                        // machine n'écrit ce registre, donc ECX reçoit zéro —
                        // et c'est une valeur juste, pas un bouchon : un
                        // processeur dont personne n'a posé le TSC_AUX rend
                        // zéro aussi. Ne rien écrire y laisserait ce qui
                        // traînait, que le noyau lirait comme un numéro de
                        // processeur.
                        // **La même horloge que `RDTSC`**, et pas une seconde
                        // à côté : `retired &+ idled`, tours d'attente compris.
                        // Deux horloges qui divergent feraient reculer le temps
                        // d'une lecture à l'autre, et un noyau qui les compare
                        // se croirait sur deux processeurs.
                        let cycles = retired &+ idled
                        write(0, 4, highByte: false, cycles & 0xFFFF_FFFF)
                        write(2, 4, highByte: false, (cycles >> 32) & 0xFFFF_FFFF)
                        write(1, 4, highByte: false, 0)
                    default:
                        throw Fault.unsupported(
                            "0f 01 \(String(format: "%02x", instruction.modrm!)) "
                                + "n'est pas décidée")
                    }
                } else {
                    // INVLPG : ce cache-ci n'est pas assez fin pour n'oublier
                    // qu'une page, donc il oublie tout. C'est plus lent et
                    // jamais faux ; l'inverse serait le contraire.
                    flushTranslations()
                }
                return
            }
            guard let memory else { throw Fault.unsupported("le groupe 7 sans mémoire") }
            let operand = lastAddress
            switch (instruction.modrm! >> 3) & 0x07 {
            case let which where which == 2 || which == 3:
                // LGDT et LIDT. Le pseudo-descripteur fait dix octets en mode
                // long : une limite de seize bits, puis une base de soixante-
                // quatre. Le processeur en **recopie** le contenu et ne relit
                // jamais la mémoire d'où il vient ; noter l'adresse à la place
                // marchait tant que rien ne s'en servait, et la livraison
                // d'exception s'en sert.
                descriptorLimits[Int(which) - 2] = try readMemory(operand, 2)
                descriptorBases[Int(which) - 2] = try readMemory(operand &+ 2, 8)
            case let which where which == 0 || which == 1:
                // SGDT et SIDT : rendre le pseudo-descripteur, dans la même
                // forme.
                try writeMemory(operand, 2, descriptorLimits[Int(which)])
                try memory.write(
                    try translate(operand &+ 2, .write), 8, descriptorBases[Int(which)])
            default:
                throw Fault.unsupported("le groupe 7 /\((instruction.modrm! >> 3) & 0x07)")
            }

        case 0x00:
            // Le groupe 6, celui du registre de tâche et de la LDT.
            let fields = try decodeFields(instruction)
            switch (instruction.modrm! >> 3) & 0x07 {
            // L'opérande est le **r/m**, pas le `reg` : dans un groupe, `reg`
            // porte le numéro de l'instruction. Les confondre lirait le
            // sélecteur dans le registre 3, qui est RBX.
            case 1:  // STR : rendre le sélecteur de tâche.
                try writeRM(fields, 2, UInt64(taskSelector))
            case 3:  // LTR : charger le registre de tâche.
                try loadTaskRegister(UInt16(truncatingIfNeeded: try readRM(fields, 2)))
            case 0, 2, 4, 5:
                // SLDT, LLDT, VERR, VERW. La LDT est un mécanisme du 286 dont
                // Linux 64 bits ne se sert pas : il charge un sélecteur nul et
                // n'y revient jamais. Les noter suffit ; leur écrire un
                // comportement serait écrire du code que rien n'appelle.
                break
            default:
                throw Fault.unsupported("le groupe 6 /\((instruction.modrm! >> 3) & 0x07)")
            }

        case 0x05: try systemCall(length: instruction.length)
        case 0x07: try systemReturn(wide: (instruction.rex ?? 0) & 0x08 != 0)

        case 0x0B: throw Fault.unsupported("UD2 : l'invité s'est arrêté lui-même")

        case 0x06, 0x08, 0x09:  // CLTS, INVD, WBINVD — rien à faire ici
            break

        case 0x1E:
            // ENDBR64 et ENDBR32 : les balises de CET, que le noyau sème à
            // l'entrée de chaque fonction dès qu'il est compilé avec. Sur un
            // processeur qui n'annonce pas la technologie — et `X86CPUID`
            // ne l'annonce pas — ce sont des NOP. Les refuser arrêterait le
            // noyau à sa toute première instruction.
            //
            // **Et tout le reste de `F3 0F 1E` aussi**, `RDSSPD` et `RDSSPQ`
            // (`/1` en registre) compris. La glibc d'Ubuntu 26.04 met un
            // registre à zéro puis lit le pointeur de pile fantôme : resté à
            // zéro, il n'y a pas de pile fantôme. Sans CET, le manuel range
            // ces octets parmi les NOP réservés, et le registre ne bouge pas.
            // Le refuser arrêtait Ubuntu au premier programme lancé.
            //
            // Sans `F3`, ce sont les NOP réservés du cas suivant : les deux
            // ne font rien, et c'est ce qui permet un seul cas pour l'octet.
            break

        case 0x0D, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D:
            // PREFETCH et les NOP réservés du groupe 16 : des indices pour un
            // cache, et ce cœur n'en a pas. Le noyau en sème sur ses chemins
            // chauds ; les refuser l'arrêterait pour une instruction dont le
            // manuel dit lui-même qu'elle n'a aucun effet architectural.
            break

        case 0x1F:  // le NOP long, celui que les compilateurs sèment partout
            _ = try decodeFields(instruction)

        case 0xAE:  // les barrières mémoire, et l'état de la virgule flottante
            let extension_ = (instruction.modrm ?? 0) >> 3 & 0x07
            guard (instruction.modrm ?? 0) >> 6 != 0b11 else {
                // MFENCE, LFENCE, SFENCE : un seul cœur, rien à ordonner.
                guard extension_ >= 5 else {
                    throw Fault.unsupported("0F AE /\(extension_) en registre")
                }
                return
            }
            let fields = try decodeFields(instruction)
            guard memory != nil else { throw Fault.unsupported("0F AE sans mémoire") }
            switch extension_ {
            case 0: try saveFloatingPointState()
            case 1: try restoreFloatingPointState()
            case 2:  // LDMXCSR
                mxcsr = UInt32(truncatingIfNeeded: try readRM(fields, 4))
            case 3:  // STMXCSR
                try writeRM(fields, 4, UInt64(mxcsr))
            // Sous 66, F2 ou F3, ce sont d'autres instructions (`ptwrite`…).
            case 4 where instruction.prefixMask & Self.mandatoryPrefixes == 0:  // XSAVE et XSAVE64
                try saveExtendedState()
            case 5 where instruction.prefixMask & Self.mandatoryPrefixes == 0:  // XRSTOR et XRSTOR64
                try restoreExtendedState()
            case 7:
                // CLFLUSH et CLFLUSHOPT : vider une ligne de cache. Il n'y a
                // pas de cache ici, donc rien à vider — mais refuser ces
                // deux-là arrêterait net un noyau qui repose ses permissions
                // de page, et `CPUID` ne les annonce pas seulement pour que
                // personne ne les demande : un noyau qui les trouve les
                // utilise sans prévenir.
                _ = try? readRM(fields, 1)
            default:
                throw Fault.unsupported("0F AE /\(extension_) en mémoire")
            }

        case 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F:  // Jcc long
            if condition(opcode) { branch(instruction, Self.signExtend(instruction.immediate, 4)) }

        case 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F:  // CMOVcc : une écriture qui n'a peut-être pas lieu
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            // Le mouvement conditionnel écrit **toujours** en 32 bits, même
            // quand la condition est fausse : le haut du registre est mis à
            // zéro dans les deux cas. C'est une conséquence de la règle
            // d'écriture 32 bits, pas une exception à elle.
            let value = condition(opcode) ? try readRM(fields, size) : readReg(fields, size)
            writeReg(fields, size, value)

        case 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F:  // SETcc
            let fields = try decodeFields(instruction)
            try writeRM(fields, 1, condition(opcode) ? 1 : 0)

        case 0xA3, 0xAB, 0xB3, 0xBB:  // BT, BTS, BTR, BTC — le bit est nommé par un registre
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            // **Le décalage n'est pas borné quand la destination est en
            // mémoire.** C'est la forme « chaîne de bits » : le numéro est
            // signé, il désigne un bit n'importe où autour de l'adresse, et le
            // processeur va chercher le mot qui le contient. Le réduire au
            // modulo, comme pour un registre, replierait tous les bits d'un
            // tableau de bits dans son premier mot.
            //
            // C'est ce qui arrivait, et un vrai noyau l'a montré : Linux tient
            // ses vecteurs d'interruption réservés dans un tableau de 256
            // bits, et posait ceux de 0xEC à 0xFF avec cette instruction. Ils
            // atterrissaient dans le premier mot, donc aux numéros 44 et 48 à
            // 63 — c'est-à-dire pile sur les vecteurs des interruptions ISA,
            // que le noyau croyait alors déjà pris. Il ne posait plus de porte
            // pour l'horloge, et attendait un battement qui ne pouvait plus
            // arriver.
            let raw = Int64(bitPattern: readReg(fields, size))
            let bits = Int64(8 * size)
            if fields.mod != 0b11 {
                // La division est **arrondie vers le bas**, pour que les
                // numéros négatifs descendent d'un mot au lieu de remonter.
                let word = raw >= 0 ? raw / bits : ((raw &+ 1) / bits) &- 1
                lastAddress = lastAddress &+ UInt64(bitPattern: word &* Int64(size))
            }
            let offset = UInt64(bitPattern: raw &- (raw >= 0
                ? (raw / bits) &* bits : (((raw &+ 1) / bits) &- 1) &* bits))
            try bit(Int((opcode >> 3) & 0x03), fields, size, offset & UInt64(bits - 1))

        case 0xBA:  // le groupe 8 : les mêmes, avec un immédiat
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            let offset = (instruction.immediate & 0xFF) & UInt64(8 * size - 1)
            try bit(Int((instruction.modrm! >> 3) & 0x07) - 4, fields, size, offset)

        case 0xA4, 0xA5, 0xAC, 0xAD:  // SHLD et SHRD
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            let count = (opcode == 0xA4 || opcode == 0xAC)
                ? (instruction.immediate & 0xFF)
                : (registers.read(1) & 0xFF)
            try probeWrite(fields, size)
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
            let fields = try decodeFields(instruction)
            writeReg(fields, size, multiplyTruncating(readReg(fields, size),
                                                      try readRM(fields, size), size))

        case 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF:  // BSWAP : renverser les octets d'un registre
            let size = Self.operandSize(instruction, byteForm: false)
            let index = Int(((instruction.rex ?? 0) & 0x01) << 3 | (opcode & 0x07))
            let value = read(index, size, highByte: false)
            // En trente-deux bits, le renversement porte sur ces quatre
            // octets-là ; renverser les huit puis tronquer rendrait zéro.
            write(index, size, highByte: false, size == 8
                ? value.byteSwapped
                : UInt64(UInt32(truncatingIfNeeded: value).byteSwapped))

        case 0xB0, 0xB1:  // CMPXCHG
            // La primitive dont toutes les serrures du noyau sont faites.
            // `LOCK` n'ajoute rien ici : un seul cœur, rien à exclure.
            let size = Self.operandSize(instruction, byteForm: opcode == 0xB0)
            let fields = try decodeFields(instruction)
            let destination = try readRM(fields, size)
            let accumulator = read(0, size, highByte: false)
            // Les drapeaux sont ceux d'une comparaison, dans **cet** ordre :
            // l'accumulateur moins la destination.
            let difference = subtract(accumulator, destination, size)
            setResultFlags(difference, size)
            if flags & Flag.zero != 0 {
                try writeRM(fields, size, readReg(fields, size))
            } else {
                // L'accumulateur reçoit ce qu'il n'attendait pas — c'est ce qui
                // permet au noyau de réessayer sans relire.
                write(0, size, highByte: false, destination)
            }

        case 0x77:  // EMMS
            guard instruction.vexCount == 0 else { throw Self.unknownTwoByte(opcode) }
            // Les huit registres de la pile x87 marqués vides, comme après une
            // série d'instructions MMX. Linux l'exécute sur un processeur AMD
            // à chaque restauration de l'état flottant, entre `FNCLEX` et un
            // `FILD` factice : c'est le contournement de « FXSAVE leak ».
            x87Tags = 0xFFFF

        case 0xC7:  // CMPXCHG8B
            guard (try? Self.fields(instruction))?.reg == 1 else { throw Self.unknownTwoByte(opcode) }
            // Le même échange que `CMPXCHG`, sur huit octets et deux paires de
            // registres : EDX:EAX attendus, ECX:EBX à ranger. C'est ce que
            // promet le bit CX8 de CPUID, que la glibc exige pour démarrer.
            // Avec REX.W, c'est `CMPXCHG16B` (voir `X86SSE42.swift`).
            let fields = try decodeFields(instruction)
            guard fields.mod != 0b11 else { throw Fault.unsupported("CMPXCHG8B sur un registre") }
            if (instruction.rex ?? 0) & 0x08 != 0 {
                try compareExchange16(fields)
                return
            }
            let current = try readMemory(lastAddress, 8)
            let expected = (registers.read(2) & 0xFFFF_FFFF) << 32 | (registers.read(0) & 0xFFFF_FFFF)
            if current == expected {
                try writeMemory(lastAddress, 8, (registers.read(1) & 0xFFFF_FFFF) << 32 | (registers.read(3) & 0xFFFF_FFFF))
                flags |= Flag.zero
            } else {
                // Les moitiés lues remplacent EAX et EDX, hauts effacés comme
                // toute écriture de trente-deux bits.
                registers[0] = current & 0xFFFF_FFFF
                registers[2] = current >> 32
                flags &= ~Flag.zero
            }

        case 0xC0, 0xC1:  // XADD : échanger, puis additionner
            // **La mémoire d'abord, le registre ensuite.** Le registre source
            // recevait l'ancienne valeur *avant* l'écriture en mémoire ; quand
            // celle-ci fautait — la page venait d'être partagée par un
            // `fork()` et n'était plus inscriptible —, le noyau copiait la
            // page et rejouait l'instruction avec le registre déjà écrasé :
            // la reprise additionnait la destination à elle-même. C'est ainsi
            // que le verrou de musl passait de 0xBFFFFFFF à 0x7FFFFFFE au lieu
            // de 0x3FFFFFFE, et que nlplug-findfs s'endormait sur un
            // `futex(verrou, WAIT, -1)` que personne ne réveillerait.
            let size = Self.operandSize(instruction, byteForm: opcode == 0xC0)
            let fields = try decodeFields(instruction)
            try probeWrite(fields, size)
            let destination = try readRM(fields, size)
            let source = readReg(fields, size)
            try writeRM(fields, size, add(destination, source, size))
            writeReg(fields, size, destination)

        case 0xB6, 0xB7:  // MOVZX
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            writeReg(fields, size, try readRM(fields, opcode == 0xB6 ? 1 : 2))

        case 0xBE, 0xBF:  // MOVSX
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            let source = opcode == 0xBE ? 1 : 2
            writeReg(fields, size, Self.signExtend(try readRM(fields, source), source)
                & Self.mask(size))

        case 0xB8:  // POPCNT
            guard instruction.hasPrefix(0xF3) else { throw Self.unknownTwoByte(opcode) }
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
            let source = try readRM(fields, size)
            writeReg(fields, size, UInt64(source.nonzeroBitCount))
            flags &= ~Flag.arithmetic
            set(Flag.zero, source == 0)

        case 0xBC where instruction.hasPrefix(0xF3), 0xBD where instruction.hasPrefix(0xF3):
            // TZCNT et LZCNT : BSF et BSR sous F3, mais une source nulle rend
            // la largeur, et CF le dit. Voir `X86BMI.swift`.
            try countZeros(instruction, leading: opcode == 0xBD)

        case 0xBC, 0xBD:  // BSF et BSR : le premier bit à un, par un bout ou l'autre
            let size = Self.operandSize(instruction, byteForm: false)
            let fields = try decodeFields(instruction)
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
            throw Self.unknownTwoByte(opcode)
        }
    }

    /// La faute d'un octet `0F` que personne ne prend, à part : elle sert à
    /// `default` et aux cas dont la forme ne convient pas.
    @inline(never)
    static func unknownTwoByte(_ opcode: UInt8) -> Fault {
        .unsupported("l'opcode 0F \(String(format: "%02X", opcode))")
    }

    /// Le strict minimum d'x87 : **trois** instructions, et rien d'autre.
    ///
    /// Linux détecte le coprocesseur en exécutant `fninit`, puis en rangeant le
    /// mot d'état et le mot de contrôle et en regardant ce qu'il obtient. C'est
    /// la séquence qui arrête ce cœur après un demi-million d'instructions de
    /// décompression — et c'est **du vrai code noyau**, pas des données prises
    /// pour du code : `db e3 / dd 7c 24 0e / d9 7c 24 08` se désassemble
    /// exactement en `fninit ; fnstsw ; fnstcw`.
    ///
    /// Ces trois-là sont donc rendues fidèlement : après `fninit`, le mot
    /// d'état vaut zéro et le mot de contrôle 0x37F, ce qui est la valeur
    /// qu'un vrai coprocesseur pose. **Aucune arithmétique x87 n'existe** ; si
    /// l'invité en tente une, elle est refusée par son nom, bruyamment. Mieux
    /// vaut un refus au bon endroit qu'un calcul faux.
    mutating func minimalX87(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        let modrm = instruction.modrm ?? 0
        let extension_ = (modrm >> 3) & 0x07
        // FNINIT : db e3, la seule forme qui nous intéresse sur cet octet.
        if opcode == 0xDB && modrm == 0xE3 {
            x87Status = 0
            x87Control = 0x037F
            return
        }
        let fields = try decodeFields(instruction)
        // FNSTSW en mémoire : dd /7. FNSTCW : d9 /7.
        if opcode == 0xDD && extension_ == 7 {
            try writeRM(fields, 2, UInt64(x87Status))
            return
        }
        if opcode == 0xD9 && extension_ == 7 {
            try writeRM(fields, 2, UInt64(x87Control))
            return
        }
        if opcode == 0xD9 && extension_ == 5 {  // FLDCW
            x87Control = UInt16(truncatingIfNeeded: try readRM(fields, 2))
            return
        }
        throw Fault.unsupported(
            "une instruction x87 : \(String(format: "%02X", opcode)) /\(extension_)")
    }

    /// Les opérations sur chaînes : copier, remplir, lire, comparer, en
    /// avançant ou en reculant selon le drapeau de direction, et
    /// éventuellement répétées jusqu'à ce que RCX s'épuise.
    ///
    /// Un noyau s'en sert pour effacer sa propre section BSS avant tout le
    /// reste ; sans elles il n'arrive pas à sa première ligne de C.
    mutating func stringOperation(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        guard memory != nil else { throw Fault.unsupported("une chaîne sans mémoire") }
        let byteForm = opcode & 1 == 0
        let size = Self.operandSize(instruction, byteForm: byteForm)
        let step = UInt64(bitPattern: flags & Flag.direction != 0 ? -Int64(size) : Int64(size))
        let repeated = instruction.hasPrefix(0xF3) || instruction.hasPrefix(0xF2)
        let whileEqual = instruction.hasPrefix(0xF3)

        var count = repeated ? registers.read(1) : 1
        let comparing = opcode == 0xA6 || opcode == 0xA7 || opcode == 0xAE || opcode == 0xAF
        while count > 0 {
            // **Une page à la fois quand c'est possible** : voir `bulkString`.
            if repeated && count > 1, try bulkString(opcode, size, &count) { continue }
            switch opcode {
            case 0xA4, 0xA5:  // MOVS : de RSI vers RDI
                let value = try readMemory(registers.read(6), size)
                try writeMemory(registers.read(7), size, value)
                registers[6] = registers.read(6) &+ step
                registers[7] = registers.read(7) &+ step
            case 0xA6, 0xA7:  // CMPS
                let left = try readMemory(registers.read(6), size)
                let right = try readMemory(registers.read(7), size)
                _ = subtract(left, right, size)
                registers[6] = registers.read(6) &+ step
                registers[7] = registers.read(7) &+ step
            case 0xAA, 0xAB:  // STOS : l'accumulateur vers RDI
                try writeMemory(registers.read(7), size, read(0, size, highByte: false))
                registers[7] = registers.read(7) &+ step
            case 0xAC, 0xAD:  // LODS : de RSI vers l'accumulateur
                write(0, size, highByte: false, try readMemory(registers.read(6), size))
                registers[6] = registers.read(6) &+ step
            default:  // SCAS : comparer l'accumulateur à ce qui est en RDI
                let value = try readMemory(registers.read(7), size)
                _ = subtract(read(0, size, highByte: false), value, size)
                registers[7] = registers.read(7) &+ step
            }
            count -= 1
            if repeated {
                registers[1] = count
                // Les deux comparaisons — CMPS et SCAS — s'arrêtent aussi sur
                // le drapeau de zéro, et dans le sens que le préfixe dit.
                if comparing && ((flags & Flag.zero != 0) != whileEqual) { break }
            }
        }
    }

    /// **`REP MOVS` et `REP STOS` par pages entières**, au lieu d'un élément à
    /// la fois.
    ///
    /// Le `memcpy` de musl est un `rep movsq`, et un noyau efface et recopie
    /// ses pages de la même façon : chaque élément traduisait ses deux
    /// adresses et repassait par les bornes de la mémoire. Ici, le morceau qui
    /// tient dans la page de la source **et** dans celle de la destination est
    /// traduit une fois, dans l'ordre des accès d'un élément — la lecture,
    /// puis l'écriture —, puis copié ou rempli d'un coup.
    ///
    /// **Ce que l'invité voit ne change pas.** Une faute ne tombe qu'à une
    /// frontière de page, donc RSI, RDI et RCX disent exactement ce qui a été
    /// fait, comme après le même nombre d'éléments un par un. Restent à
    /// l'ancien chemin, qui rend `false` : le sens arrière, un élément à
    /// cheval sur deux pages, un morceau qui touche un périphérique plutôt que
    /// la RAM, le témoin d'adresse armé (il veut voir chaque accès), et une
    /// copie dont la destination commence **dans** la source, plus haut —
    /// l'élément un par un y répète un motif, ce que `memmove` ne ferait pas.
    mutating func bulkString(_ opcode: UInt8, _ size: Int, _ count: inout UInt64) throws -> Bool {
        let moving = opcode == 0xA4 || opcode == 0xA5
        guard moving || opcode == 0xAA || opcode == 0xAB,
              flags & Flag.direction == 0, watchedAddress == nil,
              let memory = memoryReference?.takeUnretainedValue()
        else { return false }
        let destination = registers.read(7)
        var room = 0x1000 - Int(destination & 0xFFF)
        let source = registers.read(6)
        if moving { room = min(room, 0x1000 - Int(source & 0xFFF)) }
        let elements = min(count, UInt64(room / size))
        guard elements > 1 else { return false }
        let length = Int(elements) * size
        // Les traductions, dans l'ordre d'un élément : la source d'abord.
        let from = moving ? memory.offset(try translate(source, .read), length) : nil
        guard let to = memory.offset(try translate(destination, .write), length),
              !moving || from != nil
        else { return false }
        let target = memory.bytes + to
        if let from {
            guard to <= from || to >= from + length else { return false }
            UnsafeMutableRawPointer(target).copyMemory(
                from: UnsafeRawPointer(memory.bytes + from), byteCount: length)
            registers[6] = source &+ UInt64(length)
        } else {
            let value = read(0, size, highByte: false)
            switch size {
            case 1: target.update(repeating: UInt8(truncatingIfNeeded: value), count: length)
            default:
                let raw = UnsafeMutableRawPointer(target)
                for index in 0..<Int(elements) {
                    let at = raw + index * size
                    switch size {
                    case 2: at.storeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, as: UInt16.self)
                    case 4: at.storeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, as: UInt32.self)
                    default: at.storeBytes(of: value.littleEndian, as: UInt64.self)
                    }
                }
            }
        }
        registers[7] = destination &+ UInt64(length)
        count -= elements
        registers[1] = count
        return true
    }

    /// Sauter : la destination d'un saut relatif se compte depuis la **fin**
    /// de l'instruction, pas depuis son début. C'est l'erreur d'un octet la
    /// plus classique de l'architecture.
    mutating func branch(_ instruction: X86Instruction, _ displacement: UInt64) {
        rip = rip &+ UInt64(instruction.length) &+ displacement
        jumped = true
    }

    /// Les ports : le série, les deux 8259 et le 8253.
    /// **Un port se lit et s'écrit en un, deux ou quatre octets**, et jamais
    /// en huit : `REX.W` ne dit rien ici, seul le préfixe de taille compte.
    /// La largeur était figée à quatre, ce qui suffisait à un port série d'un
    /// octet et se voyait dès qu'un périphérique attendait un mot de deux —
    /// le pilote virtio écrit le numéro de sa file ainsi.
    static func portSize(_ instruction: X86Instruction, byteForm: Bool) -> Int {
        if byteForm { return 1 }
        return instruction.hasPrefix(0x66) ? 2 : 4
    }

    mutating func portWrite(_ port: UInt16, _ size: Int, _ value: UInt64) {
        let byte = UInt8(truncatingIfNeeded: value)
        switch port {
        // Le port série, celui par lequel un noyau Linux dit ses premiers
        // mots — et par lequel, une fois sondé, l'espace utilisateur parle.
        case Self.serialBase...(Self.serialBase &+ 7):
            serialWrite(port &- Self.serialBase, byte)

        // L'horloge CMOS : l'index, puis la donnée. Voir `X86RealTimeClock`.
        case X86RealTimeClock.indexPort, X86RealTimeClock.dataPort:
            devices.clock.write(port, byte)

        // Le bus PCI : une adresse, puis une donnée. Sans ces deux ports, le
        // noyau conclut « PCI: System does not support PCI » et n'énumère rien.
        case X86PCIHost.addressPort:
            memory?.bus?.writeAddress(UInt32(truncatingIfNeeded: value))
        case X86PCIHost.dataPort...(X86PCIHost.dataPort &+ 3):
            guard let bus = memory?.bus else { break }
            let within = UInt32(port &- X86PCIHost.dataPort)
            if size == 4 && within == 0 {
                bus.writeConfiguration(UInt32(truncatingIfNeeded: value), 4, 0)
            } else {
                // Une écriture partielle : relire, remplacer les octets visés,
                // réécrire. Le noyau écrit la ligne d'interruption ainsi.
                var word = bus.configuration()
                for byte in 0..<UInt32(size) {
                    let shift = 8 * (within &+ byte)
                    guard shift < 32 else { break }
                    word &= ~(UInt32(0xFF) << shift)
                    word |= (UInt32(truncatingIfNeeded: value >> (8 * UInt64(byte))) & 0xFF) << shift
                }
                bus.writeConfiguration(word, size, within)
            }

        // Le 8259 maître. La commande, d'abord : le bit 4 lance une
        // initialisation, et les trois octets qui suivent arrivent par le port
        // de données — sans compter les étapes, le premier serait pris pour un
        // masque.
        case 0x20:
            if byte & 0x10 != 0 {
                devices.primary.initialisationStep = 1
            } else if byte & 0x08 != 0 {
                devices.primary.readsService = byte & 0x01 != 0
            } else if byte & 0x20 != 0 {
                // Fin d'interruption. **Deux formes, et Linux envoie la
                // seconde** : `mask_and_ack_8259A` écrit `0x60 + irq`, qui
                // nomme la ligne à retirer du service. Prendre la plus
                // prioritaire à sa place laisserait la ligne nommée en service
                // pour toujours, et tout ce qui lui est inférieur n'entrerait
                // plus jamais — sur un PC, « inférieur au port série »
                // comprend le disque.
                if byte & 0x40 != 0 {
                    devices.primary.service &= ~(1 << (byte & 0x07))
                } else {
                    let service = devices.primary.service
                    if service != 0 {
                        devices.primary.service &= ~(1 << service.trailingZeroBitCount)
                    }
                }
            }
        case 0x21:
            switch devices.primary.initialisationStep {
            case 1:
                devices.primary.vectorBase = byte & 0xF8
                devices.primary.initialisationStep = 2
            case 2, 3:
                devices.primary.initialisationStep += 1
                if devices.primary.initialisationStep > 3 { devices.primary.initialisationStep = 0 }
            default:
                devices.primary.mask = byte
            }
        case 0xA0:
            if byte & 0x10 != 0 { devices.secondary.initialisationStep = 1 }
        case 0xA1:
            if devices.secondary.initialisationStep != 0 {
                if devices.secondary.initialisationStep == 1 {
                    devices.secondary.vectorBase = byte & 0xF8
                }
                devices.secondary.initialisationStep += 1
                if devices.secondary.initialisationStep > 3 {
                    devices.secondary.initialisationStep = 0
                }
            } else {
                devices.secondary.mask = byte
            }

        // Le 8253. Seul le canal zéro bat ; les autres se laissent écrire sans
        // rien produire, ce qui suffit à ne pas arrêter un noyau qui les
        // programme pour le haut-parleur.
        case 0x61:
            // Le port B : le bit 0 ouvre la porte du canal deux. C'est par là
            // que Linux étalonne son compteur de cycles — il lance le canal,
            // puis attend que le bit 5 lui dise que c'est fini.
            let opened = byte & 0x01 != 0
            if opened && !devices.speakerGate { devices.speakerStartedAt = ticks }
            devices.speakerGate = opened
        case 0x42:
            if devices.speakerWriteHighNext {
                devices.speakerReload = (devices.speakerReload & 0x00FF) | (UInt16(byte) << 8)
                devices.speakerWriteHighNext = false
                devices.speakerStartedAt = ticks
            } else {
                devices.speakerReload = (devices.speakerReload & 0xFF00) | UInt16(byte)
                devices.speakerWriteHighNext = true
            }
        case 0x43 where byte >> 6 == 2:
            devices.speakerWriteHighNext = false
            devices.speakerReadHighNext = false
        case 0x43:
            guard byte >> 6 == 0 else { return }
            if (byte >> 4) & 0x03 == 0 {
                // Commande de verrouillage : figer le compte pour qu'une
                // lecture en deux octets voie la **même** valeur deux fois.
                devices.latched = devices.count(at: ticks)
                devices.readHighNext = false
            } else {
                devices.writeHighNext = false
                devices.readHighNext = false
                devices.latched = nil
                // Les bits 1 à 3 : le mode. 0 et 4 (et leurs variantes à
                // porte, 1 et 5) comptent une fois ; 2 et 3 battent.
                devices.oneShot = (byte >> 1) & 0x03 <= 1
            }
        case 0x40:
            if devices.writeHighNext {
                devices.reload = (devices.reload & 0x00FF) | (UInt16(byte) << 8)
                devices.writeHighNext = false
                // Un rechargement repart de maintenant, et ce qui était dû
                // avant ne l'est plus.
                devices.reloadedAt = ticks
                devices.raised = 0
            } else {
                devices.reload = (devices.reload & 0xFF00) | UInt16(byte)
                devices.writeHighNext = true
            }

        default:
            // La fenêtre de ports d'un disque, là où le noyau l'a placée.
            if let found = memory?.bus?.device(atPort: port), let memory {
                found.device.writePort(found.offset, size, value, memory)
            }
        }
    }

    mutating func portRead(_ port: UInt16, _ size: Int = 4) -> UInt64 {
        switch port {
        case Self.serialBase...(Self.serialBase &+ 7):
            return UInt64(serialRead(port &- Self.serialBase))
        case X86PCIHost.addressPort:
            return UInt64(memory?.bus?.address ?? 0)
        // La fenêtre de ports d'un disque, là où le noyau l'a placée.
        case let window where memory?.bus?.device(atPort: window) != nil:
            guard let found = memory?.bus?.device(atPort: window) else { return 0 }
            return found.device.readPort(found.offset, size)
        case X86PCIHost.dataPort...(X86PCIHost.dataPort &+ 3):
            guard let bus = memory?.bus else { return 0xFFFF_FFFF }
            let word = bus.configuration()
            let shift = 8 * UInt64(port &- X86PCIHost.dataPort)
            return (UInt64(word) >> shift) & Self.mask(size)
        case 0x20:
            return UInt64(devices.primary.readsService
                ? devices.primary.service : devices.primary.request)
        // Le masque relu. C'est **toute** la sonde de Linux : il écrit une
        // valeur dans ce port et la relit ; si elle ne revient pas, il conclut
        // qu'il n'y a pas de contrôleur et n'a plus personne à qui demander
        // l'interruption zéro. C'est le message `Using NULL legacy PIC`.
        case 0x21: return UInt64(devices.primary.mask)
        case 0xA0:
            return UInt64(devices.secondary.readsService
                ? devices.secondary.service : devices.secondary.request)
        case 0xA1: return UInt64(devices.secondary.mask)
        case 0x61:
            // Le bit 5 : « le canal deux est arrivé à zéro ». Le bit 4 change
            // à chaque rafraîchissement mémoire sur un vrai PC ; le faire
            // basculer évite qu'un noyau qui l'attend tourne indéfiniment.
            return (devices.speakerFinished(at: ticks) ? 0x20 : 0)
                | (ticks & 1) << 4
                | (devices.speakerGate ? 1 : 0)
        case X86RealTimeClock.indexPort, X86RealTimeClock.dataPort:
            return UInt64(devices.clock.read(port))
        case 0x42:
            let count = devices.speakerCount(at: ticks)
            defer { devices.speakerReadHighNext.toggle() }
            return UInt64(devices.speakerReadHighNext ? count >> 8 : count & 0xFF)
        case 0x40:
            let value = devices.latched ?? devices.count(at: ticks)
            defer {
                devices.readHighNext.toggle()
                if !devices.readHighNext { devices.latched = nil }
            }
            return UInt64(devices.readHighNext ? value >> 8 : value & 0xFF)
        default: return 0
        }
    }

    /// L'adresse qu'un ModRM désigne. `LEA` la calcule sans la lire ; tout le
    /// reste la lit ou l'écrit.
    /// `segmented` dit si la base du segment entre dans le calcul. Elle y
    /// entre partout **sauf** pour `LEA`, qui ne lit rien en mémoire et ne
    /// traverse donc pas l'unité de segmentation.
    ///
    /// Inlinée : voir `read(_:_:highByte:)`.
    ///
    /// **`mutating`, pour lire les registres en place** : voir
    /// `X86Registers.read(_:)`.
    @inline(__always)
    mutating func effectiveAddress(
        _ instruction: X86Instruction, _ fields: Fields, segmented: Bool = true
    ) throws -> UInt64 {
        guard instruction.modrm != nil, fields.mod != 0b11 else {
            throw Fault.unsupported("une adresse calculée depuis un registre")
        }
        return memoryAddress(instruction, segmented: segmented)
    }

    /// Le calcul lui-même, pour un ModRM dont on sait déjà qu'il désigne la
    /// mémoire : sans garde, donc sans faute à construire. C'est ce qui le
    /// laisse s'inliner chez la trentaine d'appelants de `decodeFields`.
    @inline(__always)
    mutating func memoryAddress(_ instruction: X86Instruction, segmented: Bool = true) -> UInt64 {
        // La forme est dépliée au décodage : voir `X86Instruction.baseField`.
        var address = (segmented ? segmentBase(instruction) : 0)
            &+ UInt64(bitPattern: instruction.displacement)
        let base = instruction.baseField
        if base < 16 {
            address &+= registers.read(Int(base))
        } else if base == X86Instruction.ripRelative {
            // Relatif à RIP : l'adresse suit l'instruction entière.
            address &+= rip &+ UInt64(instruction.length)
        }
        let index = instruction.indexField
        if index < 16 {
            address &+= registers.read(Int(index)) << UInt64(instruction.scaleShift)
        }
        return address
    }

    /// La base du segment que l'instruction a nommé, ou zéro.
    ///
    /// **En mode long il n'en reste que deux.** ES, CS, SS et DS ont une base
    /// forcée à zéro, et le processeur ignore leurs préfixes ; FS et GS, non,
    /// et leur base ne vient plus d'un descripteur mais d'un MSR. C'est ce que
    /// tout noyau x86-64 utilise pour ses variables par processeur : `%gs:` en
    /// tête d'un accès, et la base fait le reste. Un cœur qui ignore le
    /// préfixe lit donc l'adresse **sans** la base — c'est-à-dire au début de
    /// la mémoire, là où il n'y a rien de ce qu'on cherchait.
    @inline(__always)
    func segmentBase(_ instruction: X86Instruction) -> UInt64 {
        guard instruction.prefixMask & Self.segmentPrefixes != 0 else { return 0 }
        // Les champs, pas l'indice : voir `X86ModelSpecific`.
        return (instruction.hasPrefix(0x65) ? system.modelSpecific.gsBase : system.modelSpecific.fsBase) ?? 0
    }

    /// Les bits de `%fs:` et `%gs:` dans le masque de préfixes (le huitième et
    /// le neuvième de `X86Decoder.prefixOrder`), écrits en constante.
    /// **Pas un `static let` calculé depuis la table** : il se payait d'un
    /// `swift_once` à chaque adresse calculée, ce que callgrind montrait au
    /// milieu de `decodeFields`. `X86RegistersTests` vérifie qu'il dit la même
    /// chose que la table.
    static var segmentPrefixes: UInt16 { 0x0180 }

    /// BT, BTS, BTR, BTC : lire le bit, puis éventuellement le changer.
    mutating func bit(_ kind: Int, _ fields: Fields, _ size: Int, _ offset: UInt64) throws {
        // BT seul ne réécrit rien ; les trois autres si, et leur retenue est
        // posée avant l'écriture.
        if kind != 0 { try probeWrite(fields, size) }
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
