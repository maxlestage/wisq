import Foundation
import WisqCore

#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256, and the fingerprint string wisq's pairing link is written in.
///
/// This file used to be four lines and a hole. Without CryptoKit `digest`
/// returned **empty `Data`** — not an error, not nil, a value shaped exactly
/// like an answer. Two other files in this repository name it as the mistake to
/// avoid: `SpiceLink` says "a digest built on it passes its tests by agreeing
/// with itself about nothing", and `SpiceLZ` cites "the shape of
/// `WisqNet.SHA256`" as the reason its own codec was written without a platform
/// behind it. The lesson was written down twice and the code was left as it was.
///
/// So it is corrected here, in the way both of those comments prescribe: the
/// fallback is integer work on bytes with no platform behind it, which means the
/// Linux runner that costs nothing checks it against the published vectors, and
/// the Apple runner checks that it and CryptoKit say the same thing about the
/// same bytes.
public enum SHA256 {
    public static func digest(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        // The hardware path where there is one; `pure` is held to it by
        // `SHA256Tests` on every Apple run.
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        return pure(data)
        #endif
    }

    /// The fingerprint as it appears in a `wisq://` link and as the agent prints
    /// it: lower case, no separators.
    ///
    /// It used to render `AA:BB:CC…` — a third spelling, belonging to no reader
    /// in this project. Nothing called it, so nothing broke, which is precisely
    /// how it stayed wrong: the first caller would have produced a string the
    /// phone's own parser rejects.
    public static func fingerprintString(_ data: Data) -> String {
        Hex.encode(digest(data))
    }

    // MARK: - The fallback

    /// SHA-256 as specified in FIPS 180-4, in nothing but `UInt32` arithmetic.
    ///
    /// Reachable in production only where CryptoKit is absent, but compiled and
    /// exercised everywhere: the tests call it by name so that the platform
    /// which cannot run it in anger still proves it right.
    static func pure(_ message: Data) -> Data {
        var state: [UInt32] = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
            0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
        ]

        // Padding: a single 1 bit, zeros up to 56 mod 64, then the *bit* length
        // big-endian. The message length is counted before any of that is
        // appended — reading it afterwards is the classic way to get every
        // input longer than 55 bytes wrong while the short ones stay right.
        var block = [UInt8](message)
        let bitCount = UInt64(block.count) &* 8
        block.append(0x80)
        while block.count % 64 != 56 { block.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            block.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < block.count {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] =
                    UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(schedule[index - 15], 7) ^ rotate(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotate(schedule[index - 2], 17) ^ rotate(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ schedule[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            for (index, value) in [a, b, c, d, e, f, g, h].enumerated() {
                state[index] &+= value
            }
            offset += 64
        }

        var out = Data(capacity: 32)
        for value in state {
            out.append(contentsOf: [
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
            ])
        }
        return out
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    /// The first thirty-two bits of the fractional parts of the cube roots of
    /// the first sixty-four primes, as the standard puts it.
    private static let constants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]
}
