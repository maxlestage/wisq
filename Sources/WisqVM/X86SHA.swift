import Foundation

// **Les extensions SHA** : quatre tours de SHA-1, deux de SHA-256, et les
// calculs de leurs messages, chacun en une instruction.
//
// OpenSSL, la libgcrypt de GnuPG et apt, le noyau lui-même (`sha256_ni`)
// les prennent dès que `CPUID` les annonce (feuille 7, EBX, bit 29). Sans
// elles, chaque bloc de soixante-quatre octets coûte plusieurs centaines
// d'instructions de l'invité, que ce cœur interprète une à une ; avec
// elles, une quarantaine. Vérifier la somme d'un paquet, d'une image ou d'un
// certificat devient bien moins cher.
//
// Les sept instructions n'ont pas de préfixe : `0F 38 C8` à `CD`, et
// `0F 3A CC` pour les quatre tours de SHA-1. Aucune ne touche aux drapeaux.
// Les quatre mots de 32 bits d'un registre XMM se lisent ici du haut vers le
// bas, comme le manuel les nomme : `[3]` est le bit 127 à 96, `[0]` le 31 à
// 0. La référence est le processeur : `Tests/Fixtures/x86-v2-oracle.tsv`.
extension X86Core {
    /// Les quatre mots d'un registre, du plus bas au plus haut. Un
    /// `SIMD4` et pas un tableau : un tableau s'alloue sur le tas à chaque
    /// instruction, et la première mesure le payait — 191 s d'hôte pour
    /// cinq secondes de l'invité, contre 123 sans les instructions SHA.
    typealias Words = SIMD4<UInt32>

    static func words(_ value: (low: UInt64, high: UInt64)) -> Words {
        Words(UInt32(truncatingIfNeeded: value.low), UInt32(truncatingIfNeeded: value.low >> 32),
              UInt32(truncatingIfNeeded: value.high), UInt32(truncatingIfNeeded: value.high >> 32))
    }

    static func vector(words: Words) -> (UInt64, UInt64) {
        (UInt64(words[0]) | UInt64(words[1]) << 32, UInt64(words[2]) | UInt64(words[3]) << 32)
    }

