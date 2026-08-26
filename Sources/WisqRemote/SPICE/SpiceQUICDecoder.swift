import Foundation
import WisqCore

/// The QUIC decode loop: symbols in, pixels out.
///
/// The fourth and last slice of the codec, and the only one that cannot be
/// checked in pieces. The header, the family tables, the bit reader and the
/// model each had an exact comparison available; this has none. It is verified
/// the only way it can be — whole images, against what SPICE's own decoder
/// produced from the same streams.
///
/// What the loop actually does, per channel, per pixel: decode one Golomb
/// codeword whose *code number* comes from the model bucket the **previous**
/// pixel's symbol selected, undo the zig-zag, and add a prediction. The
/// prediction is what changes between the three cases — nothing on the very
/// first pixel, the pixel to the left on the first row, and the average of
/// left and above everywhere else.
///
/// Two things run alongside it. The model updates on a schedule drawn from a
/// fixed table, so both ends update at the same moments without saying so. And
/// on rows after the first, a run of identical pixels can be sent as a
/// MELCODE run length instead of as symbols.
extension SpiceQUIC {
    /// `MELCSTATES`' `J` table: how long a run's remainder field is at each
    /// state of the run coder.
    static let runLengths: [Int] = [
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15
    ]

    /// `DEFwmistart`, `DEFwmimax`, `DEFwminext`.
    static let firstWaitMaskIndex = 0
    static let lastWaitMaskIndex = 6
    static let symbolsPerWaitMask = 2048

    /// State shared by a channel's decoding, carried across rows.
    struct CommonState {
        var waitCount = 0
        var chaosSeed = SpiceQUIC.chaosSeed
        var waitMaskIndex = SpiceQUIC.firstWaitMaskIndex
        var waitMaskLeft = SpiceQUIC.symbolsPerWaitMask
        var trigger: UInt32 = SpiceQUIC.trigger(waitMaskIndex: SpiceQUIC.firstWaitMaskIndex)

        // The run coder's state, `encoder_init_rle`.
        var runState = 0
        var runLength = SpiceQUIC.runLengths[0]
        var runOrder = 1 << SpiceQUIC.runLengths[0]
    }

    /// One colour channel: its model and the row of symbols it just decoded.
    struct Channel {
        var model: Model
        /// Symbols for the current row, **offset by one**.
        ///
        /// Index 0 is the byte the reference calls `correlate_row[-1]`: the
        /// context that picks pixel 0's bucket. It is written before every row,
        /// in `uncompress_gray` and its siblings — zero for row 0, and for
        /// every row after it the *previous* row's first symbol, which is what
        /// `correlate_row[0]` still holds at that moment.
        ///
        /// Index *n + 1* is the symbol decoded for pixel *n*, so pixel *n*
        /// reads its own context at index *n* without a special case.
        var symbols: [UInt8]

        init(bitsPerChannel: Int, width: Int) {
            model = Model(bitsPerChannel: bitsPerChannel)
            symbols = [UInt8](repeating: 0, count: width + 1)
        }
    }

    /// How many channels a type has, and at what depth.
    static func shape(of type: ImageType) -> (channels: Int, bitsPerChannel: Int)? {
        switch type {
        case .gray: return (1, 8)
        case .rgb16: return (3, 5)
        case .rgb24, .rgb32: return (3, 8)
        case .rgba: return (4, 8)
        case .invalid: return nil
        }
    }

    /// Decodes a whole image to BGRA, top row first.
    ///
    /// Always four bytes out, whatever the stream's depth: a five-bit channel
    /// is widened by repeating its high bits, exactly as the reference's
    /// `rgb16_to_32` does and as an uncompressed 0555 bitmap is widened
    /// elsewhere in this client. Shifting alone would leave white at 248.
    static func decode(_ payload: [UInt8]) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let header = try header(payload)
        guard let shape = shape(of: header.type) else {
            throw Failure.unknownImageType(header.type.rawValue)
        }
        // A size the stream itself declares, so it is bounded before anything
        // is allocated from it — but each side on its own is not a bound on
        // what gets allocated. Measured with the old per-side-only guard: a
        // 32768 × 32768 header, twenty bytes on the wire, took this process's
        // peak resident set from 36 MiB to 4.03 GiB. Both sides were legal and
        // the product was four gigabytes.
        //
        // `Framebuffer.canHold` is the number the rest of the client uses, and
        // it checks the product as well as the sides.
        guard Framebuffer.canHold(width: header.width, height: header.height) else {
            throw Failure.badGeometry(width: header.width, height: header.height)
        }

