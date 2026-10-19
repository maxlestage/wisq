import Foundation

/// La décompression zstd (RFC 8878), écrite ici.
///
/// **Pourquoi.** L'image de cloud de Fedora range son noyau dans un btrfs
/// dont les fichiers sont compressés en zstd ; pour démarrer cette image
/// telle qu'elle a été téléchargée, il faut lire ces fichiers. Écrite ici pour
/// la raison de `LZ4` ou `Inflate` : `WisqVM` ne dépend que de Foundation, et
/// rien de zstd n'existe dans le système, ni sous Linux ni chez Apple.
///
/// **Ce qui est lu** : les trames zstd et les trames à sauter, les trois
/// sortes de blocs (bruts, répétés, compressés), les littéraux bruts, répétés
/// ou en Huffman (un ou quatre flux, l'arbre réutilisé d'un bloc au suivant),
/// et les séquences en FSE, avec les tables prédéfinies, répétées ou décrites
/// et les trois décalages répétés. **Ce qui ne l'est pas, en le disant** :
/// les dictionnaires. La somme de contrôle de fin de trame est sautée sans
/// être vérifiée : le contenu est déjà gardé par ce qui l'entoure.
public enum Zstd {
    public enum Failure: Error, Equatable {
        /// Ce n'est pas une trame zstd.
        case notZstd
        /// Une trame qui demande un dictionnaire.
        case dictionary
        /// Les octets finissent avant la trame, ou se contredisent.
        case corrupt(String)
    }

    static let magic: UInt32 = 0xFD2F_B528

