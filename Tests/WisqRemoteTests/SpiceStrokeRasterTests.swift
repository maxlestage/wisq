import XCTest
@testable import WisqRemote

/// The zero-width line walk.
///
/// The interesting tests here do not check pixels against a list I wrote down —
/// a list I wrote down is a restatement of the code, and would agree with it
/// however wrong both were. They check *properties* the reference's algorithm
/// has and a naive Bresenham does not.
final class SpiceStrokeRasterTests: XCTestCase {
    private func point(_ x: Int, _ y: Int) -> SpiceDisplayWire.Point {
        SpiceDisplayWire.Point(x: Int32(x), y: Int32(y))
    }

    private func pixels(
        _ from: SpiceDisplayWire.Point, _ to: SpiceDisplayWire.Point
    ) -> [SpiceDisplayWire.Point] {
        var out: [SpiceDisplayWire.Point] = []
        SpiceStrokeRaster.line(from: from, to: to) { out.append(self.point($0, $1)) }
        return out
    }

    // MARK: - Ce que le biais existe pour

    /// **A line drawn backwards must light the same pixels.**
    ///
    /// This is what `DEFAULTZEROLINEBIAS` is for, and it is the only check here
    /// that tests the whole table rather than one entry. Bresenham has to break
    /// a tie whenever the ideal line passes exactly between two pixels; break
    /// it the same way in every direction and A→B disagrees with B→A. The
    /// reference subtracts one from the initial error in four of the eight
    /// octants — the four that are the reverses of the other four — and the two
    /// agree again.
    ///
    /// A fan of endpoints rather than a handful, because the ties only happen
    /// at particular slopes and a hand-picked set would miss them. `CapNotLast`
    /// drops a different endpoint each way, so what has to match is the union
    /// of the walk and its excluded end.
    func testALineDrawnBackwardsLightsTheSamePixels() {
        let origin = point(0, 0)
        var slopesWithTies = 0

        for endX in -20...20 {
            for endY in -20...20 {
                let end = point(endX, endY)
                if endX == 0 && endY == 0 { continue }

                let forward = Set((pixels(origin, end) + [end]).map { [$0.x, $0.y] })
                let backward = Set((pixels(end, origin) + [origin]).map { [$0.x, $0.y] })
                XCTAssertEqual(
                    forward, backward,
                    "la ligne (0,0)→(\(endX),\(endY)) n'est pas réversible"
                )
                // A tie happens when the major delta divides the minor one
                // evenly at a half — the slopes the bias exists for.
                let major = max(abs(endX), abs(endY))
                let minor = min(abs(endX), abs(endY))
                if major > 0, minor > 0, (minor * 2) % major == 0 { slopesWithTies += 1 }
            }
        }
        // A guard on the guard: if no sampled slope actually produced a tie,
        // the property above would hold for any bias at all, including none.
        XCTAssertGreaterThan(
            slopesWithTies, 100, "l'éventail ne contient pas assez de pentes à égalité"
        )
    }

    /// And the bias is not simply "no bias".
    ///
    /// Reversibility would also hold if the bias word were zero and the tie
    /// rule happened to be symmetric — so this pins that the table actually
    /// biases four octants, which is what `OCTANT2 | OCTANT3 | OCTANT4 |
    /// OCTANT5` works out to.
    func testTheBiasIsTheReferencesWordAndNotZero() {
        XCTAssertEqual(SpiceStrokeRaster.zeroLineBias, 0b1101_1000)
        XCTAssertEqual(SpiceStrokeRaster.zeroLineBias, 216)
        let biased = (0..<8).filter { (SpiceStrokeRaster.zeroLineBias >> $0) & 1 == 1 }
        XCTAssertEqual(biased, [3, 4, 6, 7], "quatre octants sur huit")
    }