    @inline(__always)
    static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value << count | value >> (32 - count)
    }

    @inline(__always)
    static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        value >> count | value << (32 - count)
    }

    /// `SHA1RNDS4` (0F 3A CC) : quatre tours de SHA-1. La destination porte
    /// A, B, C, D (A en haut) ; la source, les quatre mots du message, le
    /// premier déjà augmenté de E par `SHA1NEXTE`. Les deux bits bas de
    /// l'immédiat choisissent la fonction et la constante du quart.
    static func sha1FourRounds(_ state: Words, _ message: Words, _ selector: UInt8) -> Words {
        let constants = Words(0x5A82_7999, 0x6ED9_EBA1, 0x8F1B_BCDC, 0xCA62_C1D6)
        let kind = Int(selector & 3)
        func mix(_ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
            switch kind {
            case 0: return (b & c) ^ (~b & d)
            case 2: return (b & c) ^ (b & d) ^ (c & d)
            default: return b ^ c ^ d
            }
        }
        var (a, b, c, d, e) = (state[3], state[2], state[1], state[0], UInt32(0))
        let schedule = Words(message[3], message[2], message[1], message[0])
        for round in 0..<4 {
            let next = mix(b, c, d) &+ rotateLeft(a, 5) &+ schedule[round] &+ e &+ constants[kind]
            (e, d, c, b, a) = (d, c, rotateLeft(b, 30), a, next)
        }
        return Words(d, c, b, a)
    }

    /// `SHA1NEXTE` (0F 38 C8) : E du tour suivant, A tourné de 30, ajouté au
    /// premier mot du message ; les trois autres passent tels quels.
    static func sha1NextE(_ state: Words, _ message: Words) -> Words {
        Words(message[0], message[1], message[2], message[3] &+ rotateLeft(state[3], 30))
    }

    /// `SHA1MSG1` (0F 38 C9) : la première moitié du calcul des quatre mots
    /// suivants du message, des OU exclusifs.
    static func sha1Message1(_ first: Words, _ second: Words) -> Words {
        let (w0, w1, w2, w3) = (first[3], first[2], first[1], first[0])
        let (w4, w5) = (second[3], second[2])
        return Words(w5 ^ w3, w4 ^ w2, w3 ^ w1, w2 ^ w0)
    }

    /// `SHA1MSG2` (0F 38 CA) : la seconde moitié, et la rotation d'un bit. Le
    /// quatrième mot dépend du premier qu'elle vient de calculer.
    static func sha1Message2(_ first: Words, _ second: Words) -> Words {
        let (w13, w14, w15) = (second[2], second[1], second[0])
        let w16 = rotateLeft(first[3] ^ w13, 1)
        let w17 = rotateLeft(first[2] ^ w14, 1)
        let w18 = rotateLeft(first[1] ^ w15, 1)
        let w19 = rotateLeft(first[0] ^ w16, 1)
        return Words(w19, w18, w17, w16)
    }

    /// `SHA256RNDS2` (0F 38 CB) : deux tours de SHA-256. La destination porte
    /// C, D, G, H ; la source A, B, E, F ; **xmm0, implicite**, les deux mots
    /// du message déjà augmentés de leur constante. Le résultat : A et E
    /// après le second tour en haut de chaque moitié, après le premier en bas.
    static func sha256TwoRounds(_ cdgh: Words, _ abef: Words, _ keyed: Words) -> Words {
        var (a, b, c, d) = (abef[3], abef[2], cdgh[3], cdgh[2])
        var (e, f, g, h) = (abef[1], abef[0], cdgh[1], cdgh[0])
        var results = Words()
        for round in 0..<2 {
            let choose = (e & f) ^ (~e & g)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let sigma1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let sigma0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let partial = choose &+ sigma1 &+ keyed[round] &+ h
            let nextA = partial &+ majority &+ sigma0
            let nextE = partial &+ d
            (h, g, f, e) = (g, f, e, nextE)
            (d, c, b, a) = (c, b, a, nextA)
            results[round] = nextE
            results[round + 2] = nextA
        }
        return results
    }

    /// `SHA256MSG1` (0F 38 CC) : chaque mot plus σ0 de son suivant ; le
    /// suivant du dernier est le mot bas de la source.
    static func sha256Message1(_ first: Words, _ second: Words) -> Words {
        func sigma0(_ w: UInt32) -> UInt32 { rotateRight(w, 7) ^ rotateRight(w, 18) ^ (w >> 3) }
        return Words(first[0] &+ sigma0(first[1]), first[1] &+ sigma0(first[2]),
                first[2] &+ sigma0(first[3]), first[3] &+ sigma0(second[0]))
    }

    /// `SHA256MSG2` (0F 38 CD) : plus σ1 des mots 14 et 15 du message, puis
    /// des deux qu'elle vient de calculer.
    static func sha256Message2(_ first: Words, _ second: Words) -> Words {
        func sigma1(_ w: UInt32) -> UInt32 { rotateRight(w, 17) ^ rotateRight(w, 19) ^ (w >> 10) }
        let w16 = first[0] &+ sigma1(second[2])
        let w17 = first[1] &+ sigma1(second[3])
        let w18 = first[2] &+ sigma1(w16)
        let w19 = first[3] &+ sigma1(w17)
        return Words(w16, w17, w18, w19)
    }

    /// L'aiguillage des sept : la destination est le registre de `reg`, la
    /// source celui de `r/m` ou seize octets de la mémoire (sans exigence
    /// d'alignement, comme le processeur). `nil` : pas une instruction SHA.
    mutating func secureHash(_ instruction: X86Instruction, _ opcode: UInt8, map3A: Bool) throws -> Bool {
        guard map3A ? opcode == 0xCC : (0xC8...0xCD).contains(opcode) else { return false }
        let fields = try decodeFields(instruction)
        let destination = Self.words(vector(fields.reg))
        let read = try readVectorRM(fields, 16)
        let source = Self.words((low: read.0, high: read.1))
        let result: Words
        if map3A {
            result = Self.sha1FourRounds(destination, source, UInt8(truncatingIfNeeded: instruction.immediate))
        } else {
            switch opcode {
            case 0xC8: result = Self.sha1NextE(destination, source)
            case 0xC9: result = Self.sha1Message1(destination, source)
            case 0xCA: result = Self.sha1Message2(destination, source)
            case 0xCB: result = Self.sha256TwoRounds(destination, source, Self.words(vector(0)))
            case 0xCC: result = Self.sha256Message1(destination, source)
            default: result = Self.sha256Message2(destination, source)
            }
        }
        let packed = Self.vector(words: result)
        setVector(fields.reg, packed.0, packed.1)
        return true
    }
}
