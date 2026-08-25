import Foundation

/// SPICE's own image codec, the last one and much the largest.
///
/// QUIC is not a wrapper around anything standard. It is adaptive
/// Golomb-Rice coding with a per-channel model that reshapes itself as it
/// goes, a run-length sub-state borrowed from MELCODE, and prediction from the
/// pixels above and to the left. The reference is 2 250 lines of C across
/// `quic.c` and three template files instantiated once per pixel format.
///
/// So it arrives in pieces, and this is the first: the stream header, and the
/// **family tables** — the code-length and translation tables the coder reads
/// on every symbol. They are worth having alone because they are pure: given a
/// bit depth and a length limit they are fully determined, they never change
/// while a stream is decoded, and they can therefore be compared number for
/// number against the tables the reference builds. Nothing later can be
/// checked that cleanly, so getting them wrong here would be paid for
/// repeatedly.
enum SpiceQUIC {
    /// `QUIC` in the order the four bytes sit on the wire.
    static let magic: UInt32 = 0x4349_5551
    /// Major in the high half, minor in the low. Both are zero and have been
    /// since the codec shipped; a stream saying otherwise is refused rather
    /// than guessed at.
    static let version: UInt32 = 0

    /// `DEFmaxclen`. The longest a codeword may be, which is what makes the
    /// alternative non-Golomb encoding necessary at all.
    static let maximumCodeLength = 26

    enum ImageType: UInt32, Equatable, Sendable {
        case invalid = 0
        case gray = 1
        case rgb16 = 2
        case rgb24 = 3
        case rgb32 = 4
        case rgba = 5
    }

    enum Failure: Error, Equatable {
        case notQUIC(magic: UInt32)
        case unsupportedVersion(UInt32)
        case unknownImageType(UInt32)
        case badGeometry(width: Int, height: Int)
        case truncated
    }

    struct Header: Equatable, Sendable {
        var type: ImageType
        var width: Int
        var height: Int
    }

    /// The twenty bytes in front of every stream.
    ///
    /// Little-endian words, like the rest of the display channel — and unlike
    /// the LZ stream's header next door, which is big-endian. The two codecs
    /// disagree, and a reader that borrows the other's helper gets a magic
    /// that does not match and a size that does.
    static func header(_ payload: [UInt8]) throws -> Header {
        guard payload.count >= 20 else { throw Failure.truncated }
        func word(_ index: Int) -> UInt32 {
            var value: UInt32 = 0
            for byte in (0..<4).reversed() {
                value = value << 8 | UInt32(payload[index * 4 + byte])
            }
            return value
        }

        let found = word(0)
        guard found == magic else { throw Failure.notQUIC(magic: found) }
        let declaredVersion = word(1)
        guard declaredVersion == version else {
            throw Failure.unsupportedVersion(declaredVersion)
        }
        let rawType = word(2)
        guard let type = ImageType(rawValue: rawType), type != .invalid else {
            throw Failure.unknownImageType(rawType)
        }

        // Signed on the wire, and a negative one is not a small image: it is a
        // size that becomes enormous the moment it is multiplied.
        let width = Int(Int32(bitPattern: word(3)))
        let height = Int(Int32(bitPattern: word(4)))
        guard width > 0, height > 0 else {
            throw Failure.badGeometry(width: width, height: height)
        }
        return Header(type: type, width: width, height: height)
    }

    // MARK: - The bit reader

    /// Bits out of a QUIC stream.
    ///
    /// **The two orders run opposite ways, and that is the whole difficulty.**
    /// The stream is a sequence of 32-bit words stored *little-endian*, but the
    /// bits inside the window are consumed from the *top*. A reader that gets
    /// either half right and the other wrong produces plausible small numbers
    /// for a while and then diverges, which is the worst way for a codec to
    /// fail.
    ///
    /// The shape is the reference's, kept deliberately rather than tidied: a
    /// window, one word of lookahead, and a count of how many bits of that
    /// lookahead have not yet been shifted in. Rewriting it as an index into a
    /// bit array would be clearer and would not be the same function at the
    /// edges.
    struct BitReader {
        /// The window. The bits about to be read are its most significant ones.
        private(set) var window: UInt32 = 0
        /// The word after it, already fetched.
        private(set) var lookahead: UInt32 = 0
        /// How many bits of `lookahead` have not yet been shifted into the
        /// window.
        private(set) var availableBits: Int = 0

