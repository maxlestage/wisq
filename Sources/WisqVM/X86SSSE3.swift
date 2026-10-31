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
// **Puis le reste de SSSE3**, quand le systemd de CentOS Stream 10 s'est
// arrêté sur `psignb` : `phaddw`, `phaddd`, `phsubw`, `phsubd`, `phsubsw`,
// `psignb`, `psignw`, `psignd`, `pmulhrsw`. Compilés pour x86-64-v3, ses
// programmes les emploient sous VEX, qui passe par ici.
//
// **Avec le préfixe `66`, sur les XMM ; sans lui, sur les registres MMX**,
// les mêmes opérations sur huit octets : voir `ssse3OnMMX`. Les confondre
// exécuterait sur un XMM ce que le programme voulait faire ailleurs.
//
// La référence est le processeur : `Tests/Fixtures/x86-v2-oracle.tsv`.
extension X86Core {
    /// La table `0F 38` : une source, une destination, aucun immédiat, aucun
    /// drapeau.
    mutating func threeByte38(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        // `CRC32` porte F2, pas 66 : avec 66 en plus, c'est sa forme de seize
        // bits. Voir `X86SSE42.swift`.
        if instruction.hasPrefix(0xF2), opcode == 0xF0 || opcode == 0xF1 {
            try crc32(instruction, try decodeFields(instruction), byteForm: opcode == 0xF0)
            return
        }
        // `MOVBE` : les mêmes octets sans F2, avec ou sans 66 (sa forme de
        // seize bits). Voir `X86BMI.swift`.
        if opcode == 0xF0 || opcode == 0xF1 {
            try moveSwappingBytes(instruction, toMemory: opcode == 0xF1)
            return
        }
        guard instruction.hasPrefix(0x66) else {
            if try ssse3OnMMX(instruction, opcode, aligning: false) { return }
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
        // `MOVNTDQA` (SSE4.1) : seize octets de la mémoire, sans passer par
        // le cache — ce qui ne change rien ici. Il n'existe que depuis la
        // mémoire. openSUSE l'emploie.
        if opcode == 0x2A {
            guard fields.mod != 0b11 else { throw Fault.unsupported("66 0F 38 2A entre registres") }
            let value = try readVectorRM(fields, 16)
            setVector(fields.reg, value.0, value.1)
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
        case 0x01, 0x02, 0x03, 0x05, 0x06, 0x07: result = Self.horizontal(opcode, destination, source)
        case 0x04, 0x08...0x0B, 0x1C...0x1E:
            result = Self.ssse3Elementwise(opcode, destination, source) ?? (0, 0)
        // `PHMINPOSUW` (SSE4.1) : le plus petit des huit mots sans signe de
        // la source, et son rang — le premier en cas d'égalité — dans les
        // bits 16 à 18 ; tout le reste à zéro. La destination n'est pas lue.
        case 0x41:
            let words = (0..<8).map { UInt16(truncatingIfNeeded: ($0 < 4 ? source.low : source.high) >> (16 * UInt64($0 % 4))) }
            let smallest = words.min() ?? 0
            let rank = words.firstIndex(of: smallest) ?? 0
            result = (UInt64(smallest) | UInt64(rank) << 16, 0)
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
            if try ssse3OnMMX(instruction, opcode, aligning: true) { return }
            throw Fault.unsupported(String(format: "l'opcode 0F 3A %02X sans 66 (MMX)", opcode))
        }
        let fields = try decodeFields(instruction)
        let control = UInt8(truncatingIfNeeded: instruction.immediate)
        switch opcode {
        case 0x0F:  // PALIGNR
            let read = try readVectorRM(fields, 16)
            let result = Self.alignBytes(vector(fields.reg), (low: read.0, high: read.1), by: control)
            setVector(fields.reg, result.0, result.1)
        case 0x0E, 0x14, 0x15, 0x16, 0x17, 0x20, 0x21, 0x22:
            try insertOrExtract(instruction, fields, opcode, control)
        // PCMPESTRM, PCMPESTRI, PCMPISTRM, PCMPISTRI (SSE4.2)
        case 0x60...0x63:
            try compareStrings(instruction, fields, control, explicit: opcode < 0x62, mask: opcode & 1 == 0)
        case 0x08...0x0B:  // ROUNDPS, ROUNDPD, ROUNDSS, ROUNDSD
            try round(fields, opcode, control)
        // `BLENDPS`, `BLENDPD` (SSE4.1) : l'élément i — quatre de 32 bits, ou
        // deux de 64 — vient de la source quand le bit i de l'immédiat est
        // levé. Leurs formes VEX étaient déclarées et retombaient ici sur un
        // refus : Chimera s'arrêtait sur `vblendps` dans un module du noyau,
        // depuis que CPUID annonce AVX.
        case 0x0C, 0x0D:
            let read = try readVectorRM(fields, 16)
            let width: UInt64 = opcode == 0x0C ? 32 : 64
            let perHalf = Int(64 / width)
            let element: UInt64 = width == 64 ? .max : (1 << width) - 1
            var masks: (UInt64, UInt64) = (0, 0)
            for index in 0..<(2 * perHalf) where control >> index & 1 != 0 {
                let piece = element << (UInt64(index % perHalf) * width)
                if index < perHalf { masks.0 |= piece } else { masks.1 |= piece }
            }
            let target = vector(fields.reg)
            setVector(fields.reg, target.low & ~masks.0 | read.0 & masks.0,
                      target.high & ~masks.1 | read.1 & masks.1)
        // `MPSADBW` (SSE4.1) : huit sommes d'écarts absolus. Le bloc de
        // quatre octets de la source que les bits 1-0 de l'immédiat
        // choisissent, comparé à huit fenêtres glissantes de quatre octets de
        // la destination, qui commencent à l'octet 0 ou 4 selon le bit 2.
        case 0x42:
            let read = try readVectorRM(fields, 16)
            let target = Self.bytes(vector(fields.reg)), block = Self.bytes((low: read.0, high: read.1))
            let from = Int(control >> 2 & 1) * 4, chosen = Int(control & 3) * 4
            let sums = (0..<8).map { window in
                (0..<4).reduce(0) { total, offset in
                    total + abs(Int(target[from + window + offset]) - Int(block[chosen + offset]))
                }
            }
            let packed = Self.packWords(sums.map { Int32($0) })
            setVector(fields.reg, packed.0, packed.1)
        default:
            throw Fault.unsupported(String(format: "l'opcode 66 0F 3A %02X", opcode))
        }
    }

    /// **Les opérations de SSSE3 qui travaillent élément par élément** —
    /// `PMADDUBSW` (`04`), `PSIGNB/W/D` (`08` à `0A`), `PMULHRSW` (`0B`),
    /// `PABSB/W/D` (`1C` à `1E`) — sur seize octets. Sur les registres MMX, la
    /// même chose avec une moitié haute nulle, dont on garde le bas : rien n'y
    /// traverse d'une moitié à l'autre. `nil` pour un autre opcode.
    static func ssse3Elementwise(
        _ opcode: UInt8, _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64)? {
        switch opcode {
        case 0x04: return multiplyAddBytes(destination, source)
        // `PSIGNB/W/D` : chaque élément de la destination gardé, opposé ou
        // mis à zéro selon le signe de celui de la source.
        case 0x08, 0x09, 0x0A:
            let width = 1 << Int(opcode - 0x08)
            return elementwise(width, destination, source) { element, sign, mask in
                let top = (mask >> 1) &+ 1
                if sign & mask == 0 { return 0 }
                return sign & top != 0 ? (0 &- element) & mask : element
            }
        // `PMULHRSW` : le produit signé de deux mots, arrondi, ses bits 15
        // à 30 — `(a × b + 0x4000) >> 15`.
        case 0x0B:
            let left = signedWords(destination), right = signedWords(source)
            return packWords((0..<8).map { (left[$0] * right[$0] + 0x4000) >> 15 })
        // La valeur absolue de chaque élément de la **source** : la
        // destination n'est pas lue. Le plus négatif reste ce qu'il est —
        // 0x80 n'a pas d'opposé sur huit bits.
        case 0x1C, 0x1D, 0x1E:
            let width = 1 << Int(opcode - 0x1C)
            return elementwise(width, source, source) { element, _, mask in
                let sign = (mask >> 1) &+ 1
                return element & sign != 0 ? (0 &- element) & mask : element
            }
        default:
            return nil
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

    /// **Les opérations horizontales** : les éléments voisins additionnés ou
    /// soustraits deux à deux — le premier moins le second —, les résultats
    /// de la destination en bas, ceux de la source en haut. `PHADDW`
    /// (`01`), `PHADDD` (`02`), `PHADDSW` (`03`, saturé), `PHSUBW` (`05`),
    /// `PHSUBD` (`06`), `PHSUBSW` (`07`, saturé). Sans saturation, le
    /// résultat est pris modulo la largeur.
    static func horizontal(
        _ opcode: UInt8, _ destination: (low: UInt64, high: UInt64), _ source: (low: UInt64, high: UInt64)
    ) -> (UInt64, UInt64) {
        let subtract = opcode >= 0x05
        if opcode & 3 == 2 {
            // Sur trente-deux bits : deux sommes par registre.
            func pairs(_ value: (low: UInt64, high: UInt64)) -> [UInt64] {
                [value.low, value.high].map { word in
                    let first = UInt32(truncatingIfNeeded: word), second = UInt32(truncatingIfNeeded: word >> 32)
                    return UInt64(subtract ? first &- second : first &+ second)
                }
            }
            let results = pairs(destination) + pairs(source)
            return (results[0] | results[1] << 32, results[2] | results[3] << 32)
        }
        let saturated = opcode & 3 == 3
        let left = signedWords(destination), right = signedWords(source)
        func combine(_ words: [Int32], _ index: Int) -> Int32 {
            let value = subtract ? words[2 * index] - words[2 * index + 1] : words[2 * index] + words[2 * index + 1]
            return saturated ? saturatedWord(value) : value
        }
        return packWords((0..<4).map { combine(left, $0) } + (0..<4).map { combine(right, $0) })
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
