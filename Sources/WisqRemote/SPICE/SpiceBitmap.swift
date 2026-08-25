import Foundation

/// Uncompressed bitmaps, turned into pixels.
///
/// The plainest image SPICE sends, and the one that was missing: every codec
/// was decoded and the *uncompressed* form was parsed and then dropped, so a
/// server with image compression off drew nothing at all.
///
/// Two things here are easy to get wrong and quiet when they are:
///
///   * **Rows are bottom-up unless `TOP_DOWN` is set.** The first row in the
///     data is the last row on screen, the way a Windows DIB is stored.
///     Ignoring the flag does not fail — it renders the desktop upside down,
///     and only against the servers that send it that way.
///   * **`stride` is not the row's width in bytes.** It is the distance
///     between rows, padded, and reading straight through shears every row
///     after the first by the padding.
enum SpiceBitmap {
    enum Failure: Error, Equatable {
        case truncated
        /// A palettised format arrived without the colour table it needs —
        /// either none was sent, or it named one in a cache this client does
        /// not keep.
        case missingPalette
        case unsupportedFormat(SpiceDisplayWire.BitmapFormat)
    }

    /// How many bytes one row of pixels occupies, padding excluded.
    ///
    /// The packed formats round up: a five-pixel 4-bit row spends three bytes
    /// and wastes half of the third.
    static func rowBytes(_ format: SpiceDisplayWire.BitmapFormat, width: Int) -> Int? {
        switch format {
        case .oneBitLE, .oneBitBE: return (width + 7) / 8
        case .fourBitLE, .fourBitBE: return (width + 1) / 2
        case .eightBit, .eightBitAlpha: return width
        case .sixteenBit: return width * 2
        case .twentyFourBit: return width * 3
        case .thirtyTwoBit, .rgba: return width * 4
        }
    }

    /// Whether a format reads its colours from a palette rather than carrying
    /// them. `eightBitAlpha` does not: its byte is alpha, not an index.
    static func needsPalette(_ format: SpiceDisplayWire.BitmapFormat) -> Bool {
        switch format {
        case .oneBitLE, .oneBitBE, .fourBitLE, .fourBitBE, .eightBit: return true
        default: return false
        }
    }

