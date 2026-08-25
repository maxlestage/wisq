import Foundation

/// The pixels a stroke covers.
///
/// Separated from the surface it will be painted onto, and that is a testing
/// decision as much as a structural one: a Bresenham walk is a sequence of
/// coordinates, and the cheapest honest way to check it is to look at the
/// coordinates rather than at the pixels they later became.
///
/// This is `miZeroLine` from X11's `mi` layer, which is what SPICE's
/// `canvas_draw_stroke` reaches for by way of `spice_canvas_zero_line`. Zero
/// width — SPICE has no line width anywhere in `DRAW_STROKE`, because these are
/// Windows' *cosmetic* pens, one pixel however the surface is scaled.
enum SpiceStrokeRaster {
    /// Which of the eight octants a line runs in.
    ///
    /// The bits are the reference's: `XDECREASING` is 4, `YDECREASING` is 2,
    /// `YMAJOR` is 1. Only the numbering matters — it is the index into the
    /// bias word below, so a different order silently biases the wrong
    /// directions.
    private static func octant(dx: Int, dy: Int, yMajor: Bool) -> Int {
        (dx < 0 ? 4 : 0) | (dy < 0 ? 2 : 0) | (yMajor ? 1 : 0)
    }

    /// `DEFAULTZEROLINEBIAS`, which is `OCTANT2 | OCTANT3 | OCTANT4 | OCTANT5`
    /// and works out to `0b1101_1000`.
    ///
    /// **This is what makes a line reversible.** Bresenham has to break a tie
    /// whenever the ideal line passes exactly between two pixels, and breaking
    /// it the same way in every direction means a line drawn from A to B lights
    /// different pixels than the same line drawn from B to A. Subtracting one
    /// from the initial error in four of the eight octants — the four that are
    /// the reverses of the other four — makes the two agree.
    ///
    /// That is worth more than a transcription check: `SpiceStrokeRasterTests`
    /// walks a fan of lines in both directions and requires the pixel sets to
    /// match, which is a property of the *whole* table and not of any entry.
    /// Get one bit wrong and some slope stops being reversible.
    static let zeroLineBias = 0b1101_1000

    /// The pixels a single zero-width line covers, **excluding its last one**.
    ///
    /// `CapNotLast`, which `canvas_draw_stroke` sets because Win32 cosmetic
    /// lines are endpoint-exclusive. It is not a rounding detail: a rubber-band
    /// rectangle drawn as four strokes shares each corner between two of them,
    /// and drawing the endpoint paints every corner twice. Under an `XOR` rop —
    /// which is exactly what a rubber band uses — painting twice means the
    /// corner is *not there*, and dragging a selection leaves four holes.
    ///
    /// A degenerate line, both ends the same pixel, therefore covers nothing.
    /// The reference agrees: its `length` is zero and its trailing point is
    /// suppressed by the cap.
    static func line(
        from start: SpiceDisplayWire.Point, to end: SpiceDisplayWire.Point,
        _ plot: (Int, Int) -> Void
    ) {
        let x1 = Int(start.x), y1 = Int(start.y)
        let x2 = Int(end.x), y2 = Int(end.y)

        let dx = x2 - x1, dy = y2 - y1
        let adx = abs(dx), ady = abs(dy)
        let signX = dx < 0 ? -1 : 1
        let signY = dy < 0 ? -1 : 1
        // The reference writes `if (adx > ady) { x-major } else { y-major }`,
        // so **a perfect diagonal is y-major**, not x-major. Sabotage says the
        // two readings light the same pixels — with the minor delta equal to the
        // major one, the error term is positive on every step whatever the bias
        // — so this is a divergence nothing here could observe. It is matched
        // anyway: the equivalence holds for today's error terms and would stop
        // holding quietly if either ever changed, and agreeing with the
        // reference costs one character.
        let yMajor = ady >= adx
        let bias = (zeroLineBias >> octant(dx: dx, dy: dy, yMajor: yMajor)) & 1

        // The major axis is the one the walk steps along every time; the minor
        // one steps when the accumulated error says to. `length` is the major
        // delta and not one more than it, which is the endpoint exclusion.
        let major = yMajor ? ady : adx
        let minor = yMajor ? adx : ady
        guard major > 0 else { return }

        let e1 = minor << 1
        let e2 = e1 - (major << 1)
        let e3 = e2 - e1
        // `e = e1 - major`, then the bias, then the loop's own `e -= e1` before
        // it starts. Folded into one expression here; kept in the reference's
        // order so the bias lands before the shift and not after.
        var error = (e1 - major - bias) - e1

        var x = x1, y = y1
        for _ in 0..<major {
            plot(x, y)
            error += e1
            if error >= 0 {
                if yMajor { x += signX } else { y += signY }
                error += e3
            }
            if yMajor { y += signY } else { x += signX }
        }
    }

