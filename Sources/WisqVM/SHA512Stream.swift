import Foundation

/// SHA-512 par morceaux : la somme que Debian publie pour ses images
/// (`SHA512SUMS`), calculée sur un fichier de centaines de mégaoctets sans le
/// tenir en mémoire. La compression est celle de `SHA512Crypt`, écrite une
/// fois.
public struct SHA512Stream: Sendable {
    private var state = SHA512Crypt.initialState
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private var words = [UInt64](repeating: 0, count: 80)

    public init() {}

    public mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        let whole = pending.count / 128 * 128
        guard whole > 0 else { return }
        var state = state, words = words
        pending.withUnsafeBytes { raw in
            SHA512Crypt.compress(&state, UnsafeRawBufferPointer(rebasing: raw[0..<whole]), words: &words)
        }
        self.state = state
        self.words = words
        length &+= UInt64(whole) * 8
        pending.removeFirst(whole)
    }

    /// La somme, en 64 octets. La valeur est consommée : on ne finit qu'une
    /// fois. La longueur tient sur 64 bits ; les 64 de poids fort que prévoit
    /// la norme valent zéro pour tout fichier de moins de deux exbioctets.
    public consuming func finalize() -> [UInt8] {
        let bits = length &+ UInt64(pending.count) * 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 128 != 112 { tail.append(0) }
        tail += [UInt8](repeating: 0, count: 8)
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        var state = state, words = words
        tail.withUnsafeBytes { SHA512Crypt.compress(&state, $0, words: &words) }
        return SHA512Crypt.digest(state)
    }

    /// La somme de `bytes`, en hexadécimal minuscule.
    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var hash = SHA512Stream()
        hash.update(bytes)
        return SHA256Stream.hexString(hash.finalize())
    }

    /// La somme d'un fichier, lu par blocs d'un mégaoctet.
    public static func hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA512Stream()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(chunk)
        }
        return SHA256Stream.hexString(hash.finalize())
    }
}
