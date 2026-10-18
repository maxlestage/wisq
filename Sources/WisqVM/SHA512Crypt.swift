import Foundation

/// SHA-512, et l'empreinte de mot de passe `$6$` qu'on en tire (« SHA-crypt »,
/// la spécification d'Ulrich Drepper, celle de la glibc et de libxcrypt).
///
/// **Pourquoi wisq calcule l'empreinte lui-même.** Le mot de passe de `root`
/// d'une image de cloud est donné à `systemd-firstboot` sur la ligne de
/// commande du noyau. Donné en clair, il y était lisible par tous dans
/// `/proc/cmdline`, et `systemd-firstboot` le chiffrait avec yescrypt, un
/// algorithme fait pour coûter : sur une machine qui exécute une quinzaine de
/// millions d'instructions par seconde, `login` expirait (après soixante
/// secondes) avant d'avoir fini de le vérifier. Une empreinte `$6$` à mille
/// tours se vérifie mille fois plus vite, et ne dit pas le mot de passe.
///
/// Écrit ici plutôt que pris ailleurs pour la même raison que `CRC32` ou
/// `SHA256Stream` : `WisqVM` ne dépend que de Foundation.
public enum SHA512Crypt {
    // MARK: - SHA-512

    static let roundConstants: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
        0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
        0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
        0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
        0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
        0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
        0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
        0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
        0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    /// L'état de départ de SHA-512.
    static let initialState: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    /// Le condensé SHA-512 de `bytes` : soixante-quatre octets.
    public static func sha512(_ bytes: [UInt8]) -> [UInt8] {
        var state = initialState
        var message = bytes
        message.append(0x80)
        while message.count % 128 != 112 { message.append(0) }
        let bits = UInt64(bytes.count) &* 8
        message += [UInt8](repeating: 0, count: 8)
        message += (0..<8).map { UInt8(truncatingIfNeeded: bits >> (56 - 8 * UInt64($0))) }
        var words = [UInt64](repeating: 0, count: 80)
        message.withUnsafeBytes { compress(&state, $0, words: &words) }
        return digest(state)
    }