    /// Toutes les trames de `input`, mises bout à bout.
    public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8]()
        var reader = ForwardReader(input)
        guard reader.remaining >= 4 else { throw Failure.notZstd }
        var first = true
        while reader.remaining > 0 {
            let word = try reader.u32()
            if word & 0xFFFF_FFF0 == 0x184D_2A50 {
                // Une trame à sauter : sa taille, puis autant d'octets.
                let size = Int(try reader.u32())
                try reader.skip(size)
            } else if word == magic {
                try decodeFrame(&reader, into: &output)
            } else {
                throw first ? Failure.notZstd : Failure.corrupt("trame inconnue")
            }
            first = false
        }
        return output
    }

    /// Vrai si `bytes` commence comme une trame zstd.
    public static func looksLikeZstd(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24 == magic
    }

    // MARK: - La trame

    static func decodeFrame(_ reader: inout ForwardReader, into output: inout [UInt8]) throws {
        let descriptor = try reader.byte()
        let contentSizeFlag = descriptor >> 6
        let singleSegment = descriptor & 0x20 != 0
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryFlag = descriptor & 0x03
        guard descriptor & 0x08 == 0 else { throw Failure.corrupt("bit réservé posé") }
        if !singleSegment { _ = try reader.byte() }  // la fenêtre : on décode tout en mémoire
        let dictionaryBytes = [0, 1, 2, 4][Int(dictionaryFlag)]
        var dictionary: UInt64 = 0
        for index in 0..<dictionaryBytes { dictionary |= UInt64(try reader.byte()) << (8 * UInt64(index)) }
        guard dictionary == 0 else { throw Failure.dictionary }
        let contentSizeBytes = contentSizeFlag == 0 ? (singleSegment ? 1 : 0) : [0, 2, 4, 8][Int(contentSizeFlag)]
        var contentSize: UInt64?
        if contentSizeBytes > 0 {
            var value: UInt64 = 0
            for index in 0..<contentSizeBytes { value |= UInt64(try reader.byte()) << (8 * UInt64(index)) }
            contentSize = contentSizeBytes == 2 ? value + 256 : value
        }
        let start = output.count
        if let contentSize, contentSize < 1 << 32 { output.reserveCapacity(start + Int(contentSize)) }

        var state = FrameState()
        while true {
            let header = UInt32(try reader.byte()) | UInt32(try reader.byte()) << 8
                | UInt32(try reader.byte()) << 16
            let last = header & 1 != 0
            let size = Int(header >> 3)
            switch (header >> 1) & 3 {
            case 0:
                output.append(contentsOf: try reader.bytes(size))
            case 1:
                let value = try reader.byte()
                output.append(contentsOf: repeatElement(value, count: size))
            case 2:
                let block = try reader.bytes(size)
                try decodeCompressedBlock(block, &state, into: &output, frameStart: start)
            default:
                throw Failure.corrupt("bloc de type réservé")
            }
            if last { break }
        }
        if let contentSize, UInt64(output.count - start) != contentSize {
            throw Failure.corrupt("taille de contenu annoncée \(contentSize), lue \(output.count - start)")
        }
        if hasChecksum { try reader.skip(4) }
    }

    /// Ce qu'un bloc compressé laisse au suivant, dans la même trame.
    struct FrameState {
        var huffman: HuffmanTable?
        var literalLengths: FSETable?
        var offsets: FSETable?
        var matchLengths: FSETable?
        var repeats: (UInt64, UInt64, UInt64) = (1, 4, 8)
    }

    // MARK: - Le bloc compressé

    static func decodeCompressedBlock(_ block: [UInt8], _ state: inout FrameState,
                                      into output: inout [UInt8], frameStart: Int) throws {
        var reader = ForwardReader(block)
        let literals = try decodeLiterals(&reader, &state)
        try decodeSequences(&reader, literals: literals, &state, into: &output, frameStart: frameStart)
    }

    static func decodeLiterals(_ reader: inout ForwardReader, _ state: inout FrameState) throws -> [UInt8] {
        let first = try reader.byte()
        let kind = first & 3
        let sizeFormat = (first >> 2) & 3
        if kind < 2 {
            // Bruts ou répétés : seulement la taille régénérée.
            var size: Int
            switch sizeFormat {
            case 0, 2: size = Int(first >> 3)
            case 1: size = Int(first >> 4) | Int(try reader.byte()) << 4
            default:
                size = Int(first >> 4) | Int(try reader.byte()) << 4
                size |= Int(try reader.byte()) << 12
            }
            if kind == 0 { return try reader.bytes(size) }
            return [UInt8](repeating: try reader.byte(), count: size)
        }
        // En Huffman, avec ou sans arbre neuf.
        let b1 = Int(try reader.byte()), b2 = Int(try reader.byte())
        let regenerated: Int, compressed: Int, streams: Int
        switch sizeFormat {
        case 0, 1:
            streams = sizeFormat == 0 ? 1 : 4
            regenerated = Int(first >> 4) | (b1 & 0x3F) << 4
            compressed = b1 >> 6 | b2 << 2
        case 2:
            streams = 4
            let b3 = Int(try reader.byte())
            regenerated = Int(first >> 4) | b1 << 4 | (b2 & 3) << 12
            compressed = b2 >> 2 | b3 << 6
        default:
            streams = 4
            let b3 = Int(try reader.byte()), b4 = Int(try reader.byte())
            regenerated = Int(first >> 4) | b1 << 4 | (b2 & 0x3F) << 12
            compressed = b2 >> 6 | b3 << 2 | b4 << 10
        }
        var payload = ForwardReader(try reader.bytes(compressed))
        if kind == 2 {
            state.huffman = try HuffmanTable.read(&payload)
        }
        guard let table = state.huffman else { throw Failure.corrupt("littéraux sans arbre de Huffman") }
        let rest = try payload.bytes(payload.remaining)
        if streams == 1 {
            return try table.decode(rest[...], count: regenerated)
        }
        guard rest.count >= 6 else { throw Failure.corrupt("table des quatre flux tronquée") }
        let sizes = (0..<3).map { Int(rest[2 * $0]) | Int(rest[2 * $0 + 1]) << 8 }
        let perStream = (regenerated + 3) / 4
        var output = [UInt8]()
        output.reserveCapacity(regenerated)
        var offset = 6
        for index in 0..<4 {
            let size = index < 3 ? sizes[index] : rest.count - offset
            guard size >= 0, offset + size <= rest.count else { throw Failure.corrupt("flux de littéraux hors bloc") }
            let count = index < 3 ? perStream : regenerated - 3 * perStream
            output += try table.decode(rest[offset..<(offset + size)], count: count)
            offset += size
        }
        return output
    }

    // MARK: - Les séquences

    static func decodeSequences(_ reader: inout ForwardReader, literals: [UInt8], _ state: inout FrameState,
                                into output: inout [UInt8], frameStart: Int) throws {
        var count = 0
        if reader.remaining > 0 {
            let b0 = Int(try reader.byte())
            if b0 < 128 {
                count = b0
            } else if b0 < 255 {
                count = (b0 - 128) << 8 | Int(try reader.byte())
            } else {
                count = Int(try reader.byte()) | Int(try reader.byte()) << 8
                count += 0x7F00
            }
        }
        if count == 0 {
            output.append(contentsOf: literals)
            return
        }
        let modes = try reader.byte()
        state.literalLengths = try table(mode: modes >> 6, &reader, previous: state.literalLengths,
                                         kind: .literalLength)
        state.offsets = try table(mode: (modes >> 4) & 3, &reader, previous: state.offsets, kind: .offset)
        state.matchLengths = try table(mode: (modes >> 2) & 3, &reader, previous: state.matchLengths,
                                       kind: .matchLength)
        guard let literalTable = state.literalLengths, let offsetTable = state.offsets,
              let matchTable = state.matchLengths else { throw Failure.corrupt("table manquante") }

        var bits = try BackwardReader(try reader.bytes(reader.remaining)[...])
        var literalState = bits.read(literalTable.accuracy)
        var offsetState = bits.read(offsetTable.accuracy)
        var matchState = bits.read(matchTable.accuracy)
        var literalIndex = 0
        var repeats = state.repeats

        for sequence in 0..<count {
            let offsetCode = Int(offsetTable.entries[offsetState].symbol)
            let matchCode = Int(matchTable.entries[matchState].symbol)
            let literalCode = Int(literalTable.entries[literalState].symbol)
            guard offsetCode <= 31, matchCode < Self.matchLengthBase.count,
                  literalCode < Self.literalLengthBase.count else { throw Failure.corrupt("code de séquence") }
            let offsetValue = (UInt64(1) << UInt64(offsetCode)) + UInt64(bits.read(offsetCode))
            let matchLength = Self.matchLengthBase[matchCode] + bits.read(Self.matchLengthBits[matchCode])
            let literalLength = Self.literalLengthBase[literalCode]
                + bits.read(Self.literalLengthBits[literalCode])

            // Les trois décalages répétés, et le sens décalé d'un cran quand
            // la séquence n'a pas de littéraux.
            let offset: UInt64
            if offsetValue > 3 {
                offset = offsetValue - 3
                repeats = (offset, repeats.0, repeats.1)
            } else {
                switch Int(offsetValue) + (literalLength == 0 ? 1 : 0) {
                case 1: offset = repeats.0
                case 2: offset = repeats.1; repeats = (repeats.1, repeats.0, repeats.2)
                case 3: offset = repeats.2; repeats = (repeats.2, repeats.0, repeats.1)
                default:
                    offset = repeats.0 &- 1
                    repeats = (offset, repeats.0, repeats.1)
                }
            }

            guard literalIndex + literalLength <= literals.count else {
                throw Failure.corrupt("séquence au-delà des littéraux")
            }
            output.append(contentsOf: literals[literalIndex..<(literalIndex + literalLength)])
            literalIndex += literalLength
            guard offset > 0, offset <= UInt64(output.count - frameStart) else {
                throw Failure.corrupt("copie avant le début de la trame")
            }
            // **En place.** `append(contentsOf: output[…])` tenait une tranche
            // du tableau qu'il agrandissait, et chaque copie recopiait alors le
            // tableau entier : 57 s pour 20 Mio, le temps d'un carré.
            let from = output.count - Int(offset)
            let end = output.count
            output.append(contentsOf: repeatElement(0, count: matchLength))
            output.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                if Int(offset) >= matchLength {
                    (base + end).update(from: base + from, count: matchLength)
                } else {
                    // Une copie qui chevauche ce qu'elle écrit : octet par octet.
                    for index in 0..<matchLength { base[end + index] = base[from + index] }
                }
            }

            if sequence < count - 1 {
                literalState = literalTable.next(literalState, &bits)
                matchState = matchTable.next(matchState, &bits)
                offsetState = offsetTable.next(offsetState, &bits)
            }
        }
        guard bits.exhausted else { throw Failure.corrupt("bits de séquences restants") }
        output.append(contentsOf: literals[literalIndex...])
        state.repeats = repeats
    }

    enum SequenceKind {
        case literalLength, offset, matchLength

        var maximumSymbol: Int {
            switch self {
            case .literalLength: return 35
            case .offset: return 31
            case .matchLength: return 52
            }
        }

        var maximumAccuracy: Int {
            switch self {
            case .literalLength, .matchLength: return 9
            case .offset: return 8
            }
        }

        var predefined: FSETable {
            switch self {
            case .literalLength: return Zstd.predefinedLiteralLengths
            case .offset: return Zstd.predefinedOffsets
            case .matchLength: return Zstd.predefinedMatchLengths
            }
        }
    }

    static func table(mode: UInt8, _ reader: inout ForwardReader, previous: FSETable?,
                      kind: SequenceKind) throws -> FSETable {
        switch mode {
        case 0: return kind.predefined
        case 1: return FSETable(single: try reader.byte())
        case 2:
            let (counts, accuracy) = try FSETable.readCounts(&reader, maximumSymbol: kind.maximumSymbol,
                                                             maximumAccuracy: kind.maximumAccuracy)
            return try FSETable(counts: counts, accuracy: accuracy)
        default:
            guard let previous else { throw Failure.corrupt("table répétée sans table d'avant") }
            return previous
        }
    }

    // Les longueurs : une base et des bits en plus, par code (RFC 8878, 3.1.1.3.2.1).
    static let literalLengthBase: [Int] = Array(0..<16) + [
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
    ]
    static let literalLengthBits: [Int] = [Int](repeating: 0, count: 16) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
    static let matchLengthBase: [Int] = Array(3..<35) + [
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
    ]
    static let matchLengthBits: [Int] = [Int](repeating: 0, count: 32) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]

    // Les distributions prédéfinies (RFC 8878, 3.1.1.3.2.2).
    static let predefinedLiteralLengths = try! FSETable(counts: [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ], accuracy: 6)
    static let predefinedMatchLengths = try! FSETable(counts: [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
    ], accuracy: 6)
    static let predefinedOffsets = try! FSETable(counts: [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ], accuracy: 5)
}

