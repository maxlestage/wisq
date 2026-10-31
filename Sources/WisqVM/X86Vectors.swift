import Foundation

// **Les seize registres XMM, et rien que le déplacement de bits.**
//
// C'est le noyau qui a nommé cette tranche. Après le TSS, Linux arrive jusqu'à
// son espace utilisateur — 2 712 254 848 instructions, l'initramfs déballé —
// puis s'arrête sur l'opcode `0F 6E` à une adresse en `0x7f…` : `MOVD` entre
// un registre général et un registre SSE, dans le chargeur dynamique de musl.
// La bibliothèque C se sert de SSE dans ses fonctions de chaîne, et elle le
// fait **avant** son premier appel système.
//
// **Ce qui n'est pas là, et pourquoi.** Aucune arithmétique en virgule
// flottante. Sur les 8 663 instructions vectorielles du chargeur, celles qui
// calculent — `mulsd`, `addsd`, `cvtsi2sd` — appartiennent au formatage des
// nombres dans `printf`, qui ne tourne pas au démarrage. Déplacer des bits et
// calculer sont deux décisions différentes ; écrire un moteur de virgule
// flottante que rien n'appelle encore serait exactement ce que ce dépôt évite.
// Le jour où la machine le demandera, elle le dira en s'arrêtant dessus.
//
// **Aucune de ces instructions ne touche un drapeau**, et l'oracle le tient :
// les états d'entrée font varier les six drapeaux de l'arithmétique et exigent
// qu'ils reviennent intacts.
extension X86Core {
    /// Le bas et le haut d'un registre XMM.
    func vector(_ index: Int) -> (low: UInt64, high: UInt64) {
        (vectors[2 * index], vectors[2 * index + 1])
    }

    mutating func setVector(_ index: Int, _ low: UInt64, _ high: UInt64) {
        vectors[2 * index] = low
        vectors[2 * index + 1] = high
    }

    /// L'opérande r/m d'une instruction vectorielle : un registre XMM entier,
    /// ou `width` octets de mémoire.
    ///
    /// **La largeur ne concerne que la mémoire**, et le premier jet disait le
    /// contraire : il effaçait le haut quand la source était un registre lu sur
    /// huit octets. C'était sans effet — la seule forme qui lit huit octets
    /// d'un registre, `MOVQ xmm, xmm`, efface le haut de sa destination
    /// elle-même — et un sabotage l'a montré en ne cassant rien. Une branche
    /// qu'aucun cas ne peut atteindre est pire qu'absente : elle a l'air d'une
    /// règle et n'en est pas une. C'est à l'instruction de dire ce qu'elle
    /// garde ; la lecture, elle, rend ce qui est là.
    mutating func readVectorRM(_ fields: Fields, _ width: Int) throws -> (UInt64, UInt64) {
        guard fields.mod != 0b11 else { return vector(fields.rm) }
        guard memory != nil else { throw Fault.unsupported("un opérande vectoriel en mémoire") }
        // Deux, quatre ou huit octets : ce que l'instruction élargit ou
        // insère, et pas un de plus — le suivant peut être sur une page
        // absente.
        let low = try readMemory(lastAddress, min(width, 8))
        guard width == 16 else { return (low, 0) }
        return (low, try readMemory(lastAddress &+ 8, 8))
    }

    /// Et l'écriture correspondante, pour la même raison : vers un registre
    /// c'est les cent vingt-huit bits, et la seule forme qui n'en écrit que
    /// soixante-quatre — `MOVQ xmm, xmm` — le fait chez elle, parce qu'elle
    /// doit aussi effacer le haut.
    mutating func writeVectorRM(
        _ fields: Fields, _ width: Int, _ value: (low: UInt64, high: UInt64)
    ) throws {
        guard fields.mod != 0b11 else {
            setVector(fields.rm, value.low, value.high)
            return
        }
        guard memory != nil else { throw Fault.unsupported("un opérande vectoriel en mémoire") }
        try writeMemory(lastAddress, 8, value.low)
        if width == 16 {
            try writeMemory(lastAddress &+ 8, 8, value.high)
        }
    }