    /// Les huit mots de l'état, octet de poids fort d'abord.
    static func digest(_ state: [UInt64]) -> [UInt8] {
        state.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> (56 - 8 * UInt64($0))) } }
    }

    /// **Tous les blocs entiers de `bytes`**, à la suite, mêlés à `state` ;
    /// `words` est un tampon de quatre-vingts mots que l'appelant garde d'un
    /// appel à l'autre. Partagé avec `SHA512Stream`. Écrit sur des
    /// pointeurs, sans tableau intermédiaire : la première version, à coups
    /// de `reduce` et de tableaux par bloc, hachait l'image de Debian
    /// (390 Mio) en 25 s, le temps de laisser croire à un téléphone figé ;
    /// celle-ci le fait en 1,4 s.
    static func compress(_ state: inout [UInt64], _ bytes: UnsafeRawBufferPointer, words: inout [UInt64]) {
        let blocks = bytes.count / 128
        guard blocks > 0, let base = bytes.baseAddress else { return }
        roundConstants.withUnsafeBufferPointer { k in
            words.withUnsafeMutableBufferPointer { w in
                var (a0, b0, c0, d0) = (state[0], state[1], state[2], state[3])
                var (e0, f0, g0, h0) = (state[4], state[5], state[6], state[7])
                for block in 0..<blocks {
                    let start = base + block * 128
                    for index in 0..<16 {
                        w[index] = UInt64(bigEndian: start.loadUnaligned(fromByteOffset: 8 * index, as: UInt64.self))
                    }
                    for index in 16..<80 {
                        let low = w[index - 15], high = w[index - 2]
                        let sigma0 = rotate(low, 1) ^ rotate(low, 8) ^ (low >> 7)
                        let sigma1 = rotate(high, 19) ^ rotate(high, 61) ^ (high >> 6)
                        w[index] = w[index - 16] &+ sigma0 &+ w[index - 7] &+ sigma1
                    }
                    var (a, b, c, d, e, f, g, h) = (a0, b0, c0, d0, e0, f0, g0, h0)
                    for index in 0..<80 {
                        let sum1 = rotate(e, 14) ^ rotate(e, 18) ^ rotate(e, 41)
                        let choice = (e & f) ^ (~e & g)
                        let first = h &+ sum1 &+ choice &+ k[index] &+ w[index]
                        let sum0 = rotate(a, 28) ^ rotate(a, 34) ^ rotate(a, 39)
                        let majority = (a & b) ^ (a & c) ^ (b & c)
                        h = g; g = f; f = e; e = d &+ first
                        d = c; c = b; b = a; a = first &+ sum0 &+ majority
                    }
                    a0 &+= a; b0 &+= b; c0 &+= c; d0 &+= d
                    e0 &+= e; f0 &+= f; g0 &+= g; h0 &+= h
                }
                state = [a0, b0, c0, d0, e0, f0, g0, h0]
            }
        }
    }

    @inline(__always)
    private static func rotate(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }

    // MARK: - `$6$`

    /// L'alphabet de `crypt`, qui n'est pas celui de base64.
    static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    /// L'empreinte `$6$` de `password`. `salt` : seize caractères au plus de
    /// l'alphabet de `crypt` (au-delà, la spécification les ignore).
    /// `rounds` : 5000 par défaut, et alors absent de l'empreinte ; ailleurs
    /// entre 1000 et 999 999 999, et écrit.
    public static func hash(_ password: String, salt: String, rounds: Int = 5000) -> String {
        let key = Array(password.utf8)
        let saltBytes = Array(salt.utf8.prefix(16))
        let rounds = min(max(rounds, 1000), 999_999_999)

        // B, puis A : le texte, le sel, et B répété sur la longueur du texte.
        let alternate = sha512(key + saltBytes + key)
        var context = key + saltBytes
        var remaining = key.count
        while remaining > 64 { context += alternate; remaining -= 64 }
        context += alternate.prefix(remaining)
        var length = key.count
        while length > 0 {
            context += length & 1 != 0 ? alternate : key
            length >>= 1
        }
        var digest = sha512(context)

        // P : le texte, autant de fois qu'il a d'octets ; S : le sel, 16 + A[0] fois.
        let passwordDigest = sha512([UInt8]((0..<key.count).flatMap { _ in key }))
        let pSequence = Array((0..<(key.count / 64)).flatMap { _ in passwordDigest }
                              + passwordDigest.prefix(key.count % 64))
        let saltDigest = sha512([UInt8]((0..<(16 + Int(digest[0]))).flatMap { _ in saltBytes }))
        let sSequence = Array((0..<(saltBytes.count / 64)).flatMap { _ in saltDigest }
                              + saltDigest.prefix(saltBytes.count % 64))

        for round in 0..<rounds {
            var step = round & 1 != 0 ? pSequence : digest
            if round % 3 != 0 { step += sSequence }
            if round % 7 != 0 { step += pSequence }
            step += round & 1 != 0 ? digest : pSequence
            digest = sha512(step)
        }

        // L'ordre des octets imposé par la spécification, trois par trois.
        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var encoded: [UInt8] = []
        func emit(_ value: UInt32, _ count: Int) {
            var value = value
            for _ in 0..<count {
                encoded.append(alphabet[Int(value & 0x3F)])
                value >>= 6
            }
        }
        for (first, second, third) in order {
            emit(UInt32(digest[first]) << 16 | UInt32(digest[second]) << 8 | UInt32(digest[third]), 4)
        }
        emit(UInt32(digest[63]), 2)

        let roundsField = rounds == 5000 ? "" : "rounds=\(rounds)$"
        return "$6$" + roundsField + String(decoding: saltBytes, as: UTF8.self) + "$"
            + String(decoding: encoded, as: UTF8.self)
    }
}