        private let words: [UInt32]
        private var next: Int

        /// Trailing bytes that do not fill a word are dropped, because the
        /// reference reads the buffer as `uint32 *` and counts `size / 4`. A
        /// stream is written in whole words, so this only ever discards
        /// padding — but it is the reference's behaviour rather than a choice.
        init(_ payload: [UInt8]) throws {
            guard payload.count >= 4 else { throw Failure.truncated }
            var words = [UInt32]()
            words.reserveCapacity(payload.count / 4)
            for start in stride(from: 0, to: payload.count - 3, by: 4) {
                var value: UInt32 = 0
                for byte in (0..<4).reversed() {
                    value = value << 8 | UInt32(payload[start + byte])
                }
                words.append(value)
            }
            self.words = words

            // Both registers start on the *first* word, not on the first and
            // the second. Priming the lookahead with word one instead loses
            // the whole stream by 32 bits, and the magic still reads correctly
            // — so the mistake survives the first check.
            window = words[0]
            lookahead = words[0]
            availableBits = 0
            next = 1
        }

        private mutating func fetch() throws {
            guard next < words.count else { throw Failure.truncated }
            lookahead = words[next]
            next += 1
        }

        /// Drops `count` bits from the top of the window and refills from the
        /// lookahead. `count` must be between 1 and 31: the reference asserts
        /// it, and a shift of 32 is undefined in C and merely wrong here.
        mutating func eat(_ count: Int) throws {
            precondition(count > 0 && count < 32, "QUIC consomme 1 à 31 bits à la fois")
            window <<= UInt32(count)

            let delta = availableBits - count
            if delta >= 0 {
                availableBits = delta
                window |= lookahead >> UInt32(availableBits)
                return
            }

            window |= lookahead << UInt32(-delta)
            try fetch()
            availableBits = 32 + delta
            window |= lookahead >> UInt32(availableBits)
        }

        /// Thirty-two bits, as two sixteens.
        ///
        /// Not one `eat(32)`: shifting a 32-bit word by 32 is undefined in C,
        /// so the reference was written never to ask, and the precondition
        /// above keeps that true here.
        ///
        /// *Which* split is used does not matter — checked against the
        /// reference rather than assumed: 16+16, 31+1 and a mixed sequence all
        /// leave the reader in the same state, because the bookkeeping only
        /// ever tracks a running total. Sixteen and sixteen because that is
        /// what `decode_eat32bits` does, not because anything depends on it.
        mutating func eat32() throws {
            try eat(16)
            try eat(16)
        }
    }

    // MARK: - The family tables

    /// `bppmask`: the low `n` bits set.
    ///
    /// A table in the reference, computed here — thirty-three constants
    /// transcribed by hand is thirty-three chances to mistype one, and the
    /// rule is one line.
    static func bitMask(_ bits: Int) -> UInt32 {
        guard bits > 0 else { return 0 }
        guard bits < 32 else { return .max }
        return (1 << UInt32(bits)) - 1
    }

    /// `ceil(log2(value))`, by the reference's own definition — which is not
    /// the mathematical one at 1: it answers 0 there rather than raising.
    static func ceilingLog2(_ value: Int) -> Int {
        guard value > 1 else { return 0 }
        var remaining = value - 1
        var result = 1
        while remaining >> 1 != 0 {
            remaining >>= 1
            result += 1
        }
        return result
    }

    /// Everything the coder looks up per symbol, for one bit depth.
    ///
    /// Two of these exist: eight bits per channel for the ordinary formats and
    /// five for `rgb16`, which really is 5-5-5. They are built once and never
    /// change, so they are a `struct` of tables rather than state.
    struct Family: Equatable, Sendable {
        /// How many codewords at this code number stay plain Golomb-Rice.
        /// Beyond it the coder switches to a fixed-length escape, which is what
        /// keeps a single symbol from costing hundreds of bits.
        var golombCodewords: [UInt32]
        var escapeLength: [UInt32]
        var escapePrefixMask: [UInt32]
        var escapeSuffixLength: [UInt32]

