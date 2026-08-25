import Foundation

extension SpiceDisplayWire {
    /// A coordinate in SPICE's fixed-point format: 28 integer bits and four
    /// fractional ones, in an `int32`.
    ///
    /// The protocol calls it `SPICE_FIXED28_4`. Spelled with a `Point` here
    /// because SwiftLint's `type_name` refuses the underscore, and the name is
    /// worth keeping close to the wire's rather than shortened to something
    /// that no longer says which format it is.
    ///
    /// A distinct type rather than a bare `Int32`, because the whole risk here
    /// is treating one as the other. A stroke's points arrive multiplied by
    /// sixteen; used as pixels they would draw a line sixteen times too long
    /// and mostly off the surface.
    struct Fixed28Point4: Equatable, Hashable, Sendable {
        var raw: Int32

        init(raw: Int32) { self.raw = raw }

        /// Whole pixels, rounded the way the reference rounds.
        ///
        /// **Exactly a half rounds down**, and that is not a slip to tidy up.
        /// `fix_to_int` in `canvas_base.c` reads
        ///
        ///     rem = fixed & 0x0f; val = fixed >> 4; if (rem > 8) val++;
        ///
        /// — strictly *greater* than eight, so a remainder of exactly eight,
        /// which is one half, keeps the lower pixel. The obvious transcription,
        /// `(raw + 8) >> 4`, rounds it up instead, and disagrees on every
        /// coordinate that lands on a half. A server drawing a grid on half
        /// pixels would come out one pixel off, on some lines and not others.
        ///
        /// The arithmetic shift also matters: `>>` on a negative `Int32` in
        /// Swift, like `>>` on a signed int in C, floors rather than truncating
        /// toward zero, so −1/16 becomes −1 rather than 0. Reproduced rather
        /// than corrected, because it is what the server drew against.
        var rounded: Int {
            let remainder = raw & 0x0F
            let whole = Int(raw >> 4)
            return remainder > 8 ? whole + 1 : whole
        }

        /// Whole pixels with the fraction thrown away, which is what a
        /// coordinate wants when it is being used as an index rather than
        /// rounded to one.
        var truncated: Int { Int(raw >> 4) }

        static func whole(_ value: Int) -> Fixed28Point4 {
            Fixed28Point4(raw: Int32(clamping: value) << 4)
        }
    }

    /// A point on a stroke's path.
    struct PointFix: Equatable, Sendable {
        var x: Fixed28Point4
        var y: Fixed28Point4

        var rounded: Point { Point(x: Int32(clamping: x.rounded), y: Int32(clamping: y.rounded)) }
    }

    /// One run of points in a path.
    ///
    /// A path is a list of these, and each carries flags saying how it joins to
    /// what came before. The flags are the reason a path is not simply a list
    /// of points: a `BEGIN` starts a new figure rather than continuing the last
    /// one, and drawing them all as one polyline would connect two unrelated
    /// shapes with a line nobody asked for.
    struct PathSegment: Equatable, Sendable {
        /// `SPICE_PATH_BEGIN`. This segment starts a new figure.
        static let begin: UInt8 = 1 << 0
        /// `SPICE_PATH_END`. This segment finishes the figure.
        static let end: UInt8 = 1 << 1
        /// `SPICE_PATH_CLOSE` — **bit three, not bit two.**
        ///
        /// The enum skips a bit, and `SPICE_PATH_FLAGS_MASK` is `0x1b`
        /// (`0b11011`) rather than `0x0f`, which confirms it: bit two is not a
        /// flag at all. Counting the cases off in order gives close = 4 and
        /// bezier = 8, and then every closed rectangle draws as an open one.
        static let close: UInt8 = 1 << 3
        /// `SPICE_PATH_BEZIER`. The points are cubic control points, in groups
        /// of three after the current position.
        static let bezier: UInt8 = 1 << 4

        var flags: UInt8
        var points: [PointFix]

