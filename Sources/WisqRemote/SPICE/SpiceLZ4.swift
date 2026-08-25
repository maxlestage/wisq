import Foundation

/// LZ4 on the SPICE display channel, decoding side.
///
/// The last compressed form the display channel can send that wisq could not
/// read. It is also the odd one out among them: LZ, GLZ and QUIC are SPICE's
/// own inventions and exist nowhere else, while this is stock LZ4 with a
/// two-byte SPICE header in front and a length before each block.
///
/// That makes the interesting part of this file *not* the codec. It is the
/// three things the wrapper does that reading "it's just LZ4" would get wrong:
///
///   * **the block lengths are big-endian**, in a protocol that is
///     little-endian everywhere else. `lz4_encode` writes them with
///     `GUINT32_TO_BE` and `canvas_get_lz4` reads them with `READ_UINT32_BE`.
///     Read the other way round, the first block claims to be some hundreds of
///     megabytes long;
///   * **the blocks share one dictionary.** The server compresses with
///     `LZ4_compress_fast_continue` on a stream it creates once per image, so a
///     match in the fourth block routinely names bytes that were decoded in the
///     first. Decoding each block on its own is the mistake that looks like it
///     works: a flat image comes out right and a real one comes out as bands of
///     rubbish. Three of the six fixtures here fail that way if the dictionary
///     is reset between blocks, and that was checked by resetting it in the
///     reference decoder rather than reasoned about;
///   * **the header's second byte is a `bitmap_fmt`, not a channel count.** Its
///     four accepted values are the four RGB ones, and it decides the row
///     length that everything after depends on.
///
/// Rows arrive packed at `width × bytes-per-pixel` with no padding. The
/// reference spreads them into a pixman surface afterwards with
/// `canvas_fix_alignment`, which exists precisely because the encoder's rows
/// are tighter than pixman's; wisq keeps them packed and hands them to
/// `SpiceBitmap`, which reads a stride and needs no such repair.
enum SpiceLZ4 {
    enum Failure: Error, Equatable {
        /// The payload ran out inside a header, a length, or a block.
        case truncated
        /// A `bitmap_fmt` this codec does not carry. The reference warns and
        /// draws nothing for exactly the same set.
        case unsupportedFormat(UInt8)
        /// The descriptor's width and height do not describe an image.
        case badGeometry
        /// The LZ4 block itself is malformed.
        case badBlock
        /// The blocks decoded, but not to the number of bytes the image's own
        /// width, height and format call for.
        case wrongSize(expected: Int, got: Int)
    }

    /// The two bytes in front of the blocks.
    struct Header: Equatable, Sendable {
        var topDown: Bool
        var format: SpiceDisplayWire.BitmapFormat
    }

    /// The number of bytes one pixel of an LZ4-carried format occupies.
    ///
    /// Only four formats have an answer here, and the list is not this
    /// decoder's choice: it is the `switch` in `canvas_get_lz4`, and the server
    /// agrees with it from the other end — `get_compression_for_bitmap`
    /// downgrades LZ4 to plain LZ whenever `bitmap_fmt_is_rgb` is false, and
    /// that predicate is false for every palettised format and for the alpha
    /// mask. So the refusal below is not a gap: nothing produces the others.
    static func bytesPerPixel(_ format: SpiceDisplayWire.BitmapFormat) -> Int? {
        switch format {
        case .sixteenBit: return 2
        case .twentyFourBit: return 3
        case .thirtyTwoBit, .rgba: return 4
        default: return nil
        }
    }

    /// Decodes a whole LZ4 image payload into packed rows.
    ///
    /// The width and height are the *descriptor's*, from the message around the
    /// payload, because the LZ4 header carries neither. That is a difference
    /// worth naming: LZ and GLZ repeat their geometry inside the stream and
    /// this decoder checks the two agree, but here there is nothing to check
    /// against, and a wrong width silently reinterprets every row boundary.
    /// What catches it instead is the total: the blocks have to decode to
    /// exactly `width × height × bytes-per-pixel` bytes.
    static func decode(
        _ payload: [UInt8], width: Int, height: Int
    ) throws -> (header: Header, rows: [UInt8]) {
        guard payload.count >= 2 else { throw Failure.truncated }
        let topDown = payload[0] != 0
        guard let format = SpiceDisplayWire.BitmapFormat(rawValue: payload[1]),
              let bytesPerPixel = bytesPerPixel(format) else {
            throw Failure.unsupportedFormat(payload[1])
        }

        // Bounded before anything is allocated from it. The two come from the
        // image descriptor, which is the network's word, and the cap is the
        // same one the other codecs here use.
        guard width > 0, height > 0, width <= 1 << 15, height <= 1 << 15 else {
            throw Failure.badGeometry
        }
        let stride = width * bytesPerPixel
        let total = stride * height
        guard total <= 1 << 28 else { throw Failure.badGeometry }

        var rows = [UInt8](repeating: 0, count: total)
        var written = 0
        var offset = 2

        while offset < payload.count {
            guard offset + 4 <= payload.count else { throw Failure.truncated }
            // Big-endian, and the one place in this file where getting the
            // order wrong produces a plausible-looking failure rather than an
            // obvious one: a short first block reads as a huge one and the
            // error says "truncated" about a payload that is entirely present.
            let size =
                Int(payload[offset]) << 24 | Int(payload[offset + 1]) << 16
                | Int(payload[offset + 2]) << 8 | Int(payload[offset + 3])
            offset += 4
            guard size > 0, payload.count - offset >= size else { throw Failure.truncated }

            // `at: written` and not `at: 0` — every block decodes into the tail
            // of the same buffer, and matches are free to reach back into the
            // part earlier blocks wrote.
            let produced = try block(
                payload, from: offset, size: size, into: &rows, at: written
            )
            // The reference treats a block that produced nothing as an error
            // rather than as a no-op, and so does this: without it a payload
            // could pad itself with empty blocks after the pixels were already
            // complete and still be accepted.
            guard produced > 0 else { throw Failure.badBlock }
            written += produced
            offset += size
        }

        // The reference does not check this. It warns on a block that fails and
        // otherwise leaves whatever pixman's allocation happened to contain in
        // the rows the stream never reached — which is uninitialised memory
        // drawn to a screen. A payload that decodes to the wrong length is a
        // message that disagrees with its own descriptor, so it is refused.
        guard written == total else { throw Failure.wrongSize(expected: total, got: written) }
        return (Header(topDown: topDown, format: format), rows)
    }