    /// Les instructions vectorielles que ce cœur exécute. Rend `false` quand
    /// l'opcode n'en est pas une, pour que le dispatch ordinaire continue.
    ///
    /// Le préfixe décide autant que l'opcode : `0F 6E` sans préfixe est une
    /// instruction MMX (voir `X86MMX.swift`), avec `66` c'est SSE, et ce
    /// fichier ne fait que le second.
    /// Le dire plutôt que de les confondre évite d'exécuter sur un registre
    /// XMM ce que le programme voulait faire sur un registre MMX.
    mutating func vectorInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws -> Bool {
        let operandSize = instruction.hasPrefix(0x66)
        let repeatFE = instruction.hasPrefix(0xF3)
        let repeatFD = instruction.hasPrefix(0xF2)
        // La largeur du pont entre les deux mondes : REX.W fait un mot de
        // soixante-quatre bits, sinon c'est trente-deux.
        let wide = (instruction.rex ?? 0) & 0x08 != 0

        switch opcode {
        case 0x6E where operandSize:  // MOVD/MOVQ r/m -> xmm
            let fields = try decodeFields(instruction)
            let value = try readRM(fields, wide ? 8 : 4)
            setVector(fields.reg, value, 0)

        case 0x7E where operandSize:  // MOVD/MOVQ xmm -> r/m
            let fields = try decodeFields(instruction)
            try writeRM(fields, wide ? 8 : 4, vector(fields.reg).low)

        case 0x7E where repeatFE:  // MOVQ xmm/m64 -> xmm, le haut effacé
            let fields = try decodeFields(instruction)
            let (low, _) = try readVectorRM(fields, 8)
            setVector(fields.reg, low, 0)

        case 0xD6 where operandSize:  // MOVQ xmm -> xmm/m64
            let fields = try decodeFields(instruction)
            let value = vector(fields.reg)
            // Vers un **registre**, le haut est effacé ; vers la mémoire, il
            // n'y a rien au-delà de huit octets à effacer. Le manuel les
            // sépare, et c'est le seul endroit où cette forme diffère d'un
            // simple rangement.
            if fields.mod == 0b11 {
                setVector(fields.rm, value.low, 0)
            } else {
                try writeVectorRM(fields, 8, value)
            }

        // Les déplacements de cent vingt-huit bits. `MOVDQA` et `MOVAPS`
        // exigent une adresse alignée là où `MOVDQU` et `MOVUPS` ne le
        // demandent pas ; ce cœur ne lève pas sur l'alignement, parce qu'il
        // n'a aucune façon de le signaler au programme aujourd'hui — et parce
        // qu'un accès non aligné qu'on laisse passer donne le bon résultat,
        // alors qu'un refus arrêterait un invité que la vraie machine n'aurait
        // pas arrêté.
        case 0x6F where operandSize || repeatFE:  // MOVDQA / MOVDQU, vers le registre
            let fields = try decodeFields(instruction)
            let value = try readVectorRM(fields, 16)
            setVector(fields.reg, value.0, value.1)

        case 0x7F where operandSize || repeatFE:  // MOVDQA / MOVDQU, depuis le registre
            let fields = try decodeFields(instruction)
            try writeVectorRM(fields, 16, vector(fields.reg))

        // `MOVAPS`/`MOVAPD` n'ont pas de forme préfixée par `F2` ou `F3` : les
        // deux octets se prennent donc sans condition. `MOVUPS`/`MOVUPD` en
        // ont, elles — `MOVSS` et `MOVSD`, qui sont *scalaires* et n'écrivent
        // qu'une partie du registre — et les confondre avec un déplacement de
        // cent vingt-huit bits écraserait ce que le programme voulait garder.
        case 0x28:  // MOVAPS / MOVAPD, vers le registre
            let fields = try decodeFields(instruction)
            let value = try readVectorRM(fields, 16)
            setVector(fields.reg, value.0, value.1)

        case 0x29:  // MOVAPS / MOVAPD, depuis le registre
            let fields = try decodeFields(instruction)
            try writeVectorRM(fields, 16, vector(fields.reg))

        case 0x10 where !repeatFE && !repeatFD:  // MOVUPS / MOVUPD
            let fields = try decodeFields(instruction)
            let value = try readVectorRM(fields, 16)
            setVector(fields.reg, value.0, value.1)

        case 0x11 where !repeatFE && !repeatFD:
            let fields = try decodeFields(instruction)
            try writeVectorRM(fields, 16, vector(fields.reg))

        // **`MOVSS` et `MOVSD`, dont la règle dépend de la source.** Ils
        // portent des noms de virgule flottante et ne calculent rien : ils
        // déplacent trente-deux ou soixante-quatre bits. Mais depuis la
        // **mémoire** le reste du registre est mis à zéro, tandis que depuis un
        // autre **registre** il est laissé tel quel. Confondre les deux écrase
        // ce que le programme voulait garder ; c'est l'oracle qui le dit, pas
        // une lecture.
        case 0x10 where repeatFE || repeatFD:  // vers le registre
            let fields = try decodeFields(instruction)
            let width = repeatFE ? 4 : 8
            if fields.mod == 0b11 {
                let source = vector(fields.rm)
                let mask = width == 4 ? UInt64(0xFFFF_FFFF) : UInt64.max
                let low = (vector(fields.reg).low & ~mask) | (source.low & mask)
                setVector(fields.reg, low, vector(fields.reg).high)
            } else {
                guard memory != nil else {
                    throw Fault.unsupported("un opérande vectoriel en mémoire")
                }
                setVector(fields.reg, try readMemory(lastAddress, width), 0)
            }

        case 0x11 where repeatFE || repeatFD:  // depuis le registre
            let fields = try decodeFields(instruction)
            let width = repeatFE ? 4 : 8
            let value = vector(fields.reg)
            if fields.mod == 0b11 {
                let mask = width == 4 ? UInt64(0xFFFF_FFFF) : UInt64.max
                let low = (vector(fields.rm).low & ~mask) | (value.low & mask)
                setVector(fields.rm, low, vector(fields.rm).high)
            } else {
                guard memory != nil else {
                    throw Fault.unsupported("un opérande vectoriel en mémoire")
                }
                try writeMemory(lastAddress, width, value.low)
            }

        // Les entrelacements. Chacun prend des morceaux de la même taille
        // alternativement dans la destination et la source, en commençant par
        // la destination — l'ordre est ce qu'un test doit fixer, parce que
        // l'inverse produit une valeur qui a l'air tout aussi plausible.
        case 0x60 where operandSize: try interleave(instruction, 1, high: false)
        case 0x61 where operandSize: try interleave(instruction, 2, high: false)
        case 0x62 where operandSize: try interleave(instruction, 4, high: false)
        case 0x6C where operandSize: try interleave(instruction, 8, high: false)
        case 0x68 where operandSize: try interleave(instruction, 1, high: true)
        case 0x69 where operandSize: try interleave(instruction, 2, high: true)
        case 0x6A where operandSize: try interleave(instruction, 4, high: true)
        case 0x6D where operandSize: try interleave(instruction, 8, high: true)
        // `UNPCKLPD` et `UNPCKHPD` sont les mêmes que sur des entiers de huit
        // octets : les mêmes bits déplacés pareil, un autre nom.
        case 0x14 where operandSize: try interleave(instruction, 8, high: false)
        case 0x15 where operandSize: try interleave(instruction, 8, high: true)
        // Sans préfixe, `UNPCKLPS` et `UNPCKHPS` : les mêmes bits que
        // `PUNPCKLDQ` et `PUNPCKHDQ`, par morceaux de quatre octets. systemd
        // 259 de Fedora 44 s'y arrêtait.
        case 0x14 where !repeatFE && !repeatFD: try interleave(instruction, 4, high: false)
        case 0x15 where !repeatFE && !repeatFD: try interleave(instruction, 4, high: true)

        case 0x12 where !repeatFE && !repeatFD:  // MOVHLPS / MOVLPS / MOVLPD
            let fields = try decodeFields(instruction)
            // `MOVLPD` est `MOVLPS` préfixé, et n'existe que depuis la mémoire :
            // entre registres, `66 0F 12` n'est rien.
            if operandSize && fields.mod == 0b11 { throw Fault.unsupported("66 0F 12 entre registres") }
            if fields.mod == 0b11 {
                // MOVHLPS : le haut de la source devient le bas de la
                // destination, et le haut de la destination ne bouge pas.
                vectors[2 * fields.reg] = vector(fields.rm).high
            } else {
                let (low, _) = try readVectorRM(fields, 8)
                vectors[2 * fields.reg] = low
            }

        // **Les déplacements de SSE3**, sans arithmétique. `MOVDDUP` diffuse
        // les soixante-quatre bits bas de la source (huit octets en mémoire,
        // non alignés) ; `MOVSLDUP` recopie chaque mot pair de trente-deux
        // bits sur l'impair qui le suit.
        case 0x12 where repeatFD:  // MOVDDUP
            let fields = try decodeFields(instruction)
            let (low, _) = try readVectorRM(fields, 8)
            setVector(fields.reg, low, low)

        case 0x12 where repeatFE:  // MOVSLDUP
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, source.0 & 0xFFFF_FFFF | source.0 << 32,
                      source.1 & 0xFFFF_FFFF | source.1 << 32)

        // `MOVSHDUP` : le frère de `MOVSLDUP`, chaque mot **impair** recopié
        // sur le pair qui le précède. Annoncé avec SSE3 et absent : un
        // programme qui le choisit sur la foi de CPUID s'arrêtait net.
        case 0x16 where repeatFE:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, source.0 >> 32 | source.0 & 0xFFFF_FFFF_0000_0000,
                      source.1 >> 32 | source.1 & 0xFFFF_FFFF_0000_0000)