        var reader = try BitReader(payload)
        // The five header words, consumed through the same reader the loop
        // uses: it continues mid-stream from exactly here.
        for _ in 0..<5 { try reader.eat32() }

        var decoder = Decoder(
            header: header, shape: shape, reader: reader
        )
        try decoder.run()
        return (decoder.pixels, header.width, header.height)
    }

    /// A group of channels decoded together over a row, with one run coder.
    ///
    /// The reference splits its state two ways and it matters. Red, green and
    /// blue share `encoder->rgb_state`: one wait count, one chaos seed, one run
    /// coder for the three of them, and a run only starts where all three
    /// repeat. The one-byte and four-byte paths instead use `channel_a->state`,
    /// the channel's *own*.
    ///
    /// So `rgba` is not four channels in one pass. It is a colour pass over
    /// red, green and blue, then a wholly separate pass over alpha with its own
    /// run coder and its own wait counts, `uncompress_rgba` calling the two in
    /// turn for every row. Fusing them decodes the colour correctly and then
    /// desynchronises on alpha, because the second pass would inherit the
    /// first's wait count.
    struct Plane {
        /// Which channel each member is, and the byte it occupies in BGRA.
        let members: [(channel: Int, byte: Int)]
        /// Gray: one channel written to all three colour bytes.
        let replicated: Bool
        var state = CommonState()
    }

    /// The planes a given image type decodes as, in the order the reference
    /// runs them.
    ///
    /// **The stream's colour order is red, green, blue** — that is the order
    /// `APPLY_ALL_COMP` expands its per-channel macro in, so that is the order
    /// the symbols arrive in. `rgb32_pixel_t` is `b, g, r, pad`, so channel *n*
    /// lands on byte `2 - n`. The two are reversed, and pairing them straight
    /// through does not merely swap the colours: each channel carries its own
    /// model and its own row of symbols, so the wrong pairing desynchronises
    /// the decode within a few pixels and the stream runs out early.
    static func planes(of type: ImageType) -> [Plane] {
        let colour = Plane(
            members: (0..<3).map { (channel: $0, byte: 2 - $0) }, replicated: false
        )
        switch type {
        case .gray: return [Plane(members: [(channel: 0, byte: 0)], replicated: true)]
        case .rgb16, .rgb24, .rgb32: return [colour]
        case .rgba: return [colour, Plane(members: [(channel: 3, byte: 3)], replicated: false)]
        case .invalid: return []
        }
    }

    /// The loop's working state, kept together so the row functions can be
    /// small enough to read.
    private struct Decoder {
        let header: Header
        let bitsPerChannel: Int
        let mask: UInt32
        let family: Family
        /// True when the stream carries alpha of its own, so the opaque fill
        /// at the end would overwrite it.
        let hasAlpha: Bool
        var reader: BitReader
        var channels: [Channel]
        var planes: [Plane]
        /// BGRA, and the only buffer: each row predicts from the one above it
        /// in place rather than from a copy.
        var pixels: [UInt8]

        init(header: Header, shape: (channels: Int, bitsPerChannel: Int), reader: BitReader) {
            self.header = header
            self.bitsPerChannel = shape.bitsPerChannel
            self.mask = SpiceQUIC.bitMask(shape.bitsPerChannel)
            self.family = SpiceQUIC.family(bitsPerChannel: shape.bitsPerChannel)
            self.hasAlpha = header.type == .rgba
            self.reader = reader
            self.channels = (0..<shape.channels).map { _ in
                Channel(bitsPerChannel: shape.bitsPerChannel, width: header.width)
            }
            self.planes = SpiceQUIC.planes(of: header.type)
            self.pixels = [UInt8](repeating: 0, count: header.width * header.height * 4)
        }

        mutating func run() throws {
            for row in 0..<header.height {
                for plane in planes.indices {
                    // `correlate_row[-1]`: zero for the first row, and
                    // afterwards the first symbol of the row above, carried
                    // over before this row overwrites it.
                    if row > 0 {
                        for member in planes[plane].members {
                            channels[member.channel].symbols[0] =
                                channels[member.channel].symbols[1]
                        }
                    }
                    try decodeRow(row, plane: plane)
                }
            }
            guard !hasAlpha else { return }
            // Opaque: the other types carry no alpha, and a fourth byte left at
            // zero is a picture that does not appear.
            for pixel in 0..<(header.width * header.height) {
                pixels[pixel * 4 + 3] = 0xFF
            }
        }

        /// One row of one plane, split into the segments the wait mask asks for.
        private mutating func decodeRow(_ row: Int, plane: Int) throws {
            var start = 0
            var remaining = header.width

            while planes[plane].state.waitMaskIndex < SpiceQUIC.lastWaitMaskIndex,
                  planes[plane].state.waitMaskLeft <= remaining {
                let left = planes[plane].state.waitMaskLeft
                if left > 0 {
                    try decodeSegment(row: row, plane: plane, from: start, to: start + left)
                    start += left
                    remaining -= left
                }
                planes[plane].state.waitMaskIndex += 1
                planes[plane].state.trigger = SpiceQUIC.trigger(
                    waitMaskIndex: planes[plane].state.waitMaskIndex
                )
                planes[plane].state.waitMaskLeft = SpiceQUIC.symbolsPerWaitMask
            }

            guard remaining > 0 else { return }
            try decodeSegment(row: row, plane: plane, from: start, to: start + remaining)
            if planes[plane].state.waitMaskIndex < SpiceQUIC.lastWaitMaskIndex {
                planes[plane].state.waitMaskLeft -= remaining
            }
        }

        /// One stretch of a row under a single wait mask.
        ///
        /// The model updates at points the chaos table picks, not at every
        /// pixel: `waitCount` is how many more pixels to decode before the next
        /// update, and it survives across segments and rows.
        private mutating func decodeSegment(
            row: Int, plane: Int, from: Int, to end: Int
        ) throws {
            let waitMask = SpiceQUIC.bitMask(planes[plane].state.waitMaskIndex)
            var index = from
            var stopIndex: Int

            if index == 0 {
                try decodePixel(row: row, plane: plane, at: 0)
                if planes[plane].state.waitCount > 0 {
                    planes[plane].state.waitCount -= 1
                } else {
                    planes[plane].state.waitCount =
                        Int(SpiceQUIC.chaos(&planes[plane].state.chaosSeed) & waitMask)
                    updateModel(plane: plane, at: 0)
                }
                index += 1
            }
            stopIndex = index + planes[plane].state.waitCount

            while true {
                while stopIndex < end {
                    while index <= stopIndex {
                        if row > 0, startsRun(row: row, plane: plane, at: index) { break }
                        try decodePixel(row: row, plane: plane, at: index)
                        index += 1
                    }
                    if index <= stopIndex { break }   // a run interrupted the stretch
                    updateModel(plane: plane, at: stopIndex)
                    stopIndex = index
                        + Int(SpiceQUIC.chaos(&planes[plane].state.chaosSeed) & waitMask)
                }
                var interrupted = false
                while index < end {
                    if row > 0, startsRun(row: row, plane: plane, at: index) {
                        interrupted = true
                        break
                    }
                    try decodePixel(row: row, plane: plane, at: index)
                    index += 1
                }
                if !interrupted && index >= end {
                    planes[plane].state.waitCount = stopIndex - end
                    return
                }

                // A run: the pixels to come are copies of the one before them,
                // and their count is coded rather than their contents.
                planes[plane].state.waitCount = stopIndex - index
                let length = try decodeRunLength(plane: plane)
                guard length >= 0, length <= end - index else {
                    throw Failure.truncated
                }
                let runEnd = index + length
                while index < runEnd {
                    copyPixel(row: row, plane: plane, to: index, from: index - 1)
                    index += 1
                }
                if index == end { return }
                stopIndex = index + planes[plane].state.waitCount
            }
        }

        /// `RLE_PRED_IMP`: the encoder switched to a run exactly when the row
        /// above repeats and the two pixels just decoded repeat too. Both ends
        /// can see that without it being transmitted.
        private func startsRun(row: Int, plane: Int, at index: Int) -> Bool {
            guard index > 2 else { return false }
            return samePixel(plane, row - 1, index - 1, row - 1, index)
                && samePixel(plane, row, index - 1, row, index - 2)
        }

        /// `SAME_PIXEL`, over this plane's bytes only: the colour pass compares
        /// red, green and blue, the alpha pass compares alpha.
        private func samePixel(
            _ plane: Int, _ rowA: Int, _ a: Int, _ rowB: Int, _ b: Int
        ) -> Bool {
            let offsetA = (rowA * header.width + a) * 4
            let offsetB = (rowB * header.width + b) * 4
            for member in planes[plane].members
            where pixels[offsetA + member.byte] != pixels[offsetB + member.byte] {
                return false
            }
            return true
        }

        private mutating func copyPixel(row: Int, plane: Int, to: Int, from: Int) {
            let destination = (row * header.width + to) * 4
            let source = (row * header.width + from) * 4
            for member in planes[plane].members {
                pixels[destination + member.byte] = pixels[source + member.byte]
                if planes[plane].replicated {
                    pixels[destination + 1] = pixels[source + member.byte]
                    pixels[destination + 2] = pixels[source + member.byte]
                }
            }
        }

        /// One pixel, every channel, with the prediction its position calls for.
        private mutating func decodePixel(row: Int, plane: Int, at index: Int) throws {
            let base = (row * header.width + index) * 4
            for member in planes[plane].members {
                let channel = member.channel
                let contexts = channels[channel].model.bucketOfValue.count
                let bucket = channels[channel].model.bucketOfValue[
                    Int(channels[channel].symbols[index]) & (contexts - 1)
                ]
                let level = channels[channel].model.buckets[bucket].bestCode
                let (symbol, length) = SpiceQUIC.golombDecode(
                    level: level, bits: reader.window, family: family
                )
                channels[channel].symbols[index + 1] = UInt8(truncatingIfNeeded: symbol)

                let error = family.symbolToError[Int(symbol) & Int(mask)]
                let value: UInt32
                if row == 0 {
                    value = index == 0
                        ? error
                        : (error + channelValue(row: row, index - 1, member.byte)) & mask
                } else if index == 0 {
                    value = (error + channelValue(row: row - 1, 0, member.byte)) & mask
                } else {
                    let left = channelValue(row: row, index - 1, member.byte)
                    let above = channelValue(row: row - 1, index, member.byte)
                    value = (error + ((left + above) >> 1)) & mask
                }
                setChannel(value, at: base, plane: plane, byte: member.byte)
                try reader.eat(length)
            }
        }

        /// The stored value of one channel, back at the depth it was coded.
        private func channelValue(row: Int, _ index: Int, _ byte: Int) -> UInt32 {
            let stored = pixels[(row * header.width + index) * 4 + byte]
            return bitsPerChannel == 5 ? UInt32(stored) >> 3 : UInt32(stored)
        }

        /// Writes a channel, widening a five-bit one by repeating its high bits.
        private mutating func setChannel(
            _ value: UInt32, at base: Int, plane: Int, byte: Int
        ) {
            let stored: UInt8 = bitsPerChannel == 5
                ? UInt8(truncatingIfNeeded: value << 3 | (value & 0x1F) >> 2)
                : UInt8(truncatingIfNeeded: value)
            pixels[base + byte] = stored
            if planes[plane].replicated {
                pixels[base + 1] = stored
                pixels[base + 2] = stored
            }
        }

        private mutating func updateModel(plane: Int, at index: Int) {
            for member in planes[plane].members {
                channels[member.channel].model.update(
                    value: channels[member.channel].symbols[index + 1],
                    context: channels[member.channel].symbols[index],
                    family: family,
                    trigger: planes[plane].state.trigger
                )
            }
        }

        /// `decode_state_run`: a MELCODE run length.
        ///
        /// Counts leading *ones* a byte at a time — a full byte of them means
        /// the run is longer than this state can express, so it advances the
        /// state and keeps counting. The terminating zero is eaten with the
        /// partial byte, which is why the two exits consume different amounts.
        private mutating func decodeRunLength(plane: Int) throws -> Int {
            var length = 0
            while true {
                let leadingOnes = min((~(reader.window >> 24) & 0xFF).leadingZeroBitCount - 24, 8)
                for _ in 0..<leadingOnes {
                    length += planes[plane].state.runOrder
                    if planes[plane].state.runState < SpiceQUIC.runLengths.count - 1 {
                        planes[plane].state.runState += 1
                        planes[plane].state.runLength =
                            SpiceQUIC.runLengths[planes[plane].state.runState]
                        planes[plane].state.runOrder = 1 << planes[plane].state.runLength
                    }
                }
                if leadingOnes != 8 {
                    try reader.eat(leadingOnes + 1)
                    break
                }
                try reader.eat(8)
            }

            if planes[plane].state.runLength > 0 {
                length += Int(reader.window >> UInt32(32 - planes[plane].state.runLength))
                try reader.eat(planes[plane].state.runLength)
            }
            if planes[plane].state.runState > 0 {
                planes[plane].state.runState -= 1
                planes[plane].state.runLength =
                    SpiceQUIC.runLengths[planes[plane].state.runState]
                planes[plane].state.runOrder = 1 << planes[plane].state.runLength
            }
            return length
        }
    }
}
