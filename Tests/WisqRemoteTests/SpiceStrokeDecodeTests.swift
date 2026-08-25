import XCTest
@testable import WisqRemote

/// Decoding `DRAW_STROKE`.
///
/// The wire layout here comes from the demarshaller the reference *generates*
/// from `spice.proto`, not from `draw.h`: the C struct and the wire differ in
/// three places, and each difference silently misaligns everything after it.
/// These tests build the bytes by hand so the layout is written down where it
/// can be checked rather than inferred from a struct.
final class SpiceStrokeDecodeTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private func u16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(value >> (8 * $0) & 0xFF) } }

    /// The `base`: a surface, a box and an empty clip. Twenty-one bytes.
    private func base() -> [UInt8] {
        u32(0) + i32(0) + i32(0) + i32(64) + i32(64) + [0]
    }

    /// One path segment as it sits on the wire: a one-byte flags, a four-byte
    /// count, then eight bytes a point.
    private func segment(flags: UInt8, _ points: [(Int32, Int32)]) -> [UInt8] {
        var bytes = [flags] + u32(UInt32(points.count))
        for point in points { bytes += i32(point.0 << 4) + i32(point.1 << 4) }
        return bytes
    }

    /// Assembles a whole message, placing the path (and any dash style) after
    /// the fixed part and pointing at them.
    private func message(
        segments: [[UInt8]], lineFlags: UInt8 = 0, style: [Int32] = [],
        brush: [UInt8] = [1] + [0xFF, 0, 0, 0], foreMode: UInt16 = 0x08
    ) -> [UInt8] {
        // The fixed part's length has to be known before the pointers can be
        // written, so it is measured rather than counted by hand.
        let styled = lineFlags & SpiceDisplayWire.LineAttr.styled != 0
        let fixedLength = base().count
            + 4                                  // path pointer
            + 1                                  // attr flags
            + (styled ? 1 + 4 : 0)               // style count and pointer
            + brush.count
            + 2 + 2                              // fore and back mode
        let pathOffset = UInt32(fixedLength)
        var path = u32(UInt32(segments.count))
        for segment in segments { path += segment }
        let styleOffset = UInt32(fixedLength + path.count)

        var bytes = base() + u32(pathOffset) + [lineFlags]
        if styled { bytes += [UInt8(style.count)] + u32(styleOffset) }
        bytes += brush + u16(foreMode) + u16(0)
        XCTAssertEqual(bytes.count, fixedLength, "la partie fixe n'a pas la longueur annoncée")
        bytes += path
        for length in style { bytes += i32(length << 4) }
        return bytes
    }

    // MARK: - Le point fixe

    /// **Exactly a half rounds down.**
    ///
    /// `fix_to_int` reads `if (rem > 8) val++` — strictly greater than eight.
    /// The obvious transcription, `(raw + 8) >> 4`, rounds a half up instead
    /// and disagrees on every coordinate that lands on one. Written as
    /// literals rather than as `whole(n) + half`, because the whole point is
    /// the boundary and an expression built from the same constant could not
    /// see it move.
    func testExactlyAHalfRoundsDownTheWayTheReferenceDoes() {
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 0).rounded, 0)
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 16).rounded, 1)
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 16 + 7).rounded, 1)
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 16 + 8).rounded, 1, "une demie exacte descend")
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 16 + 9).rounded, 2)
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 16 + 15).rounded, 2)
    }

    /// The rounding has **one rule and no special case for sign**: a half
    /// always goes toward minus infinity.
    ///
    /// +0.5 becomes 0 and −0.5 becomes −1. Both go down — which is the pair
    /// worth staring at, because every familiar rounding rule gets one of them
    /// wrong. "Half up" gives 1 and 0; "half away from zero" gives 1 and −1;
    /// "half to even" gives 0 and 0. Only "half toward minus infinity" gives
    /// 0 and −1, and that is what falls out of an arithmetic shift plus
    /// `rem > 8`.
    ///
    /// Two drafts of this test were wrong before this one, both because I did
    /// the arithmetic in my head instead of running the reference's formula.
    /// The values below come from evaluating `rem = fixed & 0x0f; val = fixed
    /// >> 4; if (rem > 8) val++` over the range, not from reasoning about it.
    func testTheRoundingHasOneRuleAndNoSpecialCaseForSign() {
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: 8).rounded, 0, "+0,5 descend")
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -8).rounded, -1, "−0,5 descend aussi")

        // The whole neighbourhood of −1.5, where the boundary sits.
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -22).rounded, -1)   // −1,3750
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -23).rounded, -1)   // −1,4375
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -24).rounded, -2)   // −1,5000
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -25).rounded, -2)   // −1,5625

        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -1).rounded, 0)     // −0,0625
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -7).rounded, 0)     // −0,4375
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -16).rounded, -1)
        XCTAssertEqual(SpiceDisplayWire.Fixed28Point4(raw: -32).rounded, -2)
    }

    // MARK: - Les drapeaux

    /// **`CLOSE` is bit three, and the mask proves it.**
    ///
    /// `SPICE_PATH_FLAGS_MASK` is `0x1b` — `0b11011` — so bit two is not a flag
    /// at all. Counting the four cases off in order instead gives close = 4 and
    /// bezier = 8, and then every closed rectangle draws as an open one and
    /// every Bézier draws as a polyline through its control points.
    func testThePathFlagsAreTheReferencesAndNotAConsecutiveCount() {
        XCTAssertEqual(SpiceDisplayWire.PathSegment.begin, 0x01)
        XCTAssertEqual(SpiceDisplayWire.PathSegment.end, 0x02)
        XCTAssertEqual(SpiceDisplayWire.PathSegment.close, 0x08)
        XCTAssertEqual(SpiceDisplayWire.PathSegment.bezier, 0x10)
        let mask = SpiceDisplayWire.PathSegment.begin | SpiceDisplayWire.PathSegment.end
            | SpiceDisplayWire.PathSegment.close | SpiceDisplayWire.PathSegment.bezier
        XCTAssertEqual(mask, 0x1B, "SPICE_PATH_FLAGS_MASK")
    }

    func testTheLineFlagsAreTheReferences() {
        XCTAssertEqual(SpiceDisplayWire.LineAttr.startWithGap, 0x04)
        XCTAssertEqual(SpiceDisplayWire.LineAttr.styled, 0x08)
        XCTAssertEqual(
            SpiceDisplayWire.LineAttr.startWithGap | SpiceDisplayWire.LineAttr.styled, 0x0C,
            "SPICE_LINE_FLAGS_MASK"
        )
    }

    // MARK: - Le fil

    func testAPathIsSegmentsOneAfterAnother() throws {
        let stroke = try SpiceDisplayWire.stroke(message(segments: [
            segment(flags: SpiceDisplayWire.PathSegment.begin, [(1, 2), (3, 4)]),
            segment(flags: SpiceDisplayWire.PathSegment.end, [(5, 6)]),
        ]))

        XCTAssertEqual(stroke.path.segments.count, 2)
        XCTAssertTrue(stroke.path.segments[0].beginsAFigure)
        XCTAssertEqual(stroke.path.segments[0].points.count, 2)
        XCTAssertEqual(stroke.path.segments[0].points[0].rounded, .init(x: 1, y: 2))
        XCTAssertEqual(stroke.path.segments[0].points[1].rounded, .init(x: 3, y: 4))
        XCTAssertTrue(stroke.path.segments[1].endsAFigure)
        XCTAssertEqual(stroke.path.segments[1].points[0].rounded, .init(x: 5, y: 6))
    }

    /// A segment's flags are **one byte on the wire** while `SpicePathSeg.flags`
    /// is a `uint32_t`. Reading four lands every later segment three bytes
    /// early and turns the second one's coordinates into a flags-and-count
    /// pair. Two segments are the fewest that can tell.
    func testASegmentsFlagsAreOneByteAndNotFour() throws {
        let stroke = try SpiceDisplayWire.stroke(message(segments: [
            segment(flags: SpiceDisplayWire.PathSegment.begin, [(0, 0)]),
            segment(flags: SpiceDisplayWire.PathSegment.close, [(7, 7)]),
        ]))
        XCTAssertEqual(stroke.path.segments.count, 2)
        XCTAssertTrue(stroke.path.segments[1].isClosed)
        XCTAssertEqual(stroke.path.segments[1].points[0].rounded, .init(x: 7, y: 7))
    }

    /// **An unstyled line attribute is a single byte.**
    ///
    /// `LineAttr` is a switch on its own flags, so `style_nseg` and `style` are
    /// absent from the wire when `STYLED` is clear — even though the C struct
    /// always carries both. Reading them anyway swallows five bytes of the
    /// brush, and the brush is what says the line's colour.
    func testAnUnstyledAttributeCostsOneByteAndTheBrushFollowsImmediately() throws {
        let stroke = try SpiceDisplayWire.stroke(message(
            segments: [segment(flags: 0, [(0, 0), (4, 4)])],
            brush: [1] + u32(0x00AB_CDEF)
        ))
        XCTAssertEqual(stroke.brush, .solid(0x00AB_CDEF), "la brosse a été lue au bon endroit")
        XCTAssertFalse(stroke.attr.isStyled)
        XCTAssertTrue(stroke.attr.style.isEmpty)
        XCTAssertEqual(stroke.foreMode, 0x08)
    }

    func testAStyledAttributeCarriesItsLengthsBehindAPointer() throws {
        let stroke = try SpiceDisplayWire.stroke(message(
            segments: [segment(flags: 0, [(0, 0), (9, 0)])],
            lineFlags: SpiceDisplayWire.LineAttr.styled,
            style: [4, 2, 1],
            brush: [1] + u32(0x0000_FF00)
        ))
        XCTAssertTrue(stroke.attr.isStyled)
        XCTAssertEqual(stroke.attr.style.map(\.rounded), [4, 2, 1])
        XCTAssertEqual(stroke.brush, .solid(0x0000_FF00), "la brosse suit toujours le style")
    }

    // MARK: - Le motif de tirets

    /// A solid line has no cycle at all, which is not the same as a cycle of
    /// zeroes: one draws the whole line, the other would draw nothing.
    func testASolidLineHasNoDashCycleRatherThanAnEmptyOne() throws {
        let stroke = try SpiceDisplayWire.stroke(
            message(segments: [segment(flags: 0, [(0, 0), (4, 0)])])
        )
        XCTAssertNil(stroke.attr.dashes)
    }

    /// **`START_WITH_GAP` rotates the list; it does not invert the phase.**
    ///
    /// The reference moves the first length to the end, shifts the rest down,
    /// and sets the offset to the new first length. With three lengths the two
    /// readings disagree: `[4, 2, 1]` becomes `[2, 1, 4]` starting at 2, where
    /// "same list, start on a gap" would keep `[4, 2, 1]`. Three is the fewest
    /// that can tell them apart — with two the rotation and the inversion
    /// happen to agree.
    func testStartingWithAGapRotatesTheCycleRatherThanFlippingIt() throws {
        let stroke = try SpiceDisplayWire.stroke(message(
            segments: [segment(flags: 0, [(0, 0), (9, 0)])],
            lineFlags: SpiceDisplayWire.LineAttr.styled
                | SpiceDisplayWire.LineAttr.startWithGap,
            style: [4, 2, 1]
        ))
        let dashes = try XCTUnwrap(stroke.attr.dashes)
        XCTAssertEqual(dashes.lengths, [2, 1, 4])
        XCTAssertEqual(dashes.offset, 2, "l'offset est la nouvelle première longueur")
    }

    func testWithoutTheGapFlagTheCycleIsTheListAsItArrived() throws {
        let stroke = try SpiceDisplayWire.stroke(message(
            segments: [segment(flags: 0, [(0, 0), (9, 0)])],
            lineFlags: SpiceDisplayWire.LineAttr.styled,
            style: [4, 2, 1]
        ))
        let dashes = try XCTUnwrap(stroke.attr.dashes)
        XCTAssertEqual(dashes.lengths, [4, 2, 1])
        XCTAssertEqual(dashes.offset, 0)
    }

    // MARK: - Les messages qui se contredisent

    /// A stroke with nowhere to draw is a message contradicting itself, not an
    /// empty drawing: every stroke has a path by construction — `@nonnull` in
    /// the protocol description.
    func testAStrokeWithNoPathIsRefused() {
        var bytes = base() + u32(0) + [0] + [1] + u32(0) + u16(0x08) + u16(0)
        XCTAssertThrowsError(try SpiceDisplayWire.stroke(bytes))
        bytes = []
        XCTAssertThrowsError(try SpiceDisplayWire.stroke(bytes))
    }

    /// A styled attribute whose lengths are behind a null pointer is refused
    /// rather than quietly drawn solid. A dotted border arriving as a solid one
    /// is a wrong picture, not a missing feature.
    func testAStyledLineWithNoLengthsIsRefusedRatherThanDrawnSolid() {
        let path = segment(flags: 0, [(0, 0), (4, 0)])
        let fixedLength = base().count + 4 + 1 + 1 + 4 + 5 + 2 + 2
        var bytes = base() + u32(UInt32(fixedLength)) + [SpiceDisplayWire.LineAttr.styled]
        bytes += [2] + u32(0)                      // deux longueurs, pointeur nul
        bytes += [1] + u32(0) + u16(0x08) + u16(0)
        bytes += u32(1) + path
        XCTAssertThrowsError(try SpiceDisplayWire.stroke(bytes))
    }
}