        // `LDDQU` : un `MOVDQU` qui n'existe que depuis la mémoire.
        case 0xF0 where repeatFD:
            let fields = try decodeFields(instruction)
            guard fields.mod != 0b11 else { throw Fault.unsupported("F2 0F F0 entre registres") }
            let value = try readVectorRM(fields, 16)
            setVector(fields.reg, value.0, value.1)

        case 0x16 where !repeatFE && !repeatFD:  // MOVLHPS / MOVHPS / MOVHPD
            let fields = try decodeFields(instruction)
            if operandSize && fields.mod == 0b11 { throw Fault.unsupported("66 0F 16 entre registres") }
            if fields.mod == 0b11 {
                vectors[2 * fields.reg + 1] = vector(fields.rm).low
            } else {
                let (low, _) = try readVectorRM(fields, 8)
                vectors[2 * fields.reg + 1] = low
            }

        // Les rangements d'une moitié : le bas (`MOVLPS`, `MOVLPD`) ou le haut
        // (`MOVHPS`, `MOVHPD`) du registre, vers huit octets de mémoire. Ils
        // n'existent que vers la mémoire. La glibc d'Ubuntu 26.04 range ainsi
        // la moitié haute d'un registre, et le démarrage s'arrêtait là, à
        // 45,7 milliards d'instructions.
        case 0x13 where !repeatFE && !repeatFD, 0x17 where !repeatFE && !repeatFD:
            let fields = try decodeFields(instruction)
            guard fields.mod != 0b11 else {
                throw Fault.unsupported(String(format: "0F %02X entre registres", opcode))
            }
            let value = vector(fields.reg)
            try writeVectorRM(fields, 8, (opcode == 0x13 ? value.low : value.high, 0))

