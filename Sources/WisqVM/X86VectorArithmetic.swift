import Foundation

// **L'arithmétique SSE2 entière : additionner, comparer, décaler.**
//
// C'est la machine qui a nommé cette tranche, comme les précédentes. Une fois
// le `push` fautif corrigé, `/init` vit — « Alpine Init 3.10.1-r0 », les
// pilotes chargés, le média de démarrage monté — et la course s'arrête sur
// `0F 76`, `PCMPEQD`, à trois milliards d'instructions.
//
// **Le cadrage vient d'un comptage.** En désassemblant les binaires
// réellement présents dans l'initramfs de l'invité et en comptant ce que ce
// cœur ne savait pas exécuter, il restait dix-sept mnémoniques : `paddd`
// (1 129 fois), `psrld` (634), `pslld` (522), `pshufd` (343), `psrlq` (125),
// `psllq` (118), `pcmpeqd` (106), `paddq` (98), `pslldq` (77), `pinsrw` (74),
// `pcmpgtd` (64), `psrldq` (55), `psubd` (30), `psrad` (22), `pcmpeqb` (10),
// `psubq` (5), `psadbw` (3).
//
// Et un fait que seul le comptage donne : **tous les décalages sont par
// immédiat**. Le groupe `0F 72/73` suffit ; les formes par registre XMM
// (`0F D2`, `0F E2`, `0F F2`…) n'apparaissent nulle part dans ce système.
// Les écrire quand même serait du code qu'aucun cas n'atteint.
//
// **Toujours pas de virgule flottante.** `PADDD` additionne quatre entiers de
// trente-deux bits ; ce n'est pas `ADDPS`, et rien ne demande encore le
// second.
//
// La référence est le processeur lui-même : `Tests/Fixtures/x86-simd-oracle.tsv`,
// 236 formes et 9 204 cas, fabriqué par `scripts/build-x86-simd-oracle.py`.
extension X86Core {
    /// Les cent vingt-huit bits vus comme des éléments de `width` octets, deux
    /// à deux, chaque élément traité à part des autres.
    ///
    /// **C'est toute la différence avec l'arithmétique ordinaire** : une
    /// retenue qui sort d'un élément ne rentre pas dans le suivant, et aucun
    /// drapeau n'en sort. Le masque est passé à l'opération parce que les
    /// comparaisons en ont besoin : elles rendent *tous les bits de l'élément*
    /// à un, et cette largeur n'est connue qu'ici.
    static func elementwise(
        _ width: Int, _ left: (low: UInt64, high: UInt64),
        _ right: (low: UInt64, high: UInt64),
        _ operation: (UInt64, UInt64, UInt64) -> UInt64
    ) -> (UInt64, UInt64) {
        (half(width, left.low, right.low, operation),
         half(width, left.high, right.high, operation))
    }

