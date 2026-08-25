import XCTest
@testable import WisqRemote

/// The cursor channel's layouts.
///
/// Two of these would have been written wrong from memory, and both are the
/// kind that produce a cursor rather than an error: `cursor_flags` is sixteen
/// bits where `cursor_type` is eight, so a guess puts the header two bytes off;
/// and the position is a `Point16` — two signed sixteen-bit values — not the
/// two 32-bit ones the display channel uses.
final class SpiceCursorWireTests: XCTestCase {
    private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func i16(_ v: Int16) -> [UInt8] { u16(UInt16(bitPattern: v)) }
    private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * $0) & 0xFF) } }

    /// A cursor structure: flags, header, pixels.
    private func cursor(
        flags: UInt16 = 0, kind: UInt8 = 0, width: UInt16 = 2, height: UInt16 = 2,
        hotspot: (UInt16, UInt16) = (1, 1), pixels: [UInt8]? = nil
    ) -> [UInt8] {
        var body = u16(flags)
        body += u64(0xABCD)
        body += [kind]
        body += u16(width) + u16(height)
        body += u16(hotspot.0) + u16(hotspot.1)
        body += pixels ?? (0..<(Int(width) * Int(height) * 4)).map { UInt8($0 & 0xFF) }
        return body
    }

    // MARK: - Widths

    /// The flags are sixteen bits and the type is eight. Swap them and every
    /// field after is two bytes out — a cursor that decodes to *something*,
    /// which is exactly why this needs pinning.
    func testTheFlagsAreSixteenBitsAndTheTypeIsEight() throws {
        var reader = try SpiceWire.Reader(cursor(kind: 0, width: 3, height: 5), from: 0)
        let (found, _) = try SpiceCursorWire.cursor(from: &reader)
        let cursor = try XCTUnwrap(found)
        XCTAssertEqual(cursor.width, 3)
        XCTAssertEqual(cursor.height, 5)
    }

    /// The position is two signed sixteen-bit values. A pointer at -1 is off
    /// the left edge, not at sixty-five thousand.
    func testThePositionIsSignedAndSixteenBitsRatherThanThirtyTwo() throws {
        let payload = i16(-1) + i16(-2)
        var reader = try SpiceWire.Reader(payload, from: 0)
        let at = try SpiceCursorWire.position(from: &reader)
        XCTAssertEqual(at, SpiceCursorWire.Position(x: -1, y: -2))
        XCTAssertEqual(reader.remaining, 0, "quatre octets, pas huit")
    }

    // MARK: - Messages

    func testTheInitialMessageCarriesPositionVisibilityAndCursor() throws {
        var payload = i16(100) + i16(50)
        payload += u16(0) + u16(0)      // trail length, frequency
        payload += [1]                  // visible
        payload += cursor(width: 2, height: 2, hotspot: (1, 1))

        let update = try SpiceCursorWire.initialise(payload)
        XCTAssertEqual(update.position, SpiceCursorWire.Position(x: 100, y: 50))
        XCTAssertTrue(update.visible)
        XCTAssertEqual(update.cursor?.width, 2)
        XCTAssertEqual(update.cursor?.hotspotX, 1)
        XCTAssertEqual(update.cursor?.bgra.count, 2 * 2 * 4)
    }

    /// `SET` has no trail fields. Reading them anyway would take four bytes out
    /// of the cursor structure that follows.
    func testTheSetMessageHasNoTrailFields() throws {
        var payload = i16(7) + i16(8)
        payload += [1]
        payload += cursor(width: 4, height: 4)

        let update = try SpiceCursorWire.set(payload)
        XCTAssertEqual(update.position, SpiceCursorWire.Position(x: 7, y: 8))
        XCTAssertEqual(update.cursor?.width, 4)
    }

    func testTheMoveMessageIsAPositionAndNothingElse() throws {
        let update = try SpiceCursorWire.move(i16(-3) + i16(400))
        XCTAssertEqual(update.position, SpiceCursorWire.Position(x: -3, y: 400))
        XCTAssertNil(update.cursor)
    }

    func testAnInvisibleCursorIsReportedAsSuch() throws {
        var payload = i16(0) + i16(0)
        payload += [0]                  // not visible
        payload += cursor()
        XCTAssertFalse(try SpiceCursorWire.set(payload).visible)
    }

    // MARK: - Absences, which are not all the same absence

    /// The `NONE` flag means the message carries no image, and nothing after
    /// the flags is read.
    func testTheNoneFlagMeansNothingFollowsTheFlags() throws {
        var reader = try SpiceWire.Reader(u16(SpiceCursorWire.Flag.none), from: 0)
        let (found, cached) = try SpiceCursorWire.cursor(from: &reader)
        XCTAssertNil(found)
        XCTAssertFalse(cached)
    }

    /// A cursor named from the cache carries a header and no pixels. Reported
    /// apart from "no cursor", because returning an empty image would read to
    /// the renderer as "hide the pointer" — the server asked for the opposite.
    func testACursorNamedFromTheCacheIsReportedRatherThanTreatedAsNoCursor() throws {
        var reader = try SpiceWire.Reader(
            cursor(flags: SpiceCursorWire.Flag.fromCache, pixels: []), from: 0
        )
        let (found, cached) = try SpiceCursorWire.cursor(from: &reader)
        XCTAssertNil(found)
        XCTAssertTrue(cached, "« je ne l'ai pas » n'est pas « il n'y en a pas »")
    }

    /// `CACHE_ME` is a request to remember, not a statement that there is
    /// nothing here. The pixels still follow.
    func testCacheMeStillCarriesItsPixels() throws {
        var reader = try SpiceWire.Reader(
            cursor(flags: SpiceCursorWire.Flag.cacheMe, width: 2, height: 2), from: 0
        )
        let (found, cached) = try SpiceCursorWire.cursor(from: &reader)
        XCTAssertNotNil(found)
        XCTAssertFalse(cached)
    }

    /// A form that needs a palette or bit-mask expansion yields no cursor
    /// rather than a guessed one. A cursor drawn from the wrong layout is a
    /// smear that follows the finger everywhere — worse than the system arrow.
    func testAFormThisDoesNotDecodeYieldsNoCursorRatherThanAGuess() throws {
        for kind in [UInt8(1) /* mono */, 2 /* colour4 */, 3, 4, 5] {
            var reader = try SpiceWire.Reader(cursor(kind: kind, pixels: []), from: 0)
            let (found, cached) = try SpiceCursorWire.cursor(from: &reader)
            XCTAssertNil(found, "type \(kind)")
            XCTAssertFalse(cached, "type \(kind)")
        }
    }

    func testAnUnknownCursorTypeIsRefused() throws {
        var reader = try SpiceWire.Reader(cursor(kind: 99, pixels: []), from: 0)
        XCTAssertThrowsError(try SpiceCursorWire.cursor(from: &reader)) { error in
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }

    /// Width and height are the server's numbers and their product is an
    /// allocation. A cursor is a small thing; a megapixel one is not a cursor.
    func testAnAbsurdCursorSizeIsRefusedBeforeAnythingIsRead() throws {
        for (width, height) in [(UInt16(0), UInt16(4)), (4, 0), (4096, 4096)] {
            var reader = try SpiceWire.Reader(
                cursor(width: width, height: height, pixels: []), from: 0
            )
            XCTAssertThrowsError(
                try SpiceCursorWire.cursor(from: &reader), "\(width)x\(height)"
            )
        }
    }

    /// A cursor claiming more pixels than it sent is refused, not padded.
    func testACursorShorterThanItsHeaderClaimsIsRefused() throws {
        var reader = try SpiceWire.Reader(
            cursor(width: 8, height: 8, pixels: [1, 2, 3, 4]), from: 0
        )
        XCTAssertThrowsError(try SpiceCursorWire.cursor(from: &reader)) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }
}