    /// One LZ4 block, into `out` at `start`, with everything already in `out`
    /// available as the dictionary.
    ///
    /// This is `LZ4_decompress_safe_continue` in the contiguous-output case,
    /// which is the only case SPICE produces: the reference hands it successive
    /// slices of one surface, so lz4 takes its "rolling the current segment"
    /// branch and the match limit becomes the start of the whole buffer rather
    /// than the start of this block.
    ///
    /// The bounds are lz4's own rather than looser ones that would also be
    /// safe, because the format's end-of-block rules are what make a
    /// speed-oriented decoder correct and a decoder that accepts more than the
    /// spec allows accepts streams no encoder can produce. In order: a literal
    /// run that comes within 12 bytes of the output end, or within 8 bytes of
    /// the input end, must be the block's last sequence and must consume the
    /// input exactly; and a match may never finish inside the last 5 bytes of
    /// the output.
    static func block(
        _ input: [UInt8], from start: Int, size: Int,
        into out: inout [UInt8], at outStart: Int
    ) throws -> Int {
        let inputEnd = start + size
        let outEnd = out.count
        var read = start
        var write = outStart
        guard size > 0, outStart <= outEnd else { throw Failure.badBlock }

        while true {
            guard read < inputEnd else { throw Failure.badBlock }
            let token = Int(input[read])
            read += 1

            var literals = token >> 4
            if literals == 15 {
                literals += try extendedLength(input, at: &read, limit: inputEnd - 15)
            }

            let literalEnd = write + literals
            // Either restriction firing means this has to be the final
            // sequence; the reference checks both and so does this, because a
            // block can reach the input's end long before the output's.
            if literalEnd + 12 > outEnd || read + literals + 8 > inputEnd {
                guard read + literals == inputEnd, literalEnd <= outEnd else {
                    throw Failure.badBlock
                }
                out.replaceSubrange(write..<literalEnd, with: input[read..<(read + literals)])
                return literalEnd - outStart
            }
            out.replaceSubrange(write..<literalEnd, with: input[read..<(read + literals)])
            read += literals
            write = literalEnd

            // Two bytes, little-endian — the block format's own order, and the
            // opposite of the block *length* four lines up. There is no
            // inconsistency to fix: the length is SPICE's field and the offset
            // is lz4's.
            let distance = Int(input[read]) | Int(input[read + 1]) << 8
            read += 2
            var match = write - distance
            // A distance reaching before the buffer would read whatever
            // preceded it. lz4 spells that as `match + dictSize < lowPrefix`;
            // with one contiguous buffer the prefix starts at zero.
            //
            // **The zero is a deliberate divergence.** The block format says a
            // zero offset "denotes an invalid (corrupted) block", but lz4's own
            // decoder does not reject one — it has an `LZ4_write32(op, 0)` on
            // the short-offset path, commented as silencing a sanitiser
            // warning, and the effect is that a zero distance copies a pixel
            // from itself and fills the match with zeroes. So the reference
            // client draws a band of black where this refuses.
            //
            // Found by fuzzing against the reference rather than by reading it,
            // and kept: no encoder emits a zero offset, so a stream carrying
            // one has been damaged, and a black band from damaged data is worse
            // than no pixels at all.
            guard distance > 0, match >= 0 else { throw Failure.badBlock }

            var length = token & 0x0F
            if length == 15 {
                length += try extendedLength(input, at: &read, limit: inputEnd - 6)
            }
            length += 4

            let matchEnd = write + length
            // lz4's rule that the last five bytes of a block are literals, and
            // it turns out to be unreachable: the input-side restriction above
            // refuses every stream that could get here first. The arithmetic is
            // in `SpiceLZ4Tests`. Kept because it is the reference's bound and
            // because its unreachability is a property of the other checks
            // rather than of this one — loosen one of those and this is what
            // still holds the line.
            guard matchEnd + 5 <= outEnd else { throw Failure.badBlock }
            // One byte at a time, deliberately. A match may overlap its own
            // destination — a distance of 1 repeating a byte is the format's
            // ordinary way of writing a run — so a bulk copy of the source
            // range would take the bytes as they were before the copy started
            // rather than as it writes them.
            while write < matchEnd {
                out[write] = out[match]
                write += 1
                match += 1
            }
        }
    }

    /// The `255, 255, …, n` continuation used by both length fields.
    ///
    /// `limit` is the reference's, and it differs between the two callers: a
    /// literal length may not read into the last 15 bytes of the block, a match
    /// length not into the last 6. Both are what guarantee the reads after them
    /// are in bounds without a check of their own.
    private static func extendedLength(
        _ input: [UInt8], at read: inout Int, limit: Int
    ) throws -> Int {
        guard read < limit else { throw Failure.badBlock }
        var byte = Int(input[read])
        read += 1
        var total = byte
        while byte == 255 {
            guard read < limit else { throw Failure.badBlock }
            byte = Int(input[read])
            read += 1
            total += byte
        }
        return total
    }
}