    private static func half(
        _ width: Int, _ left: UInt64, _ right: UInt64,
        _ operation: (UInt64, UInt64, UInt64) -> UInt64
    ) -> UInt64 {
        guard width < 8 else { return operation(left, right, UInt64.max) }
        let bits = UInt64(width) * 8
        let mask = (UInt64(1) << bits) - 1
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            let piece = operation((left >> shift) & mask, (right >> shift) & mask, mask)
            result |= (piece & mask) << shift
            shift += bits
        }
        return result
    }

    /// Un décalage appliqué à chaque élément de `width` octets.
    ///
    /// **Le compte ne se replie pas.** Un décalage de trente-deux sur des mots
    /// de trente-deux bits ne vaut pas un décalage de zéro : il rend zéro pour
    /// les formes logiques, et le bit de signe étalé pour l'arithmétique.
    /// C'est l'inverse de ce que font `SHL` et `SAR` sur un registre général,
    /// où le compte est masqué à 63 ou 31 — deux règles opposées dans le même
    /// processeur, et les confondre est invisible sur les petits comptes.
    static func shiftEach(
        _ width: Int, _ value: (low: UInt64, high: UInt64), _ count: UInt64,
        arithmetic: Bool, left: Bool
    ) -> (UInt64, UInt64) {
        elementwise(width, value, value) { element, _, mask in
            let bits = UInt64(width) * 8
            guard count < bits else {
                // Au-delà de la largeur : zéro, sauf pour le décalage
                // arithmétique à droite, qui garde le signe partout.
                guard arithmetic, !left else { return 0 }
                return element >> (bits - 1) & 1 == 1 ? mask : 0
            }
            if left { return (element << count) & mask }
            guard arithmetic else { return element >> count }
            let sign = (element >> (bits - 1)) & 1
            let shifted = element >> count
            guard sign == 1 else { return shifted }
            return shifted | (mask << (bits - count)) & mask
        }
    }

    /// Le registre entier décalé **en octets**, sans regarder les éléments.
    /// `PSRLDQ` et `PSLLDQ` portent des noms de la même famille et n'en sont
    /// pas : ils déplacent les cent vingt-huit bits d'un bloc.
    ///
    /// **Par décalages de mots, sans tableau** : `PSRLDQ` est dans le
    /// `memcpy` et le `strlen` de la glibc, et un tableau alloué à chaque
    /// passage y coûtait plus que l'instruction.
    static func shiftWhole(
        _ value: (low: UInt64, high: UInt64), by count: UInt64, left: Bool
    ) -> (UInt64, UInt64) {
        guard count < 16 else { return (0, 0) }
        // Un décalage de 64 bits ou plus rend zéro en Swift : le compte nul
        // n'a pas besoin d'un cas à lui.
        let bits = count * 8
        if left {
            if bits >= 64 { return (0, value.low << (bits - 64)) }
            return (value.low << bits, value.high << bits | value.low >> (64 - bits))
        }
        if bits >= 64 { return (value.high >> (bits - 64), 0) }
        return (value.low >> bits | value.high << (64 - bits), value.high >> bits)
    }

    /// **`PCMPEQB` sur un mot, huit octets à la fois** : 0xFF là où les deux
    /// octets sont égaux, 0 ailleurs. Le bit haut de chaque octet de `t` dit
    /// que l'octet de `a ^ b` n'est pas nul — sans qu'une retenue passe d'un
    /// octet au suivant, puisqu'on n'additionne que les sept bits du bas.
    static func equalBytes(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let difference = left ^ right
        let lowSeven: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        let nonZero = ((difference & lowSeven) &+ lowSeven) | difference
        let equal = ~nonZero & 0x8080_8080_8080_8080
        return (equal >> 7) &* 0xFF
    }

    /// **`PMOVMSKB` sur un mot** : le bit haut de chacun des huit octets,
    /// rangés dans l'ordre, l'octet zéro au bit zéro. La multiplication
    /// amène chaque bit haut à sa place dans l'octet du haut, sans que deux
    /// d'entre eux se rencontrent.
    static func signBits(_ value: UInt64) -> UInt64 {
        ((value & 0x8080_8080_8080_8080) >> 7 &* 0x0102_0408_1020_4080) >> 56
    }

    static func bytes(_ value: (low: UInt64, high: UInt64)) -> [UInt8] {
        (0..<16).map {
            UInt8(truncatingIfNeeded: ($0 < 8 ? value.low : value.high) >> (UInt64($0 % 8) * 8))
        }
    }

    static func pack(_ bytes: [UInt8]) -> (UInt64, UInt64) {
        var low: UInt64 = 0
        var high: UInt64 = 0
        for index in 0..<16 {
            let piece = UInt64(bytes[index]) << (UInt64(index % 8) * 8)
            if index < 8 { low |= piece } else { high |= piece }
        }
        return (low, high)
    }

    /// La somme des différences absolues, huit octets à la fois. Elle condense
    /// seize octets en deux nombres et n'a d'équivalent nulle part ailleurs
    /// dans le jeu : le résultat va dans les seize bits bas de chaque moitié,
    /// le reste est mis à zéro.
    static func sumOfAbsoluteDifferences(
        _ left: (low: UInt64, high: UInt64), _ right: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let a = bytes(left)
        let b = bytes(right)
        var sums: [UInt64] = [0, 0]
        for index in 0..<16 {
            let first = UInt64(a[index])
            let second = UInt64(b[index])
            sums[index / 8] += first > second ? first - second : second - first
        }
        return (sums[0], sums[1])
    }

    /// Les quatre mots de trente-deux bits remis dans l'ordre que dit
    /// l'immédiat, deux bits par position.
    static func shuffleDoublewords(
        _ value: (low: UInt64, high: UInt64), _ control: UInt8
    ) -> (UInt64, UInt64) {
        let words = [
            value.low & 0xFFFF_FFFF, value.low >> 32,
            value.high & 0xFFFF_FFFF, value.high >> 32,
        ]
        var chosen = [UInt64]()
        for position in 0..<4 {
            chosen.append(words[Int((control >> (2 * position)) & 0x03)])
        }
        return (chosen[0] | (chosen[1] << 32), chosen[2] | (chosen[3] << 32))
    }

    /// L'arithmétique entière vectorielle. Rend `false` quand l'opcode n'en
    /// est pas une, pour que le reste du dispatch continue.
    ///
    /// Toutes ces formes exigent le préfixe `66` : sans lui ce sont les
    /// instructions MMX, qui travaillent sur d'autres registres — voir
    /// `X86MMX.swift`. Les confondre exécuterait sur un registre XMM ce que
    /// le programme voulait faire ailleurs.
    mutating func vectorArithmetic(
        _ instruction: X86Instruction, _ opcode: UInt8
    ) throws -> Bool {
        guard instruction.hasPrefix(0x66) else { return false }
        switch opcode {
        // Les comparaisons : tous les bits de l'élément à un quand c'est vrai,
        // tous à zéro sinon. C'est un masque, pas un booléen — il sert
        // ensuite d'opérande à un `PAND`.
        case 0x74:
            // L'octet à l'octet, mais huit à la fois : c'est le cœur des
            // `strlen` et `memchr` de la glibc.
            let fields = try decodeFields(instruction)
            let destination = vector(fields.reg)
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, Self.equalBytes(destination.low, source.0),
                      Self.equalBytes(destination.high, source.1))
        case 0x76: try compute(instruction, 4) { $0 == $1 ? $2 : 0 }
        case 0x66: try compute(instruction, 4) {
            Int32(truncatingIfNeeded: $0) > Int32(truncatingIfNeeded: $1) ? $2 : 0
        }

        // L'addition et la soustraction, qui enveloppent sans saturer.
        case 0xFE: try compute(instruction, 4) { ($0 &+ $1) & $2 }
        case 0xD4: try compute(instruction, 8) { ($0 &+ $1) & $2 }
        case 0xFA: try compute(instruction, 4) { ($0 &- $1) & $2 }
        case 0xFB: try compute(instruction, 8) { ($0 &- $1) & $2 }

        case 0xF6:  // PSADBW
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let result = Self.sumOfAbsoluteDifferences(vector(fields.reg), source)
            setVector(fields.reg, result.0, result.1)

        case 0x70:  // PSHUFD : la source peut être un registre ou la mémoire
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let result = Self.shuffleDoublewords(
                (low: source.0, high: source.1), UInt8(truncatingIfNeeded: instruction.immediate))
            setVector(fields.reg, result.0, result.1)

        // Les groupes de décalage. Ici le champ `reg` du ModRM n'est pas un
        // registre mais le numéro de l'opération, et c'est `rm` qui désigne le
        // registre à décaler.
        case 0x71, 0x72, 0x73:
            let fields = try decodeFields(instruction)
            let count = UInt64(UInt8(truncatingIfNeeded: instruction.immediate))
            let width = opcode == 0x71 ? 2 : (opcode == 0x72 ? 4 : 8)
            let value = vector(fields.rm)
            let result: (UInt64, UInt64)
            switch fields.reg & 0x07 {
            case 2: result = Self.shiftEach(width, value, count,
                                            arithmetic: false, left: false)
            case 4: result = Self.shiftEach(width, value, count,
                                            arithmetic: true, left: false)
            case 6: result = Self.shiftEach(width, value, count,
                                            arithmetic: false, left: true)
            case 3 where opcode == 0x73:  // PSRLDQ, en octets sur tout le registre
                result = Self.shiftWhole(value, by: count, left: false)
            case 7 where opcode == 0x73:  // PSLLDQ
                result = Self.shiftWhole(value, by: count, left: true)
            default:
                throw Fault.unsupported("le groupe \(String(opcode, radix: 16))"
                                        + " /\(fields.reg & 0x07)")
            }
            setVector(fields.rm, result.0, result.1)

        case 0xC4:  // PINSRW : un mot de seize bits à la place que dit l'immédiat
            let fields = try decodeFields(instruction)
            // Le champ ne porte que trois bits utiles : 8 désigne le mot 0.
            let position = Int(UInt8(truncatingIfNeeded: instruction.immediate) & 0x07)
            let word = try readRM(fields, 2) & 0xFFFF
            var bytes = Self.bytes(vector(fields.reg))
            bytes[2 * position] = UInt8(truncatingIfNeeded: word)
            bytes[2 * position + 1] = UInt8(truncatingIfNeeded: word >> 8)
            let result = Self.pack(bytes)
            setVector(fields.reg, result.0, result.1)

        // **Ce que la glibc de Debian demande en plus.** Alpine est bâtie sur
        // musl, et ses programmes n'employaient rien de ce qui suit. L'image
        // de cloud de Debian 13 s'est arrêtée dans son initramfs, à 2,1
        // milliards d'instructions, sur `66 0F D7` : `PMOVMSKB`, le cœur de
        // `strlen`, `memchr` et `strchr` en SSE2. Le comptage sur les binaires
        // de cet initramfs (`objdump`, les formes sans VEX seulement, puisque
        // le CPUID n'annonce ni AVX ni SSSE3) a donné la liste : `pmovmskb`
        // (1 178), `paddb` (1 111), `psubb` (409), `pcmpgtb` (403),
        // `pmuludq` (154), `psubusb` (152), `pminub` (146), `pextrw` (131),
        // `paddw` (55), `packuswb` (53), `pmullw` (34), `psubw` (19),
        // `pmulhuw` (12), `pmaxub` (12), `pcmpgtw` (2), et quatre décalages
        // par registre (`psrad` 16, `psrld` 15, `psllw` 8, `pslld` 5).

        // Les octets et les mots, comme les doubles mots plus haut.
        case 0x64: try compute(instruction, 1) { Int8(truncatingIfNeeded: $0) > Int8(truncatingIfNeeded: $1) ? $2 : 0 }
        case 0x65: try compute(instruction, 2) {
            Int16(truncatingIfNeeded: $0) > Int16(truncatingIfNeeded: $1) ? $2 : 0
        }
        case 0xFC: try compute(instruction, 1) { ($0 &+ $1) & $2 }
        case 0xFD: try compute(instruction, 2) { ($0 &+ $1) & $2 }
        case 0xF8: try compute(instruction, 1) { ($0 &- $1) & $2 }
        case 0xF9: try compute(instruction, 2) { ($0 &- $1) & $2 }
        // Sans signe, et **saturés** : ce que `strcmp` emploie pour trouver
        // un octet nul ou une différence en un seul passage.
        case 0xDA: try compute(instruction, 1) { left, right, _ in min(left, right) }
        case 0xDE: try compute(instruction, 1) { left, right, _ in max(left, right) }
        case 0xD8: try compute(instruction, 1) { left, right, _ in left > right ? left - right : 0 }

        // Les multiplications : la moitié basse ou haute du produit de mots de
        // seize bits, et le produit complet des doubles mots pairs.
        case 0xD5: try compute(instruction, 2) { ($0 &* $1) & $2 }
        case 0xE4: try compute(instruction, 2) { left, right, _ in (left &* right) >> 16 }
        case 0xF4: try compute(instruction, 8) { left, right, _ in (left & 0xFFFF_FFFF) &* (right & 0xFFFF_FFFF) }

        // **Ce que Fedora 44 demande en plus**, trouvé d'avance : chaque
        // instruction SSE2 des binaires de son image (`/usr/bin`,
        // `/usr/lib64`, `/usr/lib/systemd`), passée au cœur une à une. Le
        // démarrage s'arrêtait sur `66 0F 63` dans `zram-generator`. Les
        // comparaisons et les extrêmes signés des mots, les moyennes
        // arrondies vers le haut, les additions et soustractions saturées.
        case 0x75: try compute(instruction, 2) { $0 == $1 ? $2 : 0 }
        case 0xEE: try compute(instruction, 2) { left, right, _ in
            Int16(truncatingIfNeeded: left) > Int16(truncatingIfNeeded: right) ? left : right
        }
        case 0xEA: try compute(instruction, 2) { left, right, _ in
            Int16(truncatingIfNeeded: left) < Int16(truncatingIfNeeded: right) ? left : right
        }
        case 0xE0: try compute(instruction, 1) { left, right, _ in (left + right + 1) >> 1 }
        case 0xE3: try compute(instruction, 2) { left, right, _ in (left + right + 1) >> 1 }
        case 0xDC: try compute(instruction, 1) { left, right, _ in min(left + right, 0xFF) }
        case 0xDD: try compute(instruction, 2) { left, right, _ in min(left + right, 0xFFFF) }
        case 0xD9: try compute(instruction, 2) { left, right, _ in left > right ? left - right : 0 }
        case 0xEC, 0xED, 0xE8, 0xE9:  // PADDSB, PADDSW, PSUBSB, PSUBSW
            let width = opcode & 1 == 0 ? 1 : 2
            let bits = UInt64(8 * width)
            let subtract = opcode < 0xEC
            try compute(instruction, width) { left, right, mask in
                let a = Int64(bitPattern: left << (64 - bits)) >> (64 - bits)
                let b = Int64(bitPattern: right << (64 - bits)) >> (64 - bits)
                let limit = Int64(1) << (bits - 1)
                let sum = min(max(subtract ? a - b : a + b, -limit), limit - 1)
                return UInt64(bitPattern: sum) & mask
            }
        // La moitié haute du produit signé de deux mots ; et `PMADDWD`, les
        // produits signés de deux mots voisins additionnés en un double mot.
        case 0xE5: try compute(instruction, 2) { left, right, mask in
            UInt64(bitPattern: (Int64(Int16(truncatingIfNeeded: left)) * Int64(Int16(truncatingIfNeeded: right))) >> 16)
                & mask
        }
        case 0xF5: try compute(instruction, 4) { left, right, mask in
            let low = Int64(Int16(truncatingIfNeeded: left)) * Int64(Int16(truncatingIfNeeded: right))
            let high = Int64(Int16(truncatingIfNeeded: left >> 16)) * Int64(Int16(truncatingIfNeeded: right >> 16))
            return UInt64(bitPattern: low + high) & mask
        }
        // Les resserrements **signés** : les mots en octets, les doubles mots
        // en mots, chacun ramené dans ce que sa nouvelle taille peut porter.
        case 0x63, 0x6B:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let result = Self.packSignedSaturated(vector(fields.reg), (low: source.0, high: source.1),
                                                  from: opcode == 0x63 ? 2 : 4)
            setVector(fields.reg, result.0, result.1)

        case 0x67:  // PACKUSWB : seize mots signés serrés en seize octets
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let result = Self.packUnsignedSaturated(vector(fields.reg), (low: source.0, high: source.1))
            setVector(fields.reg, result.0, result.1)

        // Les décalages dont le compte vient d'un registre XMM, ou de la
        // mémoire : ses soixante-quatre bits bas, entiers, et sans repli.
        // Les huit : à gauche (F1 à F3), logiques à droite (D1 à D3),
        // arithmétiques à droite (E1, E2), sur des mots, des doubles mots et
        // des quadruples mots. Il n'en existait que quatre — ceux que la glibc
        // emploie — et le `ssh-keygen` de Guix s'arrêtait sur `PSLLQ`.
        case 0xF1, 0xF2, 0xF3, 0xD1, 0xD2, 0xD3, 0xE1, 0xE2:
            let fields = try decodeFields(instruction)
            let count = try readVectorRM(fields, 16).0
            let width = 2 << Int((opcode & 0x0F) - 1)  // 1 → 2, 2 → 4, 3 → 8
            let result = Self.shiftEach(width, vector(fields.reg), count,
                                        arithmetic: opcode & 0xF0 == 0xE0, left: opcode & 0xF0 == 0xF0)
            setVector(fields.reg, result.0, result.1)

        // Vers un registre général : le bit de signe de chaque octet, ou un
        // mot choisi. Ces deux formes n'existent qu'entre registres.
        case 0xD7:  // PMOVMSKB
            let fields = try decodeFields(instruction)
            guard fields.mod == 0b11 else { throw Fault.unsupported("PMOVMSKB depuis la mémoire") }
            let value = vector(fields.rm)
            writeReg(fields, 4, Self.signBits(value.low) | Self.signBits(value.high) << 8)

        case 0xC5:  // PEXTRW
            let fields = try decodeFields(instruction)
            guard fields.mod == 0b11 else { throw Fault.unsupported("PEXTRW depuis la mémoire") }
            let position = UInt64(UInt8(truncatingIfNeeded: instruction.immediate) & 0x07)
            let value = vector(fields.rm)
            let half = position < 4 ? value.low : value.high
            writeReg(fields, 4, (half >> (16 * (position % 4))) & 0xFFFF)

        default: return false
        }
        return true
    }

    /// `PACKUSWB` : chaque mot signé ramené entre 0 et 255. Les huit mots de
    /// la destination font les octets bas, ceux de la source les octets hauts.
    static func packUnsignedSaturated(
        _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let words = [destination.low, destination.high, source.low, source.high].flatMap { half in
            (0..<4).map { Int16(truncatingIfNeeded: half >> (16 * UInt64($0))) }
        }
        return pack(words.map { UInt8(clamping: $0) })
    }

    /// `PACKSSWB` et `PACKSSDW` : chaque élément signé de `from` octets
    /// ramené dans un élément signé deux fois plus étroit. La destination
    /// fait la moitié basse, la source la moitié haute.
    static func packSignedSaturated(
        _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64), from: Int
    ) -> (UInt64, UInt64) {
        let bits = UInt64(8 * from)
        let narrow = bits / 2
        let limit = Int64(1) << (narrow - 1)
        var halves: [UInt64] = [0, 0]
        var position: UInt64 = 0
        for half in [destination.low, destination.high, source.low, source.high] {
            for index in 0..<(64 / bits) {
                let piece = (half >> (index * bits)) << (64 - bits)
                let value = min(max(Int64(bitPattern: piece) >> (64 - bits), -limit), limit - 1)
                let field = UInt64(bitPattern: value) & ((1 << narrow) - 1)
                halves[Int(position / 64)] |= field << (position % 64)
                position += narrow
            }
        }
        return (halves[0], halves[1])
    }

    /// Une opération élément par élément entre la destination et la source.
    private mutating func compute(
        _ instruction: X86Instruction, _ width: Int,
        _ operation: (UInt64, UInt64, UInt64) -> UInt64
    ) throws {
        let fields = try decodeFields(instruction)
        let destination = vector(fields.reg)
        let source = try readVectorRM(fields, 16)
        let result = Self.elementwise(width, destination,
                                      (low: source.0, high: source.1), operation)
        setVector(fields.reg, result.0, result.1)
    }
}
