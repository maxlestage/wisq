import Foundation

// **AES-NI et PCLMULQDQ** : un tour d'AES en une instruction, et la
// multiplication sans retenue qui fait le GHASH de GCM.
//
// Le TLS d'aujourd'hui chiffre en AES-GCM : `apt` sur https, `curl`, `git`.
// LUKS chiffre ses disques en AES-XTS. Sans ces instructions, OpenSSL
// tombe sur son AES par tables et son GHASH logiciel, des dizaines
// d'instructions de l'invité par octet ; avec elles, une poignée. `CPUID`
// les annonce dans la feuille 1, ECX : PCLMULQDQ (1) et AES (25).
//
// Les seize octets d'un registre sont l'état d'AES colonne par colonne :
// l'octet `i` est à la ligne `i % 4`, dans la colonne `i / 4` — quatre mots
// de 32 bits, un par colonne, l'octet bas en ligne 0. La référence
// est le processeur : `Tests/Fixtures/x86-v2-oracle.tsv`.
extension X86Core {
    /// La boîte de substitution d'AES, calculée une fois : l'inverse dans
    /// GF(2⁸), puis la transformation affine. Plus sûr qu'un tableau de
    /// deux cent cinquante-six nombres recopié à la main.
    static let substitution: [UInt8] = {
        var box = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1
        var q: UInt8 = 1
        repeat {
            // p parcourt le groupe multiplicatif par ×3, q par ÷3.
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1B : 0)
            q ^= q << 1
            q ^= q << 2
            q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            let rotated = q ^ rotate(q, 1) ^ rotate(q, 2) ^ rotate(q, 3) ^ rotate(q, 4)
            box[Int(p)] = rotated ^ 0x63
        } while p != 1
        box[0] = 0x63
        return box
    }()

    static let inverseSubstitution: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in substitution.enumerated() { inverse[Int(value)] = UInt8(index) }
        return inverse
    }()

    @inline(__always)
    static func rotate(_ value: UInt8, _ count: UInt8) -> UInt8 { value << count | value >> (8 - count) }

    /// La multiplication par x dans GF(2⁸), modulo x⁸ + x⁴ + x³ + x + 1.
    @inline(__always)
    static func double(_ value: UInt8) -> UInt8 { value << 1 ^ (value & 0x80 != 0 ? 0x1B : 0) }

    static func multiply(_ value: UInt8, _ factor: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var term = value
        var bits = factor
        while bits != 0 {
            if bits & 1 != 0 { result ^= term }
            term = double(term)
            bits >>= 1
        }
        return result
    }

    /// **Les tables T**, la façon classique de faire un tour d'AES sur des
    /// mots de 32 bits : pour chaque octet possible, la colonne qu'il
    /// apporte une fois substitué et mélangé. Un tour devient seize lectures
    /// et des OU exclusifs. La première version faisait le tour octet par
    /// octet, avec une multiplication en boucle : l'invité chiffrait seize
    /// fois plus vite, l'hôte quatre fois seulement.
    ///
    /// Une colonne est un mot dont l'octet `r` est la ligne `r`. L'octet `a`
    /// de la ligne 0 apporte (2s, s, s, 3s) au mélange, celui de la ligne 1
    /// (3s, 2s, s, s), et ainsi de suite en tournant ; au déchiffrement,
    /// (14, 9, 13, 11) fois l'inverse, en tournant de même.
    static func table(_ factors: [UInt8], _ box: [UInt8]?) -> [UInt32] {
        (0..<256).map { index in
            let value = box.map { $0[index] } ?? UInt8(index)
            return (0..<4).reduce(UInt32(0)) { sum, row in
                sum | UInt32(multiply(value, factors[row])) << (8 * UInt32(row))
            }
        }
    }

    static let encryptTables: [[UInt32]] = [[2, 1, 1, 3], [3, 2, 1, 1], [1, 3, 2, 1], [1, 1, 3, 2]]
        .map { table($0, substitution) }
    static let decryptTables: [[UInt32]] = [[14, 9, 13, 11], [11, 14, 9, 13], [13, 11, 14, 9], [9, 13, 11, 14]]
        .map { table($0, inverseSubstitution) }
    /// Le mélange inverse seul, pour `AESIMC` : les mêmes facteurs, sans
    /// la boîte.
    static let inverseMixTables: [[UInt32]] = [[14, 9, 13, 11], [11, 14, 9, 13], [13, 11, 14, 9], [9, 13, 11, 14]]
        .map { table($0, nil) }

    /// `AESENC`, `AESENCLAST`, `AESDEC`, `AESDECLAST` (66 0F 38 DC à DF) : un
    /// tour, la clé du tour dans la source. Le dernier tour n'a pas de
    /// mélange des colonnes. `AESIMC` (DB) : le mélange inverse seul, de la
    /// source, pour préparer les clés du déchiffrement.
    ///
    /// Le décalage des lignes est dans le choix des colonnes : la ligne `r`
    /// de la colonne `c` vient de la colonne `c + r` au chiffrement, `c − r`
    /// au déchiffrement.
    static func aesRound(_ opcode: UInt8, _ state: (low: UInt64, high: UInt64),
                         _ key: (low: UInt64, high: UInt64)) -> (UInt64, UInt64) {
        let columns = SIMD4<UInt32>(UInt32(truncatingIfNeeded: state.low), UInt32(truncatingIfNeeded: state.low >> 32),
                                    UInt32(truncatingIfNeeded: state.high), UInt32(truncatingIfNeeded: state.high >> 32))
        @inline(__always) func byte(_ column: Int, _ row: Int) -> Int {
            Int(truncatingIfNeeded: columns[column & 3] >> (8 * UInt32(row))) & 0xFF
        }
        func column(_ c: Int) -> UInt32 {
            switch opcode {
            case 0xDB:
                let keyColumn = UInt32(truncatingIfNeeded: (c < 2 ? key.low : key.high) >> (32 * UInt64(c & 1)))
                let tables = inverseMixTables
                return (0..<4).reduce(UInt32(0)) { sum, row in
                    sum ^ tables[row][Int(truncatingIfNeeded: keyColumn >> (8 * UInt32(row))) & 0xFF]
                }
            case 0xDC:
                let t = encryptTables
                return t[0][byte(c, 0)] ^ t[1][byte(c + 1, 1)] ^ t[2][byte(c + 2, 2)] ^ t[3][byte(c + 3, 3)]
            case 0xDE:
                let t = decryptTables
                return t[0][byte(c, 0)] ^ t[1][byte(c + 3, 1)] ^ t[2][byte(c + 2, 2)] ^ t[3][byte(c + 1, 3)]
            case 0xDD:
                let box = substitution
                return UInt32(box[byte(c, 0)]) | UInt32(box[byte(c + 1, 1)]) << 8
                    | UInt32(box[byte(c + 2, 2)]) << 16 | UInt32(box[byte(c + 3, 3)]) << 24
            default:
                let box = inverseSubstitution
                return UInt32(box[byte(c, 0)]) | UInt32(box[byte(c + 3, 1)]) << 8
                    | UInt32(box[byte(c + 2, 2)]) << 16 | UInt32(box[byte(c + 1, 3)]) << 24
            }
        }
        let out = (column(0), column(1), column(2), column(3))
        let low = UInt64(out.0) | UInt64(out.1) << 32
        let high = UInt64(out.2) | UInt64(out.3) << 32
        return opcode == 0xDB ? (low, high) : (low ^ key.low, high ^ key.high)
    }

    /// `AESKEYGENASSIST` (66 0F 3A DF) : de quoi dériver la clé du tour
    /// suivant — les mots 1 et 3 de la source passés par la boîte, puis
    /// tournés d'un octet et augmentés de la constante de l'immédiat.
    static func aesKeyAssist(_ source: (low: UInt64, high: UInt64), _ constant: UInt8) -> (UInt64, UInt64) {
        func subWord(_ word: UInt32) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { sum, index in
                sum | UInt32(substitution[Int(word >> (8 * UInt32(index)) & 0xFF)]) << (8 * UInt32(index))
            }
        }
        func rotWord(_ word: UInt32) -> UInt32 { word >> 8 | word << 24 }
        let x1 = subWord(UInt32(truncatingIfNeeded: source.low >> 32))
        let x3 = subWord(UInt32(truncatingIfNeeded: source.high >> 32))
        let rcon = UInt32(constant)
        return (UInt64(x1) | UInt64(rotWord(x1) ^ rcon) << 32, UInt64(x3) | UInt64(rotWord(x3) ^ rcon) << 32)
    }

    /// `PCLMULQDQ` (66 0F 3A 44) : le produit sans retenue de deux moitiés de
    /// soixante-quatre bits, choisies par les bits 0 (destination) et 4
    /// (source) de l'immédiat, en cent vingt-huit bits.
    static func carrylessMultiply(_ left: UInt64, _ right: UInt64) -> (UInt64, UInt64) {
        var low: UInt64 = 0
        var high: UInt64 = 0
        var bits = right
        while bits != 0 {
            let index = UInt64(bits.trailingZeroBitCount)
            low ^= left << index
            if index != 0 { high ^= left >> (64 - index) }
            bits &= bits - 1
        }
        return (low, high)
    }
}
