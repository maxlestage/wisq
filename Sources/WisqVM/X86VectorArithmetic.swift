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
// 108 formes et 3 240 cas, fabriqué par `scripts/build-x86-simd-oracle.py`.
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
    static func shiftWhole(
        _ value: (low: UInt64, high: UInt64), by count: UInt64, left: Bool
    ) -> (UInt64, UInt64) {
        guard count < 16 else { return (0, 0) }
        var bytes = [UInt8](repeating: 0, count: 16)
        let source = self.bytes(value)
        for index in 0..<16 {
            let from = left ? index - Int(count) : index + Int(count)
            if from >= 0, from < 16 { bytes[index] = source[from] }
        }
        return pack(bytes)
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
    /// instructions MMX, qui travaillent sur d'autres registres et que ce cœur
    /// n'a pas. Le dire plutôt que de les confondre évite d'exécuter sur un
    /// registre XMM ce que le programme voulait faire ailleurs.
    mutating func vectorArithmetic(
        _ instruction: X86Instruction, _ opcode: UInt8
    ) throws -> Bool {
        guard instruction.hasPrefix(0x66) else { return false }
        switch opcode {
        // Les comparaisons : tous les bits de l'élément à un quand c'est vrai,
        // tous à zéro sinon. C'est un masque, pas un booléen — il sert
        // ensuite d'opérande à un `PAND`.
        case 0x74: try compute(instruction, 1) { $0 == $1 ? $2 : 0 }
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

        default: return false
        }
        return true
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
