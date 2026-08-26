import Foundation

/// A run of glyphs flattened into one coverage mask.
///
/// The reference builds exactly this — a pixman `a1` or `a8` image spanning the
/// union of the glyph boxes — and then composites the foreground brush through
/// it. Building it separately from the surface is what lets a test look at
/// coverage values rather than at pixels that have already been blended.
enum SpiceGlyphMask {
    /// Coverage over a rectangle, one byte a pixel, 0…255.
    struct Coverage: Equatable, Sendable {
        var left: Int
        var top: Int
        var width: Int
        var height: Int
        var values: [UInt8]

        func at(_ x: Int, _ y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return values[y * width + x]
        }
    }

    /// The largest mask this will build, before anything is allocated from
    /// numbers that came off a socket. A glyph run is a line of text; anything
    /// this size is a message that has stopped making sense.
    static let maximumPixels = 1 << 24

    /// Flattens a string's glyphs into one mask.
    ///
    /// `nil` when the string has no glyphs, or names a depth this cannot read,
    /// or asks for more than `maximumPixels`.
    static func build(_ string: SpiceDisplayWire.TextString) -> Coverage? {
        guard let depth = string.depth, !string.glyphs.isEmpty else { return nil }

        var bounds = string.glyphs[0].box
        for glyph in string.glyphs.dropFirst() {
            let box = glyph.box
            bounds = SpiceDisplayWire.Rect(
                top: min(bounds.top, box.top), left: min(bounds.left, box.left),
                bottom: max(bounds.bottom, box.bottom), right: max(bounds.right, box.right)
            )
        }
        let width = Int(bounds.right) - Int(bounds.left)
        let height = Int(bounds.bottom) - Int(bounds.top)
        // Per side before the product, as in `SpiceSurfaces.create`. These are
        // differences of `Int32` rather than raw values, which changes nothing:
        // a glyph box spanning `Int32.min` to `Int32.max` gives a side of
        // 4.29 × 10^9, and two of those multiplied leave an `Int`.
        guard width > 0, height > 0,
              width <= maximumPixels, height <= maximumPixels,
              width * height <= maximumPixels else { return nil }

        var coverage = [UInt8](repeating: 0, count: width * height)
        for glyph in string.glyphs {
            draw(glyph, depth: depth, into: &coverage, width: width, bounds: bounds)
        }
        return Coverage(
            left: Int(bounds.left), top: Int(bounds.top),
            width: width, height: height, values: coverage
        )
    }

    /// One glyph into the mask.
    ///
    /// Three things here are the reference's and none of them is obvious.
    ///
    /// **Rows are read bottom-up.** `canvas_put_glyph_bits` starts at the end of
    /// the glyph's data and walks backwards, for every depth, and its
    /// `//todo: support SPICE_STRING_FLAGS_RASTER_TOP_DOWN` says the flag that
    /// would change this is not implemented. Reading top-down turns every
    /// letter upside down.
    ///
    /// **Glyphs combine with `max`, not by overwriting.** Accents and kerned
    /// pairs overlap, and the later glyph must not punch a hole in the earlier
    /// one where its own coverage is zero.
    ///
    /// **A4 shifts a nibble into the high half rather than scaling it.** The
    /// reference writes `*now & 0xf0` and `*now << 4`, so a full nibble becomes
    /// 240 and not 255 — A4 text is never quite opaque. Scaling to 255 would
    /// look better and would not be what the server drew.
    private static func draw(
        _ glyph: SpiceDisplayWire.RasterGlyph, depth: Int,
        into coverage: inout [UInt8], width maskWidth: Int, bounds: SpiceDisplayWire.Rect
    ) {
        let box = glyph.box
        let originX = Int(box.left) - Int(bounds.left)
        let originY = Int(box.top) - Int(bounds.top)
        let glyphWidth = Int(glyph.width)
        let glyphHeight = Int(glyph.height)
        let stride = SpiceDisplayWire.TextString.bytesPerRow(width: glyphWidth, depth: depth)

        for row in 0..<glyphHeight {
            // Bottom-up: the last row of data is the top row of the glyph.
            let sourceRow = glyphHeight - 1 - row
            let start = sourceRow * stride
            guard start + stride <= glyph.data.count else { continue }
            let destinationRow = originY + row
            guard destinationRow >= 0 else { continue }

            for column in 0..<glyphWidth {
                let value = sample(
                    glyph.data, rowStart: start, column: column, depth: depth
                )
                guard value > 0 else { continue }
                let x = originX + column
                guard x >= 0, x < maskWidth else { continue }
                let index = destinationRow * maskWidth + x
                guard index >= 0, index < coverage.count else { continue }
                coverage[index] = max(coverage[index], value)
            }
        }
    }

    /// One pixel of coverage out of a glyph row.
    ///
    /// **The high bits come first**, at every depth. For A1 that is the leftmost
    /// pixel in bit 7, which is why the reference runs its bytes through
    /// `revers_bits` on the way into pixman's `a1` — pixman puts the leftmost
    /// pixel in bit 0. Nothing here uses pixman's layout, so the reversal is not
    /// reproduced; what is reproduced is the reading it implies.
    private static func sample(
        _ data: [UInt8], rowStart: Int, column: Int, depth: Int
    ) -> UInt8 {
        switch depth {
        case 1:
            let index = rowStart + (column >> 3)
            guard index < data.count else { return 0 }
            return (data[index] >> (7 - UInt8(column & 7))) & 1 == 1 ? 0xFF : 0
        case 4:
            let index = rowStart + (column >> 1)
            guard index < data.count else { return 0 }
            // High nibble is the even column, and the value lands in the high
            // half of the byte rather than being scaled to fill it.
            return column & 1 == 0 ? data[index] & 0xF0 : data[index] << 4
        default:
            let index = rowStart + column
            guard index < data.count else { return 0 }
            return data[index]
        }
    }
}