        // Le bit de signe de chaque élément, vers un registre général : quatre
        // pour `MOVMSKPS`, deux pour `MOVMSKPD`. La glibc s'en sert dans ses
        // fonctions de chaînes, sans rien calculer en virgule flottante : ce
        // sont des bits, pas des nombres.
        case 0x50 where !repeatFE && !repeatFD:
            let fields = try decodeFields(instruction)
            guard fields.mod == 0b11 else { throw Fault.unsupported("MOVMSKPS depuis la mémoire") }
            let value = vector(fields.rm)
            let mask = operandSize
                ? (value.low >> 63) | (value.high >> 63) << 1
                : (value.low >> 31) & 1 | (value.low >> 63) << 1 | ((value.high >> 31) & 1) << 2
                    | (value.high >> 63) << 3
            writeReg(fields, 4, mask)

        // Les rangements « non temporels » : la même chose qu'un `MOVAPS` ou
        // un `MOVDQA` vers la mémoire. L'indication de contourner le cache ne
        // veut rien dire pour un interprète ; l'écriture, si.
        case 0x2B where !repeatFE && !repeatFD, 0xE7 where operandSize:
            let fields = try decodeFields(instruction)
            guard fields.mod != 0b11 else { throw Fault.unsupported("un rangement non temporel vers un registre") }
            try writeVectorRM(fields, 16, vector(fields.reg))

        // Les quatre opérations logiques. Les noms entiers et flottants — PXOR
        // et XORPS, PAND et ANDPD — font le même travail sur les mêmes bits :
        // les distinguer serait inventer une différence que la machine n'a pas.
        case 0xEF where operandSize: try logic(instruction) { $0 ^ $1 }
        case 0xEB where operandSize: try logic(instruction) { $0 | $1 }
        case 0xDB where operandSize: try logic(instruction) { $0 & $1 }
        case 0xDF where operandSize: try logic(instruction) { ~$0 & $1 }
        case 0x57 where !repeatFE && !repeatFD: try logic(instruction) { $0 ^ $1 }
        case 0x56 where !repeatFE && !repeatFD: try logic(instruction) { $0 | $1 }
        case 0x54 where !repeatFE && !repeatFD: try logic(instruction) { $0 & $1 }
        case 0x55 where !repeatFE && !repeatFD: try logic(instruction) { ~$0 & $1 }