// MARK: - Les lecteurs de bits

extension Zstd {
    /// Des octets lus dans l'ordre.
    struct ForwardReader {
        let data: [UInt8]
        var position = 0

        init(_ data: [UInt8]) { self.data = data }

        var remaining: Int { data.count - position }

        mutating func byte() throws -> UInt8 {
            guard position < data.count else { throw Failure.corrupt("fin des données") }
            defer { position += 1 }
            return data[position]
        }

        mutating func u32() throws -> UInt32 {
            var value: UInt32 = 0
            for index in 0..<4 { value |= UInt32(try byte()) << (8 * UInt32(index)) }
            return value
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw Failure.corrupt("fin des données") }
            defer { position += count }
            return Array(data[position..<(position + count)])
        }

        mutating func skip(_ count: Int) throws { _ = try bytes(count) }
    }

    /// **Un flux lu à l'envers.** zstd écrit ses flux de bits de la fin vers
    /// le début : le dernier octet porte un bit 1 de garde au-dessus des
    /// derniers bits utiles, et chaque lecture prend les bits du haut. On voit
    /// le flux comme un grand entier petit-boutiste dont on lit des tranches en
    /// descendant ; lire avant le début rend des zéros, ce que le décodage de
    /// Huffman fait en fin de flux, et `overflowed` le dit.
    struct BackwardReader {
        let data: ArraySlice<UInt8>
        /// Le nombre de bits pas encore lus, depuis le début du flux.
        var position: Int

        init(_ data: ArraySlice<UInt8>) throws {
            guard let last = data.last, last != 0 else { throw Failure.corrupt("flux sans bit de garde") }
            self.data = data
            position = (data.count - 1) * 8 + (7 - last.leadingZeroBitCount)
        }

        var overflowed: Bool { position < 0 }
        var exhausted: Bool { position == 0 }

        /// Les `count` bits sous `position`, sans avancer.
        func peek(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            let low = position - count
            var value = 0
            var bit = max(low, 0)
            // Octet par octet : les bits [bit, position) du grand entier.
            while bit < position {
                let byteIndex = data.startIndex + bit / 8
                let shift = bit % 8
                let take = min(8 - shift, position - bit)
                let chunk = (Int(data[byteIndex]) >> shift) & ((1 << take) - 1)
                value |= chunk << (bit - low)
                bit += take
            }
            return value
        }

        mutating func read(_ count: Int) -> Int {
            let value = peek(count)
            position -= count
            return value
        }
    }
}