        /// Code and length per (symbol, code number). Indexed symbol-major, as
        /// the reference indexes them.
        var codeLength: [[UInt32]]
        var code: [[UInt32]]

        /// The two halves of the zig-zag that turns a signed prediction error
        /// into an unsigned symbol and back: 0, -1, 1, -2, 2 … becomes
        /// 0, 1, 2, 3, 4 …
        var errorToSymbol: [UInt8]
        var symbolToError: [UInt32]
    }

    /// Builds a family, exactly as `family_init` does.
    static func family(bitsPerChannel bpc: Int, limit: Int = maximumCodeLength) -> Family {
        let pixelMask = bitMask(bpc)
        var golombCodewords = [UInt32](repeating: 0, count: bpc)
        var escapeLength = [UInt32](repeating: 0, count: bpc)
        var escapePrefixMask = [UInt32](repeating: 0, count: bpc)
        var escapeSuffixLength = [UInt32](repeating: 0, count: bpc)

        for level in 0..<bpc {
            // How long the escape's prefix may be: what the length limit
            // leaves, but never more than the symbols at this level can index.
            var prefixLength = limit - bpc
            let ceiling = Int(bitMask(bpc - level))
            if prefixLength > ceiling { prefixLength = ceiling }

            let escapeCount = Int(pixelMask) + 1 - (prefixLength << level)
            golombCodewords[level] = UInt32(prefixLength << level)
            escapeSuffixLength[level] = UInt32(ceilingLog2(escapeCount))
            escapeLength[level] = UInt32(prefixLength) + escapeSuffixLength[level]
            escapePrefixMask[level] = bitMask(32 - prefixLength)
        }

        var code = [[UInt32]](repeating: [UInt32](repeating: 0, count: bpc), count: 256)
        var codeLength = code
        for symbol in 0..<256 {
            for level in 0..<bpc {
                let (word, length) = golomb(
                    UInt8(symbol), level: level,
                    golombCodewords: golombCodewords, escapeLength: escapeLength
                )
                code[symbol][level] = word
                codeLength[symbol][level] = length
            }
        }

        return Family(
            golombCodewords: golombCodewords,
            escapeLength: escapeLength,
            escapePrefixMask: escapePrefixMask,
            escapeSuffixLength: escapeSuffixLength,
            codeLength: codeLength,
            code: code,
            errorToSymbol: errorToSymbol(pixelMask: pixelMask),
            symbolToError: symbolToError(pixelMask: pixelMask)
        )
    }

    /// One symbol's codeword, plain or escaped.
    private static func golomb(
        _ symbol: UInt8, level: Int,
        golombCodewords: [UInt32], escapeLength: [UInt32]
    ) -> (code: UInt32, length: UInt32) {
        let value = UInt32(symbol)
        guard value < golombCodewords[level] else {
            return (value - golombCodewords[level], escapeLength[level])
        }
        return (
            1 << UInt32(level) | (value & bitMask(level)),
            (value >> UInt32(level)) + UInt32(level) + 1
        )
    }

    /// `decorrelate_init`: a signed error folded into an unsigned symbol.
    ///
    /// Small errors get small symbols whichever way they lean, which is the
    /// whole reason the coder can spend one bit on a flat region.
    static func errorToSymbol(pixelMask: UInt32) -> [UInt8] {
        let half = pixelMask >> 1
        return (0...pixelMask).map { value in
            value <= half
                ? UInt8(truncatingIfNeeded: value << 1)
                : UInt8(truncatingIfNeeded: ((pixelMask - value) << 1) + 1)
        }
    }

    /// `correlate_init`: the same fold, undone.
    static func symbolToError(pixelMask: UInt32) -> [UInt32] {
        (0...pixelMask).map { value in
            value & 1 == 1 ? pixelMask - (value >> 1) : value >> 1
        }
    }
}
