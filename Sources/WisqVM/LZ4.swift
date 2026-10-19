import Foundation

/// La compression LZ4, au format de bloc standard, écrite ici.
///
/// **Pourquoi ce format.** Une machine sauvée s'écrit au moment où iOS
/// reprend l'application, et ce moment ne dure que quelques secondes. La
/// session de Debian du 18 octobre pesait 217 Mio. zlib la ramène à 75 Mio,
/// mais en 3,6 s ; LZ4 à 98 Mio en 0,6 s (les deux mesurés en C, par blocs
/// d'un mébioctet). C'est la vitesse qui décide.
///
/// **Pourquoi écrite ici** : pour la raison de `CRC32` ou `SHA256Stream`.
/// `WisqVM` ne dépend que de Foundation, et la compression d'Apple n'existe
/// pas sous Linux, où tournent les tests.
///
/// **Le format est celui de `lz4.block`, sans en-tête** : une suite de
/// séquences, chacune un jeton (longueur des littéraux en haut, longueur de
/// la copie moins quatre en bas), les littéraux, puis un décalage de deux
/// octets. Un bloc qu'écrit la référence se relit ici ; c'est vérifié sur un
/// bloc qu'elle a écrit (`LZ4Tests`).
public enum LZ4 {
    public enum Failure: Error, Equatable {
        /// Le bloc ne se relit pas en la taille attendue.
        case corrupt
    }

    /// La copie la plus courte qu'on encode.
    static let minimumMatch = 4
    /// Les cinq derniers octets d'un bloc sont toujours des littéraux, et la
    /// dernière copie commence douze octets au moins avant la fin : ce sont
    /// les règles du format, que la référence suppose en relisant vite.
    static let lastLiterals = 5
    static let matchStartLimit = 12
    /// Quatre octets lus servent de clé à une table de 2¹⁶ positions.
    static let hashBits = 16

    /// Compresse `input` en un bloc.
    public static func compress(_ input: UnsafeRawBufferPointer) -> [UInt8] {
        let count = input.count
        var output = [UInt8]()
        output.reserveCapacity(count + count / 255 + 16)
        guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self), count > 0 else {
            output.append(0)
            return output
        }
        var table = [Int32](repeating: -1, count: 1 << hashBits)
        var anchor = 0
        var position = 0
        let limit = count - matchStartLimit

        @inline(__always) func word(_ at: Int) -> UInt32 {
            UnsafeRawPointer(source + at).loadUnaligned(as: UInt32.self)
        }
        @inline(__always) func length(_ value: Int, into output: inout [UInt8]) {
            var rest = value
            while rest >= 255 { output.append(255); rest -= 255 }
            output.append(UInt8(rest))
        }

        table.withUnsafeMutableBufferPointer { table in
            while position < limit {
                let sequence = word(position)
                let slot = Int((sequence &* 2_654_435_761) >> UInt32(32 - hashBits))
                let candidate = Int(table[slot])
                table[slot] = Int32(position)
                guard candidate >= 0, position - candidate <= 0xFFFF, word(candidate) == sequence else {
                    position += 1
                    continue
                }
                // La copie, aussi loin que les octets se ressemblent, sans
                // entrer dans les cinq derniers.
                var match = minimumMatch
                let end = count - lastLiterals
                while position + match < end, source[position + match] == source[candidate + match] {
                    match += 1
                }
                let literals = position - anchor
                let token = UInt8(min(literals, 15)) << 4 | UInt8(min(match - minimumMatch, 15))
                output.append(token)
                if literals >= 15 { length(literals - 15, into: &output) }
                output.append(contentsOf: UnsafeBufferPointer(start: source + anchor, count: literals))
                let offset = position - candidate
                output.append(UInt8(offset & 0xFF))
                output.append(UInt8(offset >> 8))
                if match - minimumMatch >= 15 { length(match - minimumMatch - 15, into: &output) }
                position += match
                anchor = position
            }
        }
        // Les derniers octets, en littéraux.
        let literals = count - anchor
        output.append(UInt8(min(literals, 15)) << 4)
        if literals >= 15 { length(literals - 15, into: &output) }
        output.append(contentsOf: UnsafeBufferPointer(start: source + anchor, count: literals))
        return output
    }

    /// Relit un bloc qui doit rendre exactement `size` octets.
    public static func decompress(_ block: UnsafeRawBufferPointer, size: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size)
        guard let input = block.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            if size == 0 { return output }
            throw Failure.corrupt
        }
        let inputCount = block.count
        try output.withUnsafeMutableBufferPointer { out in
            var read = 0
            var written = 0
            @inline(__always) func length(_ start: Int) throws -> Int {
                var total = start
                guard start == 15 else { return total }
                while true {
                    guard read < inputCount else { throw Failure.corrupt }
                    let byte = Int(input[read])
                    read += 1
                    total += byte
                    if byte != 255 { return total }
                }
            }
            while true {
                guard read < inputCount else { throw Failure.corrupt }
                let token = Int(input[read])
                read += 1
                let literals = try length(token >> 4)
                guard literals <= inputCount - read, literals <= size - written else { throw Failure.corrupt }
                if literals > 0 {
                    (out.baseAddress! + written).update(from: input + read, count: literals)
                }
                read += literals
                written += literals
                // Le dernier bloc s'arrête après ses littéraux.
                if read == inputCount { break }
                guard inputCount - read >= 2 else { throw Failure.corrupt }
                let offset = Int(input[read]) | Int(input[read + 1]) << 8
                read += 2
                let match = try length(token & 0x0F) + minimumMatch
                guard offset > 0, offset <= written, match <= size - written else { throw Failure.corrupt }
                let from = written - offset
                let base = out.baseAddress!
                if offset >= match {
                    // Les deux zones ne se touchent pas : une copie d'un bloc.
                    (base + written).update(from: base + from, count: match)
                } else {
                    // Octet par octet : la copie chevauche ce qu'elle écrit, et
                    // c'est ainsi qu'une longue suite se répète. La première
                    // version faisait toujours ainsi, et relisait la session de
                    // Debian en 1,3 s.
                    for index in 0..<match { base[written + index] = base[from + index] }
                }
                written += match
            }
            guard written == size else { throw Failure.corrupt }
        }
        return output
    }
}