// MARK: - Huffman

extension Zstd {
    struct HuffmanTable {
        /// Indexée par les `maximumBits` bits du haut : le symbole, et combien
        /// de ces bits il consomme vraiment.
        let symbols: [UInt8]
        let lengths: [UInt8]
        let maximumBits: Int

        static func read(_ reader: inout ForwardReader) throws -> HuffmanTable {
            let header = Int(try reader.byte())
            var weights: [UInt8]
            if header >= 128 {
                // Directs : quatre bits par poids, le premier dans le haut.
                let count = header - 127
                let packed = try reader.bytes((count + 1) / 2)
                weights = (0..<count).map { index in
                    let byte = packed[index / 2]
                    return index % 2 == 0 ? byte >> 4 : byte & 0x0F
                }
            } else {
                weights = try decodeWeights(try reader.bytes(header))
            }
            return try HuffmanTable(weights: weights)
        }

        /// Les poids compressés en FSE : deux états entrelacés, jusqu'au bout
        /// du flux.
        static func decodeWeights(_ bytes: [UInt8]) throws -> [UInt8] {
            var reader = ForwardReader(bytes)
            let (counts, accuracy) = try FSETable.readCounts(&reader, maximumSymbol: 255, maximumAccuracy: 6)
            let table = try FSETable(counts: counts, accuracy: accuracy)
            var bits = try BackwardReader(bytes[reader.position...])
            var first = bits.read(accuracy)
            var second = bits.read(accuracy)
            var weights = [UInt8]()
            while weights.count < 255 {
                weights.append(table.entries[first].symbol)
                first = table.next(first, &bits)
                if bits.overflowed {
                    weights.append(table.entries[second].symbol)
                    break
                }
                weights.append(table.entries[second].symbol)
                second = table.next(second, &bits)
                if bits.overflowed {
                    weights.append(table.entries[first].symbol)
                    break
                }
            }
            return weights
        }

