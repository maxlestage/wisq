import Foundation

/// SHA-256 (FIPS 180-4), par morceaux, sans dépendance.
///
/// **Pourquoi ici.** Une image téléchargée n'est gardée que si sa somme est
/// celle que la distribution publie ; c'est la seule chose qui distingue un
/// téléchargement complet d'un fichier tronqué ou altéré en route. CryptoKit
/// n'existe pas sous Linux, où tournent les tests, et `WisqVM` ne dépend que
/// de Foundation : la même somme, écrite une fois, tourne partout.
///
/// Par morceaux parce qu'une image fait des centaines de mégaoctets : elle est
/// lue et hachée bloc par bloc, jamais tenue entière en mémoire.
public struct SHA256: Sendable {
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    public init() {}

    public mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var start = 0
        while pending.count - start >= 64 {
            compress(pending[start..<(start + 64)])
            start += 64
            length &+= 512
        }
        if start > 0 { pending.removeFirst(start) }
    }

    /// La somme, en 32 octets. La valeur est consommée : on ne finit qu'une
    /// fois.
    public consuming func finalize() -> [UInt8] {
        let bits = length &+ UInt64(pending.count) * 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var start = 0
        while start < tail.count {
            compress(tail[start..<(start + 64)])
            start += 64
        }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) } }
    }

    /// La somme de `bytes`, en hexadécimal minuscule — la forme que publient
    /// les distributions.
    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var hash = SHA256()
        hash.update(bytes)
        return hexString(hash.finalize())
    }

    public static func hexString(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// La somme d'un fichier, lu par blocs d'un mégaoctet.
    public static func hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(chunk)
        }
        return hexString(hash.finalize())
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        var index = block.startIndex
        for t in 0..<16 {
            w[t] = UInt32(block[index]) << 24 | UInt32(block[index + 1]) << 16
                | UInt32(block[index + 2]) << 8 | UInt32(block[index + 3])
            index += 4
        }
        for t in 16..<64 {
            let s0 = w[t - 15].rotated(7) ^ w[t - 15].rotated(18) ^ (w[t - 15] >> 3)
            let s1 = w[t - 2].rotated(17) ^ w[t - 2].rotated(19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for t in 0..<64 {
            let s1 = e.rotated(6) ^ e.rotated(11) ^ e.rotated(25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ choice &+ Self.k[t] &+ w[t]
            let s0 = a.rotated(2) ^ a.rotated(13) ^ a.rotated(22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    /// Rotation à droite.
    func rotated(_ count: UInt32) -> UInt32 { self >> count | self << (32 - count) }
}