    /// **The pixels themselves, for the slopes where Bresenham has to guess.**
    ///
    /// The reversibility test above is a good property and it is not enough.
    /// Sabotage swapped the roles of x and y in the octant index — which
    /// produces a *different* bias table that still biases exactly one member
    /// of every pair of opposite directions, so it stays perfectly reversible —
    /// and the whole suite went green.
    ///
    /// These coordinates come from `scripts/spice-zero-line/zeroline.py`, a
    /// transcription of `miZeroLine` and its macros. The asymmetry that pins
    /// the octant roles is visible in them: `(0,0)→(8,4)` steps in y on its very
    /// first move, while `(0,0)→(-8,4)` waits a step. A swapped table reverses
    /// exactly that.
    func testTheTiePixelsMatchTheReference() {
        let expected: [(from: (Int, Int), to: (Int, Int), pixels: [(Int, Int)])] = [
            ((0, 0), (8, 4), [(0, 0), (1, 1), (2, 1), (3, 2), (4, 2), (5, 3), (6, 3), (7, 4)]),
            ((0, 0), (4, 8), [(0, 0), (1, 1), (1, 2), (2, 3), (2, 4), (3, 5), (3, 6), (4, 7)]),
            ((0, 0), (8, -4), [(0, 0), (1, -1), (2, -1), (3, -2), (4, -2), (5, -3), (6, -3),
                               (7, -4)]),
            ((0, 0), (-8, 4), [(0, 0), (-1, 0), (-2, 1), (-3, 1), (-4, 2), (-5, 2), (-6, 3),
                               (-7, 3)]),
            ((0, 0), (-8, -4), [(0, 0), (-1, 0), (-2, -1), (-3, -1), (-4, -2), (-5, -2),
                                (-6, -3), (-7, -3)]),
            ((0, 0), (-4, 8), [(0, 0), (-1, 1), (-1, 2), (-2, 3), (-2, 4), (-3, 5), (-3, 6),
                               (-4, 7)]),
            ((8, 4), (0, 0), [(8, 4), (7, 4), (6, 3), (5, 3), (4, 2), (3, 2), (2, 1), (1, 1)]),
            ((0, 0), (16, 4), [(0, 0), (1, 0), (2, 1), (3, 1), (4, 1), (5, 1), (6, 2), (7, 2),
                               (8, 2), (9, 2), (10, 3), (11, 3), (12, 3), (13, 3), (14, 4),
                               (15, 4)]),
        ]

        for expectation in expected {
            let walk = pixels(
                point(expectation.from.0, expectation.from.1),
                point(expectation.to.0, expectation.to.1)
            )
            XCTAssertEqual(
                walk.map { (Int($0.x), Int($0.y)) }.map { [$0.0, $0.1] },
                expectation.pixels.map { [$0.0, $0.1] },
                "\(expectation.from) → \(expectation.to)"
            )
        }
    }

    // MARK: - Le capuchon

    /// **The last pixel is never drawn**, because Win32 cosmetic lines are
    /// endpoint-exclusive and `canvas_draw_stroke` asks for `CapNotLast`.
    ///
    /// It is not a rounding detail. A rubber-band rectangle is four strokes
    /// sharing four corners; drawing the endpoint paints each corner twice, and
    /// under the `XOR` a rubber band uses, twice means *not there* — dragging a
    /// selection would leave four holes.
    func testTheEndpointIsNotDrawn() {
        let walk = pixels(point(0, 0), point(5, 0))
        XCTAssertEqual(walk.map { Int($0.x) }, [0, 1, 2, 3, 4])
        XCTAssertFalse(walk.contains(point(5, 0)), "le point final appartient au segment suivant")
    }

    /// A line that goes nowhere covers nothing: its major delta is zero, and
    /// the only pixel it could draw is the endpoint it is not allowed to.
    func testALineFromAPixelToItselfDrawsNothing() {
        XCTAssertTrue(pixels(point(3, 3), point(3, 3)).isEmpty)
    }

    // MARK: - La marche elle-même

    /// One pixel a step along the major axis, and never two in the same column
    /// of it. A walk that steps both axes at once would leave diagonal gaps a
    /// line has no business having.
    func testTheWalkStepsTheMajorAxisExactlyOnceAtATime() {
        for (endX, endY) in [(17, 5), (5, 17), (-17, 5), (5, -17), (-9, -23), (23, -9)] {
            let walk = pixels(point(0, 0), point(endX, endY))
            XCTAssertEqual(walk.count, max(abs(endX), abs(endY)), "\(endX),\(endY)")

            for (previous, next) in zip(walk, walk.dropFirst()) {
                let stepX = abs(Int(next.x) - Int(previous.x))
                let stepY = abs(Int(next.y) - Int(previous.y))
                XCTAssertLessThanOrEqual(stepX, 1, "saut en x")
                XCTAssertLessThanOrEqual(stepY, 1, "saut en y")
                XCTAssertGreaterThan(stepX + stepY, 0, "deux fois le même pixel")
            }
        }
    }