        var beginsAFigure: Bool { flags & Self.begin != 0 }
        var endsAFigure: Bool { flags & Self.end != 0 }
        var isClosed: Bool { flags & Self.close != 0 }
        var isBezier: Bool { flags & Self.bezier != 0 }
    }

    struct Path: Equatable, Sendable {
        var segments: [PathSegment]
    }

    /// How a stroke's line is dashed, if it is.
    ///
    /// `style` is present only when `STYLED` is set — on the wire, not merely
    /// in the C struct. `LineAttr` is a switch on its own flags byte, so an
    /// unstyled attribute is **one byte** and reading a length and a pointer
    /// anyway would swallow five bytes of the brush that follows it.
    struct LineAttr: Equatable, Sendable {
        /// `SPICE_LINE_FLAGS_START_WITH_GAP` — bit two.
        static let startWithGap: UInt8 = 1 << 2
        /// `SPICE_LINE_FLAGS_STYLED` — bit three.
        static let styled: UInt8 = 1 << 3

        var flags: UInt8
        /// The dash lengths as they arrived, in fixed point. Empty when the
        /// line is solid.
        var style: [Fixed28Point4]

        var isStyled: Bool { flags & Self.styled != 0 }
        var startsWithAGap: Bool { flags & Self.startWithGap != 0 }

        /// The dash lengths in whole pixels, in the order the rasteriser walks
        /// them, and where in that cycle to start.
        ///
        /// `nil` for a solid line, which is not the same as a cycle of zero
        /// lengths — one draws, the other would draw nothing at all.
        ///
        /// **`START_WITH_GAP` rotates the list, it does not simply invert the
        /// phase.** The reference moves the first length to the *end* and
        /// shifts the rest down, then sets the offset to the new first length:
        ///
        ///     dash[nseg - 1] = style[0];
        ///     for (i = 0; i < nseg - 1; i++) dash[i] = style[i + 1];
        ///     dashOffset = dash[0];
        ///
        /// So a `[4, 2]` pattern starting with a gap becomes `[2, 4]` with an
        /// offset of 2 — not `[4, 2]` starting on the gap. With two lengths the
        /// two readings happen to agree; with three or more they do not, and a
        /// dotted-then-dashed border comes out in the wrong order.
        var dashes: (lengths: [Int], offset: Int)? {
            guard isStyled, !style.isEmpty else { return nil }
            guard startsWithAGap else {
                return (style.map(\.rounded), 0)
            }
            var lengths = Array(style.dropFirst().map(\.rounded))
            lengths.append(style[0].rounded)
            return (lengths, lengths.first ?? 0)
        }
    }

    /// `DRAW_STROKE` — a path drawn as one-pixel lines.
    ///
    /// There is no line width anywhere in the message, and that is not an
    /// omission: `canvas_draw_stroke` sets `lineWidth = 0` unconditionally.
    /// These are Windows' *cosmetic* pens, always one pixel however the surface
    /// is scaled.
    ///
    /// The same origin explains the cap: the reference uses `CapNotLast`,
    /// because a Win32 cosmetic line does not draw its final point. Drawing it
    /// leaves a pixel behind at every corner of every rubber-band rectangle.
    struct Stroke: Equatable, Sendable {
        var base: Base
        var path: Path
        var attr: LineAttr
        var brush: Brush
        /// The rop descriptor for the drawn parts, read with the brush as the
        /// source and the destination as the destination — `ROP_INPUT_BRUSH,
        /// ROP_INPUT_DEST` in the reference.
        var foreMode: UInt16
        /// The descriptor for the gaps.
        ///
        /// Decoded because it is on the wire, and **not used**, because the
        /// reference does not use it either: it asks for `LineOnOffDash`, which
        /// leaves gaps untouched, rather than `LineDoubleDash`, which would
        /// paint them. Its own comment says the alternatives were all wrong in
        /// different ways and that the GL and GDI backends ignore it too.
        /// Keeping the field costs nothing and keeps the message honest; acting
        /// on it would draw something no other client draws.
        var backMode: UInt16
    }
}