        init(weights given: [UInt8]) throws {
            guard !given.isEmpty, given.count < 256 else { throw Failure.corrupt("poids de Huffman") }
            // Le dernier poids est sous-entendu : celui qui complète la somme
            // jusqu'à la puissance de deux suivante.
            var total = 0
            for weight in given where weight > 0 {
                guard weight <= 12 else { throw Failure.corrupt("poids de Huffman trop grand") }
                total += 1 << (Int(weight) - 1)
            }
            guard total > 0 else { throw Failure.corrupt("arbre de Huffman vide") }
            let maximumBits = Int.bitWidth - total.leadingZeroBitCount
            let rest = (1 << maximumBits) - total
            guard rest > 0, rest & (rest - 1) == 0 else { throw Failure.corrupt("arbre de Huffman incomplet") }
            let weights = given + [UInt8(rest.trailingZeroBitCount + 1)]
            guard maximumBits <= 11 else { throw Failure.corrupt("arbre de Huffman trop profond") }

            // Les symboles du plus petit poids au plus grand, dans l'ordre des
            // valeurs à poids égal, chacun sur 2^(poids-1) cases consécutives.
            let size = 1 << maximumBits
            var symbols = [UInt8](repeating: 0, count: size)
            var lengths = [UInt8](repeating: 0, count: size)
            var next = 0
            for weight in 1...maximumBits {
                for (symbol, w) in weights.enumerated() where Int(w) == weight {
                    let span = 1 << (weight - 1)
                    for slot in next..<(next + span) {
                        symbols[slot] = UInt8(symbol)
                        lengths[slot] = UInt8(maximumBits + 1 - weight)
                    }
                    next += span
                }
            }
            guard next == size else { throw Failure.corrupt("arbre de Huffman mal rempli") }
            self.symbols = symbols
            self.lengths = lengths
            self.maximumBits = maximumBits
        }

        func decode(_ stream: ArraySlice<UInt8>, count: Int) throws -> [UInt8] {
            var output = [UInt8]()
            output.reserveCapacity(count)
            guard count > 0 else { return output }
            var bits = try BackwardReader(stream)
            for _ in 0..<count {
                let index = bits.peek(maximumBits)
                output.append(symbols[index])
                bits.position -= Int(lengths[index])
            }
            guard bits.exhausted else { throw Failure.corrupt("flux de Huffman mal terminé") }
            return output
        }
    }
}

