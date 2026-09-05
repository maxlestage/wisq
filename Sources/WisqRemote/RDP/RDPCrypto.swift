import Foundation

/// Les primitives que la sécurité historique de RDP demande, et qu'aucune
/// plateforme ne donne partout.
///
/// **Pourquoi elles sont écrites ici.** CryptoKit n'existe pas sur Linux, où
/// ces tests tournent ; MD5 et RC4 n'existent plus dans les bibliothèques
/// modernes, précisément parce qu'ils sont cassés. RDP en a besoin quand même :
/// sa sécurité d'origine les emploie, et un serveur qui n'offre que celle-là ne
/// se laisse pas convaincre. Le dépôt écrit déjà DES et SHA-256 à la main pour
/// la même raison.
///
/// **Ce n'est pas de la cryptographie de confiance.** RC4 est cassé, MD5 aussi,
/// et l'échange de clés de RDP n'authentifie pas le serveur : n'importe qui sur
/// le chemin peut se mettre au milieu. C'est pourquoi wisq demande TLS d'abord
/// et ne descend ici que si le serveur ne sait rien faire d'autre — et le dit
/// alors à qui se connecte.
enum RDPCrypto {
    // MARK: - MD5

    static func md5(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]
        var block = message
        let bitCount = UInt64(message.count) * 8
        block.append(0x80)
        while block.count % 64 != 56 { block.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) { block.append(UInt8((bitCount >> UInt64(shift)) & 0xFF)) }