    /// A path's segments turned into polylines.
    ///
    /// A transcription of the loop in `canvas_draw_stroke`, and it is worth
    /// following that shape rather than a tidier one, because three of its
    /// rules are not what the flag names suggest:
    ///
    ///   * **`BEGIN` consumes the segment's first point as a position**, not as
    ///     a vertex to draw to. The remaining points are what the polyline or
    ///     the Bézier branch works on. Handing all of them to the curve reads
    ///     the start position as a control point and bends the curve towards
    ///     somewhere it never went.
    ///   * **`CLOSE` only does anything inside an `END`.** The reference writes
    ///     `if (END) { if (CLOSE) …; draw; }`, so a segment marked closed
    ///     without also being marked ended closes nothing.
    ///   * **closing joins back to the first point of the accumulated run**,
    ///     which may have started in an earlier segment — not to the first
    ///     point of the segment carrying the flag.
    ///
    /// A first version of this got all three wrong in ways that a rectangle
    /// drawn in one segment could not tell apart. A curve could.
    static func polylines(_ path: SpiceDisplayWire.Path) -> [[SpiceDisplayWire.Point]] {
        var figures: [[SpiceDisplayWire.Point]] = []
        var current: [SpiceDisplayWire.Point] = []

        func flush() {
            if current.count > 1 { figures.append(current) }
            current = []
        }

        for segment in path.segments {
            var points = segment.points[...]

            if segment.beginsAFigure {
                flush()
                if let first = points.first {
                    current.append(first.rounded)
                    points = points.dropFirst()
                }
            }

            if segment.isBezier {
                // Groups of three after the current position: two handles and
                // an endpoint. A remainder means the message contradicts
                // itself — the reference asserts on it — and is dropped rather
                // than guessed at.
                var index = points.startIndex
                while index + 2 < points.endIndex {
                    current += flattenedBezier(
                        from: current.last ?? points[index].rounded,
                        points[index].rounded, points[index + 1].rounded, points[index + 2].rounded
                    )
                    index += 3
                }
            } else {
                current += points.map(\.rounded)
            }

            if segment.endsAFigure {
                if segment.isClosed, let first = current.first { current.append(first) }
                flush()
            }
        }
        flush()
        return figures
    }

    /// One cubic Bézier as points on it.
    ///
    /// The reference subdivides adaptively; this samples at a fixed step taken
    /// from the control polygon's own length, which is never shorter than the
    /// curve it bounds. That makes consecutive samples at most a pixel apart,
    /// so the straight runs between them light the pixels a finer subdivision
    /// would. Coarser and the curve visibly polygonises; finer costs time for
    /// pixels that were already lit.
    private static func flattenedBezier(
        from start: SpiceDisplayWire.Point,
        _ control1: SpiceDisplayWire.Point, _ control2: SpiceDisplayWire.Point,
        _ end: SpiceDisplayWire.Point
    ) -> [SpiceDisplayWire.Point] {
        let bound = distance(start, control1) + distance(control1, control2)
            + distance(control2, end)
        let steps = max(1, min(bound, 4096))
        return (1...steps).map { step in
            cubic(start, control1, control2, end, Double(step) / Double(steps))
        }
    }

    private static func distance(
        _ a: SpiceDisplayWire.Point, _ b: SpiceDisplayWire.Point
    ) -> Int {
        abs(Int(a.x) - Int(b.x)) + abs(Int(a.y) - Int(b.y))
    }

    private static func cubic(
        _ p0: SpiceDisplayWire.Point, _ p1: SpiceDisplayWire.Point,
        _ p2: SpiceDisplayWire.Point, _ p3: SpiceDisplayWire.Point, _ t: Double
    ) -> SpiceDisplayWire.Point {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        let x = a * Double(p0.x) + b * Double(p1.x) + c * Double(p2.x) + d * Double(p3.x)
        let y = a * Double(p0.y) + b * Double(p1.y) + c * Double(p2.y) + d * Double(p3.y)
        return SpiceDisplayWire.Point(
            x: Int32(clamping: Int(x.rounded())), y: Int32(clamping: Int(y.rounded()))
        )
    }

    /// Walks a dash cycle along a run of pixels, reporting which are drawn.
    ///
    /// **A documented divergence.** The reference does not dash a zero-width
    /// line at all: `miZeroDashLine` sets the width to one, calls the *wide*
    /// line dasher, and sets it back, above a comment reading "XXX kludge until
    /// real zero-width dash code is written". So a dashed SPICE stroke and a
    /// solid one go through two different rasterisers there, and can disagree
    /// by a pixel at a join.
    ///
    /// wisq walks the same Bresenham pixels either way and skips the ones a gap
    /// covers, which is the thing the reference's own comment wishes it had.
    /// The lit pixels are a subset of the solid line's — never beside it — so a
    /// dashed border lands on the same track as a solid one, which is the
    /// property a user could notice. Matching the wide-line dasher pixel for
    /// pixel would mean transcribing `miWideDash`, for a difference visible
    /// only under a magnifier.
    struct DashCycle {
        private let lengths: [Int]
        private var index = 0
        private var remaining: Int
        private var drawing: Bool

        /// `offset` skips into the cycle, exactly as `dashOffset` does.
        init(lengths: [Int], offset: Int) {
            self.lengths = lengths.map { max(0, $0) }
            self.remaining = 0
            self.drawing = true
            var skip = offset
            self.remaining = self.lengths.first ?? 0
            // A cycle of nothing but zeroes would spin here forever, so the
            // walk is bounded by the cycle's length rather than by reaching the
            // offset: a pattern that covers no distance leaves the phase alone.
            var guardCount = self.lengths.count * 2
            while skip > 0, guardCount > 0, !self.lengths.isEmpty {
                if skip >= remaining {
                    skip -= remaining
                    advance()
                } else {
                    remaining -= skip
                    skip = 0
                }
                guardCount -= 1
            }
        }

        private mutating func advance() {
            guard !lengths.isEmpty else { return }
            index = (index + 1) % lengths.count
            remaining = lengths[index]
            drawing.toggle()
        }

        /// Consumes one pixel of the cycle and says whether it is drawn.
        mutating func step() -> Bool {
            guard !lengths.isEmpty else { return true }
            var guardCount = lengths.count + 1
            while remaining <= 0, guardCount > 0 {
                advance()
                guardCount -= 1
            }
            // Every length was zero: the pattern covers no distance at all, and
            // treating it as a solid line is the only reading that draws
            // anything. Refusing would blank a stroke the server expects to see.
            guard remaining > 0 else { return true }
            remaining -= 1
            return drawing
        }
    }
}