// MARK: - FSE

extension Zstd {
    struct FSETable {
        struct Entry {
            var symbol: UInt8
            var bits: UInt8
            var base: Int
        }

        let entries: [Entry]
        let accuracy: Int

        /// Une table à un seul symbole, pour le mode « répété » (RLE).
        init(single symbol: UInt8) {
            entries = [Entry(symbol: symbol, bits: 0, base: 0)]
            accuracy = 0
        }

        /// La table d'une distribution normalisée : `-1` veut dire « moins
        /// d'une case », rangé à la fin.
        init(counts: [Int], accuracy: Int) throws {
            let size = 1 << accuracy
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size - 1
            for (symbol, count) in counts.enumerated() {
                if count == -1 {
                    guard high >= 0 else { throw Failure.corrupt("distribution FSE trop pleine") }
                    symbols[high] = UInt8(symbol)
                    high -= 1
                    next[symbol] = 1
                } else {
                    next[symbol] = count
                }
            }
            // L'étalement : un pas fixe, en sautant les cases du haut.
            let step = (size >> 1) + (size >> 3) + 3
            var position = 0
            for (symbol, count) in counts.enumerated() where count > 0 {
                for _ in 0..<count {
                    symbols[position] = UInt8(symbol)
                    repeat { position = (position + step) & (size - 1) } while position > high
                }
            }
            guard position == 0 else { throw Failure.corrupt("distribution FSE incohérente") }
            var entries = [Entry]()
            entries.reserveCapacity(size)
            for slot in 0..<size {
                let symbol = Int(symbols[slot])
                let state = next[symbol]
                next[symbol] += 1
                let bits = accuracy - (Int.bitWidth - 1 - state.leadingZeroBitCount)
                entries.append(Entry(symbol: UInt8(symbol), bits: UInt8(bits), base: (state << bits) - size))
            }
            self.entries = entries
            self.accuracy = accuracy
        }

        func next(_ state: Int, _ bits: inout BackwardReader) -> Int {
            let entry = entries[state]
            return entry.base + bits.read(Int(entry.bits))
        }

        /// La description d'une distribution, lue en avant, bit à bit depuis
        /// le bas de chaque octet (RFC 8878, 4.1.1).
        static func readCounts(_ reader: inout ForwardReader, maximumSymbol: Int,
                               maximumAccuracy: Int) throws -> (counts: [Int], accuracy: Int) {
            let start = reader.position
            var bitPosition = 0
            let data = reader.data
            func bits(_ count: Int) -> Int {
                var value = 0
                for index in 0..<count {
                    let absolute = start * 8 + bitPosition + index
                    let byte = absolute / 8 < data.count ? Int(data[absolute / 8]) : 0
                    value |= ((byte >> (absolute % 8)) & 1) << index
                }
                return value
            }
            let accuracy = bits(4) + 5
            bitPosition += 4
            guard accuracy <= maximumAccuracy else { throw Failure.corrupt("précision FSE trop grande") }
            var remaining = (1 << accuracy) + 1
            var threshold = 1 << accuracy
            var width = accuracy + 1
            var counts = [Int]()
            while remaining > 1 {
                guard counts.count <= maximumSymbol else { throw Failure.corrupt("trop de symboles FSE") }
                let maximum = (2 * threshold - 1) - remaining
                var value: Int
                if bits(width - 1) < maximum {
                    value = bits(width - 1)
                    bitPosition += width - 1
                } else {
                    value = bits(width)
                    if value >= threshold { value -= maximum }
                    bitPosition += width
                }
                let count = value - 1
                remaining -= abs(count)
                counts.append(count)
                if count == 0 {
                    // Des zéros répétés : deux bits à la fois, 3 voulant dire
                    // « trois de plus, et encore ».
                    while true {
                        let repeatCount = bits(2)
                        bitPosition += 2
                        counts += [Int](repeating: 0, count: repeatCount)
                        if repeatCount != 3 { break }
                    }
                }
                while remaining < threshold && threshold > 1 {
                    width -= 1
                    threshold >>= 1
                }
            }
            guard remaining == 1, counts.count <= maximumSymbol + 1 else {
                throw Failure.corrupt("distribution FSE incomplète")
            }
            let consumed = (bitPosition + 7) / 8
            try reader.skip(consumed)
            return (counts, accuracy)
        }
    }
}
