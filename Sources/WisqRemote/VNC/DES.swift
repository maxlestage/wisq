import Foundation

/// Single-block DES, needed only for the VNC authentication challenge (RFC 6143 §7.2.2).
///
/// DES is obsolete as a cipher and this is not a general-purpose implementation:
/// it exists because the VNC auth handshake is defined in terms of it. Anything
/// that must actually stay private should run over TLS (`TransportSecurity.tls`).
enum DES {
    /// Encrypts one 8-byte block in ECB mode with an 8-byte key.
    static func encryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block.count == 8 && key.count == 8, "DES works on 64-bit blocks and keys")

        let subkeys = makeSubkeys(key: key)
        var bits = permute(bitsFrom(block), table: ip)

        var left = Array(bits[0..<32])
        var right = Array(bits[32..<64])

        for round in 0..<16 {
            let previousRight = right
            let expanded = permute(right, table: e)
            var mixed = [UInt8](repeating: 0, count: 48)
            for i in 0..<48 { mixed[i] = expanded[i] ^ subkeys[round][i] }
            let substituted = substitute(mixed)
            let permuted = permute(substituted, table: p)
            for i in 0..<32 { right[i] = left[i] ^ permuted[i] }
            left = previousRight
        }

        // Final swap: the halves go back as R16 L16.
        bits = right + left
        let output = permute(bits, table: fp)
        return bytesFrom(output)
    }

    // MARK: - Key schedule

    private static func makeSubkeys(key: [UInt8]) -> [[UInt8]] {
        let permutedKey = permute(bitsFrom(key), table: pc1)
        var c = Array(permutedKey[0..<28])
        var d = Array(permutedKey[28..<56])

        var subkeys: [[UInt8]] = []
        for shift in shifts {
            c = rotateLeft(c, by: shift)
            d = rotateLeft(d, by: shift)
            subkeys.append(permute(c + d, table: pc2))
        }
        return subkeys
    }

    private static func rotateLeft(_ bits: [UInt8], by amount: Int) -> [UInt8] {
        Array(bits[amount...] + bits[..<amount])
    }

    // MARK: - Primitives

    /// Tables are 1-based, as printed in FIPS 46-3.
    private static func permute(_ bits: [UInt8], table: [Int]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: table.count)
        for (index, position) in table.enumerated() {
            output[index] = bits[position - 1]
        }
        return output
    }

    private static func substitute(_ bits: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 32)
        for box in 0..<8 {
            let base = box * 6
            let row = Int(bits[base]) << 1 | Int(bits[base + 5])
            let column = Int(bits[base + 1]) << 3 | Int(bits[base + 2]) << 2
                       | Int(bits[base + 3]) << 1 | Int(bits[base + 4])
            let value = sBoxes[box][row * 16 + column]
            for bit in 0..<4 {
                output[box * 4 + bit] = UInt8((value >> (3 - bit)) & 1)
            }
        }
        return output
    }

    /// MSB-first bit expansion, the order every DES table assumes.
    private static func bitsFrom(_ bytes: [UInt8]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: bytes.count * 8)
        for (byteIndex, byte) in bytes.enumerated() {
            for bit in 0..<8 {
                bits[byteIndex * 8 + bit] = UInt8((byte >> (7 - bit)) & 1)
            }
        }
        return bits
    }

    private static func bytesFrom(_ bits: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: bits.count / 8)
        for (index, bit) in bits.enumerated() {
            bytes[index / 8] |= bit << (7 - (index % 8))
        }
        return bytes
    }

    // MARK: - Tables (FIPS 46-3)

    private static let ip: [Int] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]

    private static let fp: [Int] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
        38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
        34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
    ]

    private static let e: [Int] = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9,
        8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
        16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25,
        24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
    ]

    private static let p: [Int] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
        2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
    ]

    private static let pc1: [Int] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
    ]

    private static let pc2: [Int] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
        23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
        44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
    ]

    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

    private static let sBoxes: [[Int]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
         0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
         15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],

        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
         3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
         13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],

        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
         13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
         1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],

        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
         13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
         3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],

        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
         14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
         11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],

        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
         10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
         4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],

        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
         13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
         6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],

        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
         1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
         2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]
}

enum VNCAuth {
    /// Answers the 16-byte challenge: two ECB blocks under a key made of the first
    /// 8 password bytes, each byte bit-reversed (the quirk every VNC server shares).
    static func response(challenge: Data, password: String) -> Data {
        let raw = password.data(using: .isoLatin1) ?? Data(password.utf8)
        var keyBytes = Array(raw.prefix(8))
        keyBytes += [UInt8](repeating: 0, count: 8 - keyBytes.count)
        let key = keyBytes.map(reverseBits)

        var response = Data()
        let bytes = [UInt8](challenge)
        for offset in stride(from: 0, to: min(bytes.count, 16), by: 8) {
            let block = Array(bytes[offset..<min(offset + 8, bytes.count)])
            guard block.count == 8 else { break }
            response.append(contentsOf: DES.encryptBlock(block, key: key))
        }
        return response
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}