    /// Converts one bitmap to BGRA, top row first.
    static func pixels(
        _ bitmap: SpiceDisplayWire.Bitmap, data: [UInt8]
    ) throws -> [UInt8] {
        let width = Int(bitmap.width)
        let height = Int(bitmap.height)
        guard width > 0, height > 0 else { return [] }

        guard let minimumRow = rowBytes(bitmap.format, width: width) else {
            throw Failure.unsupportedFormat(bitmap.format)
        }
        // The server's stride has to be at least what a row needs. Smaller and
        // rows would overlap, which is not a picture — it is a message that
        // disagrees with itself.
        let stride = Int(bitmap.stride)
        guard stride >= minimumRow, data.count >= stride * height else {
            throw Failure.truncated
        }
        if needsPalette(bitmap.format), bitmap.palette == nil {
            throw Failure.missingPalette
        }

        var out = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            // Bottom-up is the default, so the row read here is written to the
            // opposite end unless the flag says otherwise.
            let destination = bitmap.topDown ? row : height - 1 - row
            try convert(
                row: Array(data[(row * stride)..<(row * stride + minimumRow)]),
                layout: Layout(
                    format: bitmap.format, width: width, palette: bitmap.palette
                ),
                into: &out, at: destination * width * 4
            )
        }
        return out
    }

    // MARK: - One row

    /// What a row looks like: enough to read one, and no more.
    ///
    /// Grouped rather than passed loose because the three travel together
    /// everywhere and never vary within an image — and because six loose
    /// parameters is the point at which an argument gets passed in the wrong
    /// position without the compiler minding.
    private struct Layout {
        var format: SpiceDisplayWire.BitmapFormat
        var width: Int
        var palette: SpiceDisplayWire.Palette?
    }

    private static func convert(
        row: [UInt8], layout: Layout, into out: inout [UInt8], at start: Int
    ) throws {
        let width = layout.width
        switch layout.format {
        case .oneBitLE, .oneBitBE, .fourBitLE, .fourBitBE, .eightBit:
            guard let palette = layout.palette, !palette.colours.isEmpty else {
                throw Failure.missingPalette
            }
            try indexed(row, layout: layout, palette: palette, into: &out, at: start)

        case .sixteenBit:
            // 0555: five bits each, and the expansion has to repeat the high
            // bits rather than shift and leave zeros, or white comes out at
            // 248 and the whole picture is dull.
            for pixel in 0..<width {
                let value = UInt16(row[pixel * 2]) | UInt16(row[pixel * 2 + 1]) << 8
                let red = UInt8((value >> 10) & 0x1F)
                let green = UInt8((value >> 5) & 0x1F)
                let blue = UInt8(value & 0x1F)
                out[start + pixel * 4] = blue << 3 | blue >> 2
                out[start + pixel * 4 + 1] = green << 3 | green >> 2
                out[start + pixel * 4 + 2] = red << 3 | red >> 2
                out[start + pixel * 4 + 3] = 0xFF
            }

        case .twentyFourBit:
            // Already BGR, so the bytes copy straight across and only the
            // fourth is added.
            for pixel in 0..<width {
                out[start + pixel * 4] = row[pixel * 3]
                out[start + pixel * 4 + 1] = row[pixel * 3 + 1]
                out[start + pixel * 4 + 2] = row[pixel * 3 + 2]
                out[start + pixel * 4 + 3] = 0xFF
            }

        case .thirtyTwoBit:
            // xRGB little-endian: B, G, R, and a fourth byte that is *not*
            // alpha. Copying it through is how a fully opaque desktop arrives
            // completely transparent.
            for pixel in 0..<width {
                out[start + pixel * 4] = row[pixel * 4]
                out[start + pixel * 4 + 1] = row[pixel * 4 + 1]
                out[start + pixel * 4 + 2] = row[pixel * 4 + 2]
                out[start + pixel * 4 + 3] = 0xFF
            }

        case .rgba:
            for pixel in 0..<width {
                out[start + pixel * 4] = row[pixel * 4]
                out[start + pixel * 4 + 1] = row[pixel * 4 + 1]
                out[start + pixel * 4 + 2] = row[pixel * 4 + 2]
                out[start + pixel * 4 + 3] = row[pixel * 4 + 3]
            }

        case .eightBitAlpha:
            // A mask, not a colour: the byte is alpha over black.
            for pixel in 0..<width {
                out[start + pixel * 4 + 3] = row[pixel]
            }
        }
    }

    /// The packed and palettised formats.
    ///
    /// The two orders here are the ones that would have been written
    /// backwards, and they are the same rules the LZ codec's palette forms
    /// follow — checked there against the reference decoder's own output:
    ///
    ///   * a 4-bit `LE` byte gives the **low** nibble first, `BE` the **high**;
    ///   * a 1-bit `LE` byte starts at **bit 0**, `BE` at **bit 7**.
    ///
    /// Backwards, either one still produces an image — mirrored in pairs of
    /// pixels, or in groups of eight.
    private static func indexed(
        _ row: [UInt8], layout: Layout, palette: SpiceDisplayWire.Palette,
        into out: inout [UInt8], at start: Int
    ) throws {
        let format = layout.format
        let perByte: Int
        switch format {
        case .oneBitLE, .oneBitBE: perByte = 8
        case .fourBitLE, .fourBitBE: perByte = 2
        case .eightBit: perByte = 1
        default: throw Failure.unsupportedFormat(format)
        }

        var written = 0
        for byte in row {
            for slot in 0..<perByte where written < layout.width {
                let index: Int
                switch format {
                case .eightBit: index = Int(byte)
                case .fourBitLE: index = slot == 0 ? Int(byte & 0x0F) : Int(byte >> 4)
                case .fourBitBE: index = slot == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
                case .oneBitLE: index = Int(byte >> UInt8(slot) & 1)
                case .oneBitBE: index = Int(byte >> UInt8(7 - slot) & 1)
                default: throw Failure.unsupportedFormat(format)
                }
                // Modulo the table's size, which is what the codecs themselves
                // do: an index past the end is a broken image, not a reason to
                // drop the connection.
                let colour = palette.colours[index % palette.colours.count]
                out[start + written * 4] = UInt8(colour & 0xFF)
                out[start + written * 4 + 1] = UInt8(colour >> 8 & 0xFF)
                out[start + written * 4 + 2] = UInt8(colour >> 16 & 0xFF)
                out[start + written * 4 + 3] = 0xFF
                written += 1
            }
        }
    }
}