        // `SHUFPS` et `SHUFPD`. C'est le noyau qui les a nommées : Linux
        // s'arrête sur `0F C6` pendant l'initialisation de ses pilotes, et la
        // capture d'écran l'a montré avant que la CI le sache.
        //
        // Elles ne calculent rien. Malgré le nom flottant, ce sont quatre —
        // ou deux — morceaux recopiés à la place que dit l'immédiat, bit à
        // bit, sans jamais regarder ce que les bits signifient. Une valeur qui
        // n'est pas un nombre valide traverse intacte, et l'oracle le tient.
        //
        // La moitié basse vient toujours de la **destination**, la haute de la
        // **source** — l'inverse produirait une valeur tout aussi plausible,
        // et c'est le vrai processeur qui tranche dans la table.
        case 0xC6 where !repeatFE && !repeatFD:  // SHUFPS / SHUFPD
            let fields = try decodeFields(instruction)
            let destination = vector(fields.reg)
            let source = try readVectorRM(fields, 16)
            let control = UInt8(truncatingIfNeeded: instruction.immediate)
            if operandSize {
                // `SHUFPD` : un bit par moitié, et rien de plus.
                setVector(fields.reg,
                          control & 0x01 == 0 ? destination.low : destination.high,
                          control & 0x02 == 0 ? source.0 : source.1)
            } else {
                // `SHUFPS` : deux bits par mot de quatre octets. Les deux
                // premiers choisissent dans la destination, les deux suivants
                // dans la source — soit exactement le bas de ce que
                // `shuffleDoublewords` rend de chacune, avec sa moitié de
                // l'immédiat.
                let low = Self.shuffleDoublewords(destination, control & 0x0F).0
                let high = Self.shuffleDoublewords(
                    (low: source.0, high: source.1), control >> 4).0
                setVector(fields.reg, low, high)
            }

        // `PSHUFLW` et `PSHUFHW` : `PSHUFD` à l'échelle de seize bits, sur
        // une seule moitié. C'est un vrai démarrage qui les a demandées —
        // l'ISO `virt` d'Alpine s'arrêtait sur `0F 70` en installant ses
        // paquets, dans le zlib que `apk` charge pour les décompresser. La
        // moitié que l'instruction ne nomme pas est recopiée **depuis la
        // source**, pas gardée de la destination : c'est un déplacement
        // complet, et l'oracle départage les deux lectures.
        case 0x70 where repeatFD || repeatFE:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let control = UInt8(truncatingIfNeeded: instruction.immediate)
            if repeatFD {
                setVector(fields.reg, Self.shuffleWords(source.0, control), source.1)
            } else {
                setVector(fields.reg, source.0, Self.shuffleWords(source.1, control))
            }

        default: return false
        }
        return true
    }

    /// Les quatre mots de seize bits d'une moitié, remis dans l'ordre que dit
    /// l'immédiat, deux bits par position.
    static func shuffleWords(_ value: UInt64, _ control: UInt8) -> UInt64 {
        var result: UInt64 = 0
        for position in 0..<4 {
            let chosen = UInt64((control >> (2 * position)) & 0x03)
            result |= ((value >> (16 * chosen)) & 0xFFFF) << (16 * UInt64(position))
        }
        return result
    }

    /// L'entrelacement : des morceaux de `width` octets, pris alternativement
    /// dans la destination puis la source, depuis la moitié basse ou haute.
    private mutating func interleave(
        _ instruction: X86Instruction, _ width: Int, high: Bool
    ) throws {
        let fields = try decodeFields(instruction)
        let destination = vector(fields.reg)
        let source = try readVectorRM(fields, 16)
        let left = high ? destination.high : destination.low
        let right = high ? source.1 : source.0
        var result: [UInt64] = [0, 0]
        let count = 8 / width
        var position = 0
        for index in 0..<count {
            for value in [left, right] {
                let piece = width == 8
                    ? value
                    : (value >> (UInt64(index * width) * 8)) & ((1 << (UInt64(width) * 8)) - 1)
                result[position / 8] |= piece << (UInt64(position % 8) * 8)
                position += width
            }
        }
        setVector(fields.reg, result[0], result[1])
    }

    /// Une opération bit à bit entre la destination et la source, sur les deux
    /// moitiés.
    private mutating func logic(
        _ instruction: X86Instruction, _ operation: (UInt64, UInt64) -> UInt64
    ) throws {
        let fields = try decodeFields(instruction)
        let destination = vector(fields.reg)
        let source = try readVectorRM(fields, 16)
        setVector(fields.reg,
                  operation(destination.low, source.0),
                  operation(destination.high, source.1))
    }
}
