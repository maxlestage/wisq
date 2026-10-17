import Foundation

/// Un décodeur deflate brut (RFC 1951), en Swift, sans dépendance.
///
/// **Pourquoi pas zlib.** Le cœur de la machine locale ne dépend que de
/// Foundation, et ce n'est pas une coquetterie : le projet Xcode construit
/// `WisqVM` aussi en framework dynamique, et cette variante ne sait pas
/// résoudre une cible de bibliothèque système — la CI l'a dit en toutes
/// lettres, « missing target with GUID 'PACKAGE-TARGET:CZlib' », même sous
/// une condition de plateforme. Le framework Compression d'Apple aurait fait
/// l'affaire sur iPhone, mais pas sous Linux, où tournent les tests : deux
/// décodeurs, dont un jamais exercé ici. Un seul, écrit ici, tourne partout.
///
/// **Ce qu'il fait.** Les trois sortes de blocs — stockés, Huffman fixe,
/// Huffman dynamique —, la fenêtre de 32 Kio, et rien d'autre : pas d'en-tête
/// zlib ni gzip, puisque le qcow2 n'en met pas. La construction des codes suit
/// `puff.c` de Mark Adler, qui est la lecture de référence de la norme.
///
/// **Ce qu'il refuse.** Un flux qui produirait plus que `limit` octets s'arrête
/// à `limit` — c'est ce que veut un cluster de qcow2, et c'est ce qui borne une
/// bombe de décompression. Un flux mal formé rend `nil`, jamais des octets
/// devinés.
enum Inflate {
    /// Décompresse `input` jusqu'à la fin du flux ou jusqu'à `limit` octets.
    /// Rend `nil` si le flux est mal formé ou se termine avant d'avoir produit
    /// `limit` octets alors que `exact` est demandé.
    static func raw(_ input: [UInt8], limit: Int, exact: Bool) -> [UInt8]? {
        var state = State(input: input, limit: limit)
        let finished = state.run()
        if exact { return state.output.count == limit ? state.output : nil }
        return finished ? state.output : nil
    }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        /// Construit un code canonique à partir des longueurs ; `nil` si les
        /// longueurs sur-souscrivent l'arbre.
        init?(lengths: [Int]) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths { counts[length] += 1 }
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= counts[length]
                if left < 0 { return nil }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    private struct State {
        let input: [UInt8]
        let limit: Int
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []
        var full: Bool { output.count >= limit }

        init(input: [UInt8], limit: Int) {
            self.input = input
            self.limit = limit
            output.reserveCapacity(limit)
        }

        mutating func bits(_ need: Int) -> Int? {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.count else { return nil }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> need
            bitCount -= need
            return value & ((1 << need) - 1)
        }

        /// Un symbole, bit par bit, comme `puff` : lent sur le papier, assez
        /// rapide pour un cluster de 64 Kio, et sans table à valider.
        mutating func decode(_ code: Huffman) -> Int? {
            var value = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                guard let bit = bits(1) else { return nil }
                value |= bit
                let count = code.counts[length]
                if value - count < first { return code.symbols[index + (value - first)] }
                index += count
                first += count
                first <<= 1
                value <<= 1
            }
            return nil
        }

        /// Rend vrai à la fin du dernier bloc, faux sur un flux mal formé —
        /// ou plein : la sortie atteinte suffit à l'appelant.
        mutating func run() -> Bool {
            while !full {
                guard let last = bits(1), let type = bits(2) else { return false }
                let ok: Bool
                switch type {
                case 0: ok = stored()
                case 1: ok = codes(Self.fixed.0, Self.fixed.1)
                case 2: ok = dynamic()
                default: return false
                }
                if !ok { return false }
                if last == 1 { return true }
            }
            return true
        }

        mutating func stored() -> Bool {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { return false }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            position += 4
            guard length == (~complement & 0xFFFF), position + length <= input.count else {
                return false
            }
            let take = min(length, limit - output.count)
            output.append(contentsOf: input[position..<(position + take)])
            position += length
            return true
        }

        static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                   257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                   8193, 12289, 16385, 24577]
        static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

        static let fixed: (Huffman, Huffman) = {
            var lengths = [Int](repeating: 8, count: 288)
            for symbol in 144..<256 { lengths[symbol] = 9 }
            for symbol in 256..<280 { lengths[symbol] = 7 }
            return (Huffman(lengths: lengths)!, Huffman(lengths: [Int](repeating: 5, count: 30))!)
        }()

        mutating func codes(_ literals: Huffman, _ distances: Huffman) -> Bool {
            while !full {
                guard let symbol = decode(literals) else { return false }
                if symbol < 256 {
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return true
                } else {
                    let index = symbol - 257
                    guard index < 29, let extra = bits(Self.lengthExtra[index]) else { return false }
                    let length = Self.lengthBase[index] + extra
                    guard let code = decode(distances), code < 30,
                          let more = bits(Self.distanceExtra[code])
                    else { return false }
                    let distance = Self.distanceBase[code] + more
                    guard distance <= output.count else { return false }
                    let start = output.count - distance
                    let take = min(length, limit - output.count)
                    // Octet par octet : une copie peut chevaucher ce qu'elle
                    // écrit (distance plus courte que la longueur), et c'est
                    // ainsi que deflate répète un motif.
                    for offset in 0..<take { output.append(output[start + offset]) }
                }
            }
            return true
        }

        mutating func dynamic() -> Bool {
            guard let nlen = bits(5).map({ $0 + 257 }), let ndist = bits(5).map({ $0 + 1 }),
                  let ncode = bits(4).map({ $0 + 4 }), nlen <= 286, ndist <= 30
            else { return false }
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var lengthLengths = [Int](repeating: 0, count: 19)
            for index in 0..<ncode {
                guard let length = bits(3) else { return false }
                lengthLengths[order[index]] = length
            }
            guard let lengthCode = Huffman(lengths: lengthLengths) else { return false }
            var lengths: [Int] = []
            lengths.reserveCapacity(nlen + ndist)
            while lengths.count < nlen + ndist {
                guard let symbol = decode(lengthCode) else { return false }
                if symbol < 16 {
                    lengths.append(symbol)
                    continue
                }
                var repeated = 0
                var times = 0
                switch symbol {
                case 16:
                    guard let previous = lengths.last, let extra = bits(2) else { return false }
                    repeated = previous
                    times = 3 + extra
                case 17:
                    guard let extra = bits(3) else { return false }
                    times = 3 + extra
                default:
                    guard let extra = bits(7) else { return false }
                    times = 11 + extra
                }
                guard lengths.count + times <= nlen + ndist else { return false }
                lengths.append(contentsOf: repeatElement(repeated, count: times))
            }
            guard lengths[256] != 0,
                  let literals = Huffman(lengths: Array(lengths[0..<nlen])),
                  let distances = Huffman(lengths: Array(lengths[nlen...]))
            else { return false }
            return codes(literals, distances)
        }
    }
}