/// **Le fichier d'une machine sauvée** : l'instantané, compressé par blocs
/// d'un mébioctet.
///
/// Derrière une marque à lui, `WISQLZ4` et une version, puis la taille
/// d'origine sur huit octets. Chaque bloc commence par sa longueur sur
/// quatre octets ; le bit de poids fort dit un bloc rangé tel quel, quand la
/// compression n'y gagnait rien (de la RAM déjà compressée par l'invité, par
/// exemple).
///
/// **Un fichier sans la marque est un instantané d'avant**, et se lit tel
/// quel : des machines sont déjà sauvées sur des téléphones, et elles doivent
/// revenir. Seul le fichier change, pas l'instantané : le cœur Rust, qui
/// partage le format de l'instantané octet pour octet, n'en voit rien.
public enum SnapshotFile {
    static let magic = Array("WISQLZ4".utf8) + [UInt8(1)]
    static let chunk = 1 << 20
    static let stored: UInt32 = 0x8000_0000

    public enum Failure: Error, Equatable {
        case corrupt
    }

    /// L'instantané, compressé.
    public static func pack(_ snapshot: Data) -> Data {
        var output = Data(magic)
        withUnsafeBytes(of: UInt64(snapshot.count).littleEndian) { output.append(contentsOf: $0) }
        snapshot.withUnsafeBytes { raw in
            var start = 0
            while start < raw.count {
                let piece = UnsafeRawBufferPointer(rebasing: raw[start..<min(start + chunk, raw.count)])
                let packed = LZ4.compress(piece)
                if packed.count < piece.count {
                    withUnsafeBytes(of: UInt32(packed.count).littleEndian) { output.append(contentsOf: $0) }
                    output.append(contentsOf: packed)
                } else {
                    withUnsafeBytes(of: (UInt32(piece.count) | stored).littleEndian) { output.append(contentsOf: $0) }
                    output.append(contentsOf: piece)
                }
                start += piece.count
            }
        }
        return output
    }

    /// L'instantané qu'un fichier contient : décompressé s'il porte la marque,
    /// tel quel sinon.
    public static func unpack(_ file: Data) throws -> Data {
        guard file.count >= magic.count, file.prefix(magic.count).elementsEqual(magic) else { return file }
        return try file.withUnsafeBytes { raw -> Data in
            var at = magic.count
            guard raw.count >= at + 8 else { throw Failure.corrupt }
            guard let total = Int(exactly: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: at,
                                                                                  as: UInt64.self)))
            else { throw Failure.corrupt }
            at += 8
            // Une taille annoncée démesurée ne doit pas faire réserver la
            // mémoire qu'elle prétend : un bloc d'un mébioctet donne au plus un
            // mébioctet, et il en faut un par mébioctet annoncé.
            guard total >= 0, total / chunk <= raw.count else { throw Failure.corrupt }
            var output = Data()
            output.reserveCapacity(total)
            while output.count < total {
                guard raw.count >= at + 4 else { throw Failure.corrupt }
                let header = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                at += 4
                let length = Int(header & ~stored)
                let size = min(chunk, total - output.count)
                guard raw.count - at >= length else { throw Failure.corrupt }
                let body = UnsafeRawBufferPointer(rebasing: raw[at..<(at + length)])
                if header & stored != 0 {
                    guard length == size else { throw Failure.corrupt }
                    output.append(contentsOf: body)
                } else {
                    guard let piece = try? LZ4.decompress(body, size: size) else { throw Failure.corrupt }
                    output.append(contentsOf: piece)
                }
                at += length
            }
            guard at == raw.count else { throw Failure.corrupt }
            return output
        }
    }
}