    /// A diagonal is the diagonal, in all four directions — the case where a
    /// sign error is invisible on one axis and obvious on the other.
    func testAPerfectDiagonalStaysOnIt() {
        for (dx, dy) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
            let walk = pixels(point(0, 0), point(6 * dx, 6 * dy))
            XCTAssertEqual(walk.count, 6)
            for (step, pixel) in walk.enumerated() {
                XCTAssertEqual(Int(pixel.x), step * dx)
                XCTAssertEqual(Int(pixel.y), step * dy)
            }
        }
    }

    // MARK: - Les figures

    /// `BEGIN` starts a new figure. Run two together and an unrelated pair of
    /// shapes is joined by a line nobody asked for.
    func testABeginStartsANewFigureRatherThanContinuingTheLast() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin,
                points: [fix(0, 0), fix(4, 0)]
            ),
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin,
                points: [fix(0, 9), fix(4, 9)]
            ),
        ])
        let figures = SpiceStrokeRaster.polylines(path)
        XCTAssertEqual(figures.count, 2)
        XCTAssertEqual(figures[0].map(\.y), [0, 0])
        XCTAssertEqual(figures[1].map(\.y), [9, 9])
    }

    /// `CLOSE` repeats the first point, which under `CapNotLast` is what draws
    /// the closing corner at all: the previous segment stopped one short of it.
    func testAClosedFigureComesBackToItsFirstPoint() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.end
                    | SpiceDisplayWire.PathSegment.close,
                points: [fix(0, 0), fix(4, 0), fix(4, 4)]
            ),
        ])
        let figures = SpiceStrokeRaster.polylines(path)
        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures[0].count, 4)
        XCTAssertEqual(figures[0].first, figures[0].last)
    }

    /// **`CLOSE` on its own closes nothing.**
    ///
    /// The reference writes `if (END) { if (CLOSE) append(first); draw; }`, so
    /// the closing point is inside the `END` branch. A segment marked closed
    /// but not ended goes on accumulating. Reading the two flags as
    /// independent — which is what the names suggest — draws a closing line
    /// through the middle of a figure that was still being built.
    func testCloseWithoutEndClosesNothing() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.close,
                points: [fix(0, 0), fix(4, 0), fix(4, 4)]
            ),
        ])
        let figures = SpiceStrokeRaster.polylines(path)
        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures[0].count, 3, "aucun point de fermeture n'a été ajouté")
        XCTAssertNotEqual(figures[0].first, figures[0].last)
    }

    /// **`BEGIN` spends the first point on the starting position**, and the
    /// Bézier's control points are the three that follow it.
    ///
    /// Handing all four to the curve instead reads the start as a handle: the
    /// curve then leaves from the second point and bends toward somewhere the
    /// path never went. A straight-line segment cannot tell the two apart; a
    /// curve can, which is what found this.
    func testABeginPointIsAPositionAndNotABezierHandle() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.bezier,
                points: [fix(0, 0), fix(0, 30), fix(30, 30), fix(30, 0)]
            ),
        ])
        let curve = SpiceStrokeRaster.polylines(path).first ?? []
        XCTAssertEqual(curve.first, SpiceDisplayWire.Point(x: 0, y: 0), "la courbe part du départ")
        XCTAssertEqual(curve.last, SpiceDisplayWire.Point(x: 30, y: 0), "et finit à l'ancre")
        // A cubic from (0,0) with those handles is symmetric about x = 15 and
        // never reaches its handles' height: its peak is three quarters of it.
        let peak = curve.map { Int($0.y) }.max() ?? 0
        XCTAssertGreaterThan(peak, 20)
        XCTAssertLessThan(peak, 30, "la courbe ne touche pas ses poignées")
    }

    /// A single point is not a figure: there is no segment to walk, and the one
    /// pixel it could suggest is an endpoint the cap excludes anyway.
    func testALoneVertexIsNotAFigure() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin, points: [fix(2, 2)]
            ),
        ])
        XCTAssertTrue(SpiceStrokeRaster.polylines(path).isEmpty)
    }

    /// A flattened Bézier is sampled finely enough that consecutive samples are
    /// at most a pixel apart — which is what makes the straight runs between
    /// them light the pixels a finer subdivision would.
    func testAFlattenedCurveHasNoGapsBetweenItsSamples() {
        let path = SpiceDisplayWire.Path(segments: [
            SpiceDisplayWire.PathSegment(
                flags: SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.bezier,
                points: [fix(0, 0), fix(0, 40), fix(40, 40), fix(40, 0)]
            ),
        ])
        let samples = SpiceStrokeRaster.polylines(path).first ?? []
        XCTAssertGreaterThan(samples.count, 20, "la courbe est trop grossièrement échantillonnée")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(Int(next.x) - Int(previous.x)), 1)
            XCTAssertLessThanOrEqual(abs(Int(next.y) - Int(previous.y)), 1)
        }
    }

    // MARK: - Les tirets

    /// A cycle of four on, two off, walked along ten pixels.
    func testADashCycleAlternatesTheLengthsItWasGiven() {
        var cycle = SpiceStrokeRaster.DashCycle(lengths: [4, 2], offset: 0)
        let drawn = (0..<12).map { _ in cycle.step() }
        XCTAssertEqual(drawn, [true, true, true, true, false, false,
                               true, true, true, true, false, false])
    }

    /// The offset skips into the cycle rather than restarting it.
    func testTheOffsetSkipsIntoTheCycle() {
        var cycle = SpiceStrokeRaster.DashCycle(lengths: [4, 2], offset: 3)
        XCTAssertEqual((0..<4).map { _ in cycle.step() }, [true, false, false, true])
    }

    /// **A pattern of nothing but zeroes draws solid rather than nothing.**
    ///
    /// It covers no distance, so there is no reading under which it hides
    /// anything; blanking the stroke would lose a line the server expects to
    /// see, and looping forever looking for a length to consume would hang the
    /// pump on one malformed message.
    func testAPatternThatCoversNoDistanceDrawsRatherThanHangs() {
        var cycle = SpiceStrokeRaster.DashCycle(lengths: [0, 0, 0], offset: 5)
        XCTAssertEqual((0..<5).map { _ in cycle.step() }, [true, true, true, true, true])
    }

    private func fix(_ x: Int32, _ y: Int32) -> SpiceDisplayWire.PointFix {
        SpiceDisplayWire.PointFix(
            x: SpiceDisplayWire.Fixed28_4.whole(Int(x)),
            y: SpiceDisplayWire.Fixed28_4.whole(Int(y))
        )
    }
}
