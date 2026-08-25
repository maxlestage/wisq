import Foundation

extension SpiceDisplayWire {
    /// One glyph's bitmap and where it goes.
    ///
    /// Two points, and **they are added together**, not alternatives:
    /// `canvas_raster_glyph_box` reads
    ///
    ///     r->top  = glyph->render_pos.y + glyph->glyph_origin.y;
    ///     r->left = glyph->render_pos.x + glyph->glyph_origin.x;
    ///
    /// `render_pos` is where the text cursor sits and `glyph_origin` is the
    /// glyph's own offset from it — negative for a letter that hangs below the
    /// baseline, or left of it for a kerned pair. Using either alone puts every
    /// accent and descender in the wrong place, and looks like a font problem
    /// rather than a decoding one.
    struct RasterGlyph: Equatable, Sendable {
        var renderPos: Point
        var glyphOrigin: Point
        var width: UInt16
        var height: UInt16
        /// Coverage, in the depth the string declared. Rows are **bottom-up**.
        var data: [UInt8]

        /// Where this glyph lands.
        var box: Rect {
            let left = Int(renderPos.x) + Int(glyphOrigin.x)
            let top = Int(renderPos.y) + Int(glyphOrigin.y)
            return Rect(
                top: Int32(clamping: top), left: Int32(clamping: left),
                bottom: Int32(clamping: top + Int(height)),
                right: Int32(clamping: left + Int(width))
            )
        }
    }

    /// A run of glyphs, all at one depth.
    struct TextString: Equatable, Sendable {
        /// `SPICE_STRING_FLAGS_RASTER_A1`, one bit of coverage a pixel.
        static let rasterA1: UInt8 = 1 << 0
        /// `SPICE_STRING_FLAGS_RASTER_A4`, four bits.
        static let rasterA4: UInt8 = 1 << 1
        /// `SPICE_STRING_FLAGS_RASTER_A8`, a whole byte.
        static let rasterA8: UInt8 = 1 << 2
        /// `SPICE_STRING_FLAGS_RASTER_TOP_DOWN`.
        ///
        /// **Decoded and not acted on, because the reference does not act on it
        /// either.** `canvas_put_glyph_bits` carries a `//todo: support
        /// SPICE_STRING_FLAGS_RASTER_TOP_DOWN` and reads every glyph bottom-up
        /// whatever the flag says. Honouring it here would draw text the other
        /// way up from every other client against the same server, which is a
        /// wrong picture rather than a better one.
        static let topDown: UInt8 = 1 << 3

        var flags: UInt8
        var glyphs: [RasterGlyph]

        /// Bits of coverage a pixel.
        ///
        /// The comment in `spice.proto` says "Special: Only one of a1/a4/a8
        /// set", and the reference tests them in that order — so a message with
        /// two set is read as the first, rather than refused. Reproduced: a
        /// server that sets two is already wrong, and picking the same one it
        /// picked is what puts the same pixels on the screen.
        var depth: Int? {
            if flags & Self.rasterA1 != 0 { return 1 }
            if flags & Self.rasterA4 != 0 { return 4 }
            if flags & Self.rasterA8 != 0 { return 8 }
            // Vector glyphs. The reference warns and draws nothing.
            return nil
        }

        /// Bytes a row, for a glyph of this width at this depth.
        ///
        /// **A1 and A4 pad each row to a whole byte; A8 does not.** The
        /// generated parser sizes them `((w + 7) / 8) * h`, `((4w + 7) / 8) * h`
        /// and `w * h` — so an A8 glyph of odd width has no padding at all,
        /// while an A4 glyph of odd width has half a byte of it. Assuming a
        /// common rule shears every row of one of the three.
        static func bytesPerRow(width: Int, depth: Int) -> Int {
            switch depth {
            case 1: return (width + 7) / 8
            case 4: return (4 * width + 7) / 8
            default: return width
            }
        }
    }

    /// `DRAW_TEXT` — glyphs painted through a brush.
    ///
    /// **Neither mode is a raster operation here**, which is the surprise of
    /// this message. `canvas_draw_text` fills the background with
    /// `SPICE_ROP_COPY` and composites the foreground with `PIXMAN_OP_OVER`,
    /// never consulting `back_mode` and using `fore_mode` only in an assertion
    /// that it is `PUT`. The reference's own comment says as much: *"Nothing
    /// else makes sense for text and we should deprecate it and actually it
    /// means OVER really"*.
    ///
    /// Both are decoded because they are on the wire and a reader of this type
    /// should see what arrived. Acting on them would draw something no other
    /// client draws.
    struct Text: Equatable, Sendable {
        var base: Base
        var string: TextString
        /// Filled with the background brush before the glyphs go down. An empty
        /// rectangle means transparent text — the common case — and is not the
        /// same as a rectangle the size of the string.
        var backArea: Rect
        var foreBrush: Brush
        var backBrush: Brush
        var foreMode: UInt16
        var backMode: UInt16
    }
}
