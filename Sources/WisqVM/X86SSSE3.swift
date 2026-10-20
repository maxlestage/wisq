import Foundation

// **SSSE3, et les tables `0F 38` et `0F 3A` qu'il ouvre.**
//
// AlmaLinux 9, Rocky 9 et CentOS Stream 9 sont compilés pour x86-64-v2 :
// SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT, CMPXCHG16B. Leur glibc refuse de
// démarrer sur un processeur qui ne les annonce pas, et le reste de leurs
// binaires les emploie sans demander. Le comptage sur `/usr` d'AlmaLinux 9.8
// en trouve cinquante-quatre mnémoniques que ce cœur ne savait pas exécuter
// (voir `scripts/build-x86-v2-oracle.py`). Ils entrent par tranches, chacune
// avec son corpus ; les bits de `CPUID` ne s'allument qu'à la fin.
//
// Celle-ci prend SSSE3 tel que ces binaires l'emploient : `palignr` (4 948
// fois), `pshufb` (1 581), `pabsd` (214), `pmaddubsw` (4), `phaddsw` (1) — et
// `pabsb`, `pabsw`, qui ne diffèrent de `pabsd` que par la largeur.
//
// **Toutes exigent le préfixe `66`.** Sans lui, ce sont les mêmes opérations
// sur les registres MMX, que ce cœur n'a pas ; les confondre exécuterait sur
// un XMM ce que le programme voulait faire ailleurs.
//
// La référence est le processeur : `Tests/Fixtures/x86-v2-oracle.tsv`.
extension X86Core {
    /// La table `0F 38` : une source, une destination, aucun immédiat, aucun
    /// drapeau.
    mutating func threeByte38(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        guard instruction.hasPrefix(0x66) else {
            throw Fault.unsupported(String(format: "l'opcode 0F 38 %02X sans 66 (MMX)", opcode))
        }
        let fields = try decodeFields(instruction)
        // Les deux formes qui ne suivent pas le patron « destination, source,
        // résultat » : l'une n'écrit que des drapeaux, l'autre lit moins de
        // seize octets. Voir `X86SSE41.swift`.
        if opcode == 0x17 {
            try testBits(fields)
            return
        }
        if let widening = Self.widening(opcode) {
            try widen(fields, widening)
            return
        }
        let destination = vector(fields.reg)
        let read = try readVectorRM(fields, 16)
        let source = (low: read.0, high: read.1)
        let result: (UInt64, UInt64)
        switch opcode {
        case 0x00: result = Self.shuffleBytes(destination, by: source)
        case 0x03: result = Self.horizontalAddSaturated(destination, source)
        case 0x04: result = Self.multiplyAddBytes(destination, source)
        // La valeur absolue de chaque élément de la **source** : la
        // destination n'est pas lue. Le plus négatif reste ce qu'il est —
        // 0x80 n'a pas d'opposé sur huit bits.
        case 0x1C, 0x1D, 0x1E:
            let width = 1 << Int(opcode - 0x1C)
            result = Self.elementwise(width, source, source) { element, _, mask in
                let sign = (mask >> 1) &+ 1
                return element & sign != 0 ? (0 &- element) & mask : element
            }
        default:
            guard let computed = Self.sse41(opcode, destination, source, mask: vector(0)) else {
                throw Fault.unsupported(String(format: "l'opcode 66 0F 38 %02X", opcode))
            }
            result = computed
        }
        setVector(fields.reg, result.0, result.1)
    }