        for chunk in stride(from: 0, to: block.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let at = chunk + index * 4
                words[index] = UInt32(block[at]) | UInt32(block[at + 1]) << 8
                    | UInt32(block[at + 2]) << 16 | UInt32(block[at + 3]) << 24
            }
            var (a, b, c, d) = (state[0], state[1], state[2], state[3])
            for step in 0..<64 {
                var mixed: UInt32
                var index: Int
                switch step / 16 {
                case 0: mixed = (b & c) | (~b & d); index = step
                case 1: mixed = (d & b) | (~d & c); index = (5 * step + 1) % 16
                case 2: mixed = b ^ c ^ d; index = (3 * step + 5) % 16
                default: mixed = c ^ (b | ~d); index = (7 * step) % 16
                }
                let rotated = a &+ mixed &+ md5Sines[step] &+ words[index]
                a = d; d = c; c = b
                b = b &+ (rotated << md5Shifts[step] | rotated >> (32 - md5Shifts[step]))
            }
            state[0] = state[0] &+ a; state[1] = state[1] &+ b
            state[2] = state[2] &+ c; state[3] = state[3] &+ d
        }
        return state.flatMap { word in (0..<4).map { UInt8((word >> ($0 * 8)) & 0xFF) } }
    }

    static let md5Shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    /// La table de MD5, calculée plutôt que recopiée : `floor(|sin(i+1)| · 2³²)`.
    /// Soixante-quatre constantes écrites à la main sont soixante-quatre
    /// occasions de se tromper d'un chiffre, et l'erreur ne se verrait qu'au
    /// vecteur de test — si on en avait mis un qui la couvre.
    static let md5Sines: [UInt32] = (0..<64).map {
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296.0))
    }

    // MARK: - SHA-1

    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var block = message
        let bitCount = UInt64(message.count) * 8
        block.append(0x80)
        while block.count % 64 != 56 { block.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            block.append(UInt8((bitCount >> UInt64(shift)) & 0xFF))
        }
        for chunk in stride(from: 0, to: block.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let at = chunk + index * 4
                words[index] = UInt32(block[at]) << 24 | UInt32(block[at + 1]) << 16
                    | UInt32(block[at + 2]) << 8 | UInt32(block[at + 3])
            }
            for index in 16..<80 {
                let mixed = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
                words[index] = mixed << 1 | mixed >> 31
            }
            var (a, b, c, d, e) = (state[0], state[1], state[2], state[3], state[4])
            for step in 0..<80 {
                var mixed: UInt32
                var constant: UInt32
                switch step / 20 {
                case 0: mixed = (b & c) | (~b & d); constant = 0x5A82_7999
                case 1: mixed = b ^ c ^ d; constant = 0x6ED9_EBA1
                case 2: mixed = (b & c) | (b & d) | (c & d); constant = 0x8F1B_BCDC
                default: mixed = b ^ c ^ d; constant = 0xCA62_C1D6
                }
                let next = (a << 5 | a >> 27) &+ mixed &+ e &+ constant &+ words[step]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = next
            }
            state[0] = state[0] &+ a; state[1] = state[1] &+ b; state[2] = state[2] &+ c
            state[3] = state[3] &+ d; state[4] = state[4] &+ e
        }
        return state.flatMap { word in (0..<4).map { UInt8((word >> (24 - $0 * 8)) & 0xFF) } }
    }

    // MARK: - RC4

    /// Un flux RC4. Il porte son état : chiffrer deux messages veut dire
    /// continuer le même flux, pas le recommencer — un RC4 réinitialisé à
    /// chaque message donne deux textes chiffrés avec le même flux, ce qui les
    /// révèle tous les deux.
    struct RC4 {
        private var box: [UInt8]
        private var i = 0
        private var j = 0

        init(key: [UInt8]) {
            box = (0...255).map { UInt8($0) }
            guard !key.isEmpty else { return }
            var swap = 0
            for index in 0..<256 {
                swap = (swap + Int(box[index]) + Int(key[index % key.count])) & 0xFF
                box.swapAt(index, swap)
            }
        }

        mutating func process(_ data: [UInt8]) -> [UInt8] {
            var out = [UInt8](); out.reserveCapacity(data.count)
            for byte in data {
                i = (i + 1) & 0xFF
                j = (j + Int(box[i])) & 0xFF
                box.swapAt(i, j)
                out.append(byte ^ box[(Int(box[i]) + Int(box[j])) & 0xFF])
            }
            return out
        }
    }

    // MARK: - L'exponentiation modulaire

    /// `base^exponent mod modulus`, sur des entiers gros comme un module RSA.
    ///
    /// **RDP chiffre à l'envers de tout le monde** : les nombres y sont en
    /// **petit-boutiste**, module et exposant compris, là où toute autre
    /// utilisation de RSA les écrit en grand-boutiste. Les lire dans le mauvais
    /// sens donne un chiffré que le serveur déchiffre en bruit, et rien ne le
    /// dit — il ferme, c'est tout.
    static func modularPower(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        var result = BigNumber(1)
        var factor = BigNumber(littleEndian: base)
        let divisor = BigNumber(littleEndian: modulus)
        guard !divisor.isZero else { return [] }
        factor = factor.remainder(dividingBy: divisor)
        for byte in exponent {           // petit-boutiste : le bit de poids faible d'abord
            for bit in 0..<8 {
                if byte & (1 << UInt8(bit)) != 0 {
                    result = result.multiplied(by: factor).remainder(dividingBy: divisor)
                }
                factor = factor.multiplied(by: factor).remainder(dividingBy: divisor)
            }
        }
        var out = result.littleEndianBytes
        while out.count < modulus.count { out.append(0) }
        return Array(out.prefix(modulus.count))
    }

    /// Un entier positif de taille quelconque, en base 2³².
    ///
    /// Juste ce que l'exponentiation demande : multiplier, et prendre le reste.
    /// Pas de soustraction signée, pas d'inverse — ce qu'on n'écrit pas ne peut
    /// pas être faux.
    struct BigNumber {
        /// Les mots, du moins significatif au plus significatif, sans zéro de
        /// tête.
        private(set) var words: [UInt32]

        init(_ value: UInt32) { words = value == 0 ? [] : [value] }

        init(littleEndian bytes: [UInt8]) {
            words = []
            var index = 0
            while index < bytes.count {
                var word: UInt32 = 0
                for offset in 0..<4 where index + offset < bytes.count {
                    word |= UInt32(bytes[index + offset]) << (8 * offset)
                }
                words.append(word)
                index += 4
            }
            trim()
        }

        var isZero: Bool { words.isEmpty }

        var littleEndianBytes: [UInt8] {
            words.flatMap { word in (0..<4).map { UInt8((word >> ($0 * 8)) & 0xFF) } }
        }

        mutating func trim() { while words.last == 0 { words.removeLast() } }

        func multiplied(by other: BigNumber) -> BigNumber {
            guard !isZero, !other.isZero else { return BigNumber(0) }
            var product = [UInt32](repeating: 0, count: words.count + other.words.count)
            for (leftIndex, left) in words.enumerated() {
                var carry: UInt64 = 0
                for (rightIndex, right) in other.words.enumerated() {
                    let at = leftIndex + rightIndex
                    let sum = UInt64(left) * UInt64(right) + UInt64(product[at]) + carry
                    product[at] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                var at = leftIndex + other.words.count
                while carry > 0 {
                    let sum = UInt64(product[at]) + carry
                    product[at] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                    at += 1
                }
            }
            var out = BigNumber(0); out.words = product; out.trim()
            return out
        }

        /// Le reste, par division longue **mot à mot**.
        ///
        /// **Le premier jet divisait bit à bit** : quatre mille quatre-vingt-
        /// seize tours par reste, trente-quatre restes par exponentiation, et
        /// un test qui n'avait pas fini en dix minutes. Juste, et inutilisable
        /// — or ce code tourne sur un téléphone à chaque connexion.
        ///
        /// Celle-ci prend les mots un par un, du haut vers le bas, et estime
        /// chaque chiffre du quotient sur les deux mots de tête du reste.
        ///
        /// **La correction se fait avant de soustraire, jamais après.** Une
        /// estimation trop haute donne une soustraction qui passe sous zéro ;
        /// l'arithmétique est non signée, donc le résultat ne devient pas
        /// négatif — il devient énorme, et la boucle censée corriger ensuite
        /// ne finit jamais. C'est ce que faisait le deuxième jet, et c'est
        /// ainsi qu'un défaut de justesse se déguise en défaut de vitesse.
        func remainder(dividingBy divisor: BigNumber) -> BigNumber {
            guard !divisor.isZero else { return BigNumber(0) }
            if compare(divisor) < 0 { return self }
            let top = UInt64(divisor.words[divisor.words.count - 1])
            var rest = BigNumber(0)
            for wordIndex in stride(from: words.count - 1, through: 0, by: -1) {
                rest.shiftLeftOneWord(bringingIn: words[wordIndex])
                guard rest.compare(divisor) >= 0 else { continue }
                var high: UInt64 = 0
                if rest.words.count > divisor.words.count {
                    high = UInt64(rest.words[rest.words.count - 1]) << 32
                }
                let low = UInt64(rest.words[divisor.words.count - 1])
                var guess = min((high | low) / top, 0xFFFF_FFFF)
                var product = divisor.multiplied(byWord: UInt32(guess))
                while guess > 0, product.compare(rest) > 0 {
                    guess -= 1
                    product = divisor.multiplied(byWord: UInt32(guess))
                }
                if guess > 0 { rest.subtract(product) }
                while rest.compare(divisor) >= 0 { rest.subtract(divisor) }
            }
            return rest
        }

        /// Décaler d'un mot vers le haut en faisant entrer un mot par le bas.
        private mutating func shiftLeftOneWord(bringingIn value: UInt32) {
            if words.isEmpty {
                if value != 0 { words = [value] }
            } else {
                words.insert(value, at: 0)
            }
        }

        func multiplied(byWord factor: UInt32) -> BigNumber {
            guard factor != 0, !isZero else { return BigNumber(0) }
            var product = [UInt32](); product.reserveCapacity(words.count + 1)
            var carry: UInt64 = 0
            for word in words {
                let sum = UInt64(word) * UInt64(factor) + carry
                product.append(UInt32(truncatingIfNeeded: sum))
                carry = sum >> 32
            }
            if carry != 0 { product.append(UInt32(carry)) }
            var out = BigNumber(0); out.words = product; out.trim()
            return out
        }

        func compare(_ other: BigNumber) -> Int {
            if words.count != other.words.count { return words.count < other.words.count ? -1 : 1 }
            for index in stride(from: words.count - 1, through: 0, by: -1) where words[index] != other.words[index] {
                return words[index] < other.words[index] ? -1 : 1
            }
            return 0
        }

        mutating func subtract(_ other: BigNumber) {
            var borrow: Int64 = 0
            for index in words.indices {
                let right = index < other.words.count ? Int64(other.words[index]) : 0
                var value = Int64(words[index]) - right - borrow
                if value < 0 { value += 1 << 32; borrow = 1 } else { borrow = 0 }
                words[index] = UInt32(value)
            }
            trim()
        }
    }
}