    /// La table `0F 3A` : la même chose, et un octet immédiat derrière.
    mutating func threeByte3A(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        guard instruction.hasPrefix(0x66) else {
            throw Fault.unsupported(String(format: "l'opcode 0F 3A %02X sans 66 (MMX)", opcode))
        }
        let fields = try decodeFields(instruction)
        let control = UInt8(truncatingIfNeeded: instruction.immediate)
        switch opcode {
        case 0x0F:  // PALIGNR
            let read = try readVectorRM(fields, 16)
            let result = Self.alignBytes(vector(fields.reg), (low: read.0, high: read.1), by: control)
            setVector(fields.reg, result.0, result.1)
        case 0x0E, 0x14, 0x16, 0x17, 0x20, 0x21, 0x22:
            try insertOrExtract(instruction, fields, opcode, control)
        case 0x63:  // PCMPISTRI (SSE4.2)
            try compareImplicitStrings(fields, control)
        default:
            throw Fault.unsupported(String(format: "l'opcode 66 0F 3A %02X", opcode))
        }
    }

    /// **`PSHUFB`** : chaque octet de la destination devient celui que
    /// désignent les quatre bits bas de l'octet correspondant de la source —
    /// ou zéro, quand le bit 7 de celui-ci est levé. Les bits 4 à 6 ne
    /// comptent pas.
    static func shuffleBytes(
        _ value: (low: UInt64, high: UInt64), by control: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let from = bytes(value)
        let selectors = bytes(control)
        return pack(selectors.map { $0 & 0x80 != 0 ? 0 : from[Int($0 & 0x0F)] })
    }

    /// **`PALIGNR`** : la destination en haut, la source en bas, trente-deux
    /// octets décalés à droite de `count` octets, les seize du bas gardés.
    /// Au-delà de seize, il ne reste que la destination ; au-delà de
    /// trente-deux, rien.
    static func alignBytes(
        _ high: (low: UInt64, high: UInt64), _ low: (low: UInt64, high: UInt64), by count: UInt8
    ) -> (UInt64, UInt64) {
        let joined = bytes(low) + bytes(high)
        return pack((0..<16).map { index in
            let from = index + Int(count)
            return from < 32 ? joined[from] : 0
        })
    }

    /// Les seize mots de seize bits, signés.
    static func signedWords(_ value: (low: UInt64, high: UInt64)) -> [Int32] {
        (0..<8).map { index in
            let half = index < 4 ? value.low : value.high
            return Int32(Int16(truncatingIfNeeded: half >> (UInt64(index % 4) * 16)))
        }
    }

    static func packWords(_ words: [Int32]) -> (UInt64, UInt64) {
        var halves: [UInt64] = [0, 0]
        for (index, word) in words.enumerated() {
            halves[index / 4] |= UInt64(UInt16(truncatingIfNeeded: word)) << (UInt64(index % 4) * 16)
        }
        return (halves[0], halves[1])
    }

    static func saturatedWord(_ value: Int32) -> Int32 {
        min(max(value, Int32(Int16.min)), Int32(Int16.max))
    }

    /// **`PHADDSW`** : les mots voisins additionnés deux à deux, saturés — les
    /// quatre sommes de la destination en bas, celles de la source en haut.
    static func horizontalAddSaturated(
        _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let left = signedWords(destination), right = signedWords(source)
        let sums = (0..<4).map { saturatedWord(left[2 * $0] + left[2 * $0 + 1]) }
            + (0..<4).map { saturatedWord(right[2 * $0] + right[2 * $0 + 1]) }
        return packWords(sums)
    }

    /// **`PMADDUBSW`** : chaque octet de la destination, **sans signe**, par
    /// l'octet correspondant de la source, **signé** ; les produits voisins
    /// additionnés et saturés en un mot. L'asymétrie est l'instruction : les
    /// échanger donne un résultat plausible et faux.
    static func multiplyAddBytes(
        _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let unsigned = bytes(destination), signed = bytes(source)
        let words = (0..<8).map { index -> Int32 in
            let first = Int32(unsigned[2 * index]) * Int32(Int8(bitPattern: signed[2 * index]))
            let second = Int32(unsigned[2 * index + 1]) * Int32(Int8(bitPattern: signed[2 * index + 1]))
            return saturatedWord(first + second)
        }
        return packWords(words)
    }
}
