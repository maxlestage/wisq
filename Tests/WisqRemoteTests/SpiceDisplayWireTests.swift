import XCTest
@testable import WisqRemote

/// The display channel's layouts, against bytes built by hand from the
/// protocol description.
///
/// Every fixture below is assembled field by field rather than captured from a
/// server, which is deliberate: a capture proves this decoder agrees with one
/// server on one day, while a hand-built message says which bytes the protocol
/// requires and fails when the decoder stops reading them that way.
final class SpiceDisplayWireTests: XCTestCase {
    // MARK: - Building bytes

    private func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }
    private func u64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) } }

    /// `top`, `left`, `bottom`, `right` — the protocol's order.
    private func rect(top: Int32, left: Int32, bottom: Int32, right: Int32) -> [UInt8] {
        i32(top) + i32(left) + i32(bottom) + i32(right)
    }

    private var noClip: [UInt8] { [0] }

    /// A display base with no clip: surface id, box, clip type.
    private func base(surface: UInt32 = 0) -> [UInt8] {
        u32(surface) + rect(top: 10, left: 20, bottom: 110, right: 220) + noClip
    }

    /// An uncompressed bitmap image, as it sits at the far end of a pointer.
    private func bitmapImage(id: UInt64 = 7) -> [UInt8] {
        u64(id) + [0 /* BITMAP */, 0 /* flags */] + u32(64) + u32(48)
            + [8 /* 32BIT */, 0 /* flags: palette inline */] + u32(64) + u32(48) + u32(256)
            + u32(0) // palette pointer, null
    }

    // MARK: - Geometry

    /// The order is the whole test. Read as left/top/right/bottom — the order
    /// anyone would assume — every rectangle comes out transposed, and every
    /// draw lands somewhere other than where the server put it.
    func testARectangleIsTopLeftBottomRightAndNotTheUsualOrder() throws {
        var reader = try SpiceWire.Reader(rect(top: 1, left: 2, bottom: 3, right: 4), from: 0)
        let decoded = try SpiceDisplayWire.rect(from: &reader)
        XCTAssertEqual(decoded, SpiceDisplayWire.Rect(top: 1, left: 2, bottom: 3, right: 4))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
    }

    func testACoordinateIsSignedRatherThanHuge() throws {
        var reader = try SpiceWire.Reader(rect(top: -5, left: -10, bottom: 5, right: 10), from: 0)
        XCTAssertEqual(try SpiceDisplayWire.rect(from: &reader).top, -5)
    }

    /// The clip sits inline in the message. The protocol description marks it
    /// `@to_ptr`, which is about the C struct and not the wire — reading it as
    /// a pointer would eat four bytes and then treat a rectangle count as an
    /// offset into the message.
    func testTheClipIsInlineRatherThanBehindAPointer() throws {
        let payload = [1 /* RECTS */] + u32(2)
            + rect(top: 0, left: 0, bottom: 10, right: 10)
            + rect(top: 20, left: 20, bottom: 30, right: 30)
        var reader = try SpiceWire.Reader(payload, from: 0)
        guard case let .rects(rects) = try SpiceDisplayWire.clip(from: &reader) else {
            return XCTFail("attendu une liste de rectangles")
        }
        // Compared as a whole rather than by index. Subscripting after a
        // failed count assertion crashes the process, which takes the rest of
        // the suite's results with it — a wrong decoder should report one
        // failure, not hide seventeen other answers.
        XCTAssertEqual(rects, [
            SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 10, right: 10),
            SpiceDisplayWire.Rect(top: 20, left: 20, bottom: 30, right: 30),
        ])
    }

    /// A count no message could hold ends as a refusal rather than as four
    /// billion allocations.
    ///
    /// There is no length check behind this. The decoder appends one rectangle
    /// at a time and reserves nothing, so the first read past the end throws
    /// and the count never gets to mean anything. A bound was written here and
    /// removed once a sabotage showed it changed nothing — the safety is in not
    /// reserving, not in checking.
    func testARectangleCountLargerThanTheMessageIsRefusedRatherThanReserved() throws {
        var reader = try SpiceWire.Reader([1] + u32(0xFFFF_FFFF), from: 0)
        XCTAssertThrowsError(try SpiceDisplayWire.clip(from: &reader)) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }

    /// `PATH` was clip type 2 and was taken out of the protocol. Treating an
    /// unknown clip as "no clip" would paint over the part of the screen the
    /// server asked to be left alone.
    func testAnUnknownClipTypeIsRefusedRatherThanTreatedAsNoClip() throws {
        for type in [UInt8(2), 3, 255] {
            var reader = try SpiceWire.Reader([type] + u32(0), from: 0)
            XCTAssertThrowsError(try SpiceDisplayWire.clip(from: &reader), "type \(type)")
        }
    }

    // MARK: - Surfaces and mode

    func testTheModeMessageIsThreeWords() throws {
        let decoded = try SpiceDisplayWire.mode(u32(1920) + u32(1080) + u32(32))
        XCTAssertEqual(decoded, SpiceDisplayWire.Mode(width: 1920, height: 1080, bits: 32))
    }

    func testASurfaceIsCreatedWithItsFormat() throws {
        let decoded = try SpiceDisplayWire.surfaceCreate(
            u32(1) + u32(800) + u32(600) + u32(32) + u32(1)
        )
        XCTAssertEqual(decoded.surfaceID, 1)
        XCTAssertEqual(decoded.width, 800)
        XCTAssertEqual(decoded.format, .xrgb32)
    }

    /// The format numbers are sparse because they encode depth. A format this
    /// client cannot lay out is named rather than guessed at: guessing means
    /// every pixel after it is wrong, and wrong in a way that still fills the
    /// screen with something.
    func testAnUnknownSurfaceFormatIsRefusedRatherThanAssumed() {
        XCTAssertThrowsError(
            try SpiceDisplayWire.surfaceCreate(u32(1) + u32(800) + u32(600) + u32(77) + u32(0))
        ) { error in
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }

    func testATruncatedMessageIsRefusedRatherThanReadPastItsEnd() {
        XCTAssertThrowsError(try SpiceDisplayWire.mode(u32(1920) + u32(1080))) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }

    // MARK: - Pointers

    /// The rule this whole file exists for. A pointer is four bytes, and its
    /// value is an offset from the **start of the message**, not from the field
    /// that holds it. A decoder that measured from the field would read a
    /// plausible-looking structure out of the wrong bytes.
    func testAPointerIsAnOffsetFromTheStartOfTheMessage() throws {
        let head = base() + u32(0) // brush type NONE, then...
        // ...place the image well past the fixed part, and point at it.
        let imageOffset = UInt32(64)
        var payload = base() + u32(imageOffset)
        payload += [UInt8](repeating: 0xAA, count: Int(imageOffset) - payload.count)
        payload += bitmapImage(id: 0xDEAD)
        _ = head

        let body = SpiceDisplayWire.Body(payload)
        let image = try SpiceDisplayWire.image(at: imageOffset, in: body)
        XCTAssertEqual(image?.descriptor.id, 0xDEAD)
        XCTAssertEqual(image?.descriptor.type, .bitmap)
        XCTAssertEqual(image?.bitmap?.stride, 256)
    }

    /// Zero is null, and null is ordinary: a fill has no mask, a copy names an
    /// image the client already holds. It is an absence, not an error.
    func testANullPointerIsAnAbsenceRatherThanAFailure() throws {
        let body = SpiceDisplayWire.Body(bitmapImage())
        XCTAssertNil(try SpiceDisplayWire.image(at: 0, in: body))
    }

    /// An offset at or past the end of the message is where a hand-written
    /// decoder reads memory that is not the message. It is refused.
    ///
    /// Note what this does *not* pin down: an offset of exactly the message
    /// length is refused here, and would also fail a field later when the
    /// reader ran out of bytes. The two agree, so no test can tell them apart.
    /// The bound is written the way the protocol states it rather than the way
    /// a test could catch.
    func testAPointerPastTheEndOfTheMessageIsRefused() {
        let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 32))
        for offset in [UInt32(32), 33, 0xFFFF_FFFF] {
            XCTAssertThrowsError(try SpiceDisplayWire.image(at: offset, in: body), "\(offset)")
        }
    }

    /// Following the same offset twice on one path is refused.
    ///
    /// Written against `follow` itself rather than against a crafted message,
    /// and that is not laziness — it is the first version of this test being
    /// wrong. That one built a message whose mask pointed at itself and
    /// asserted a throw; removing the guard entirely left it passing, because
    /// the bytes it looped back onto happened to fail as a bitmap format a few
    /// fields later. It agreed with the guarded code about the error and proved
    /// nothing about the guard.
    ///
    /// No path through this decoder can cycle today: an image does not follow
    /// any further pointer, so the depth is at most two. The guard is here for
    /// the messages that are not decoded yet — `DRAW_ROP3` and `DRAW_OPAQUE`
    /// nest brushes and masks that each carry images — and this test is what
    /// keeps it honest until then.
    func testFollowingTheSameOffsetTwiceOnOnePathIsRefused() throws {
        let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 64))

        guard let (_, nested) = try body.follow(16) else {
            return XCTFail("le premier suivi doit aboutir")
        }
        // A different offset from the same place is fine.
        XCTAssertNotNil(try nested.follow(32))
        // The one already on the path is not.
        XCTAssertThrowsError(try nested.follow(16)) { error in
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
        // And it stays fine from a body that never followed it.
        XCTAssertNotNil(try body.follow(16))
    }

    // MARK: - Draw messages

    func testAFillCarriesItsBrushAndItsRasterOperation() throws {
        let payload = base(surface: 3)
            + [1] + u32(0x00FF_8000)       // brush: SOLID, colour
            + u16(0x000D)                  // rop descriptor
            + [0] + i32(0) + i32(0) + u32(0) // mask: no flags, origin, null bitmap

        let fill = try SpiceDisplayWire.fill(payload)
        XCTAssertEqual(fill.base.surfaceID, 3)
        XCTAssertEqual(fill.base.box, SpiceDisplayWire.Rect(top: 10, left: 20, bottom: 110, right: 220))
        XCTAssertEqual(fill.brush, .solid(0x00FF_8000))
        XCTAssertEqual(fill.rop, 0x000D)
        XCTAssertNil(fill.mask.bitmap)
    }

    /// The copy is the message that actually puts a picture on the screen, and
    /// the one whose source is behind a pointer.
    func testACopyResolvesItsSourceImageThroughThePointer() throws {
        var payload = base(surface: 1)
        let fixedEnd = payload.count + 4 + 16 + 2 + 1 + 1 + 8 + 4
        let imageOffset = UInt32(fixedEnd + 8)

        payload += u32(imageOffset)                          // src_bitmap pointer
        payload += rect(top: 0, left: 0, bottom: 48, right: 64) // src_area
        payload += u16(0x000D)                               // rop
        payload += [0]                                       // scale mode
        payload += [0] + i32(0) + i32(0) + u32(0)            // mask
        payload += [UInt8](repeating: 0, count: Int(imageOffset) - payload.count)
        payload += bitmapImage(id: 0x1234)

        let copy = try SpiceDisplayWire.copy(payload)
        XCTAssertEqual(copy.base.surfaceID, 1)
        XCTAssertEqual(copy.source?.descriptor.id, 0x1234)
        XCTAssertEqual(copy.source?.bitmap?.format, .thirtyTwoBit)
        XCTAssertEqual(copy.sourceArea, SpiceDisplayWire.Rect(top: 0, left: 0, bottom: 48, right: 64))
        XCTAssertEqual(copy.rop, 0x000D)
    }

    /// A copy naming an image the client already cached sends a null pointer.
    /// That is a normal message, not a broken one.
    func testACopyMayNameNoImageAtAll() throws {
        var payload = base(surface: 1)
        payload += u32(0)
        payload += rect(top: 0, left: 0, bottom: 48, right: 64)
        payload += u16(0) + [0]
        payload += [0] + i32(0) + i32(0) + u32(0)

        XCTAssertNil(try SpiceDisplayWire.copy(payload).source)
    }

    /// A compressed image is carried whole, not half-read.
    ///
    /// The length belongs to the display channel, so it is read here; the bytes
    /// belong to the codec, so they are handed on untouched. Reading fields out
    /// of a QUIC or LZ payload at this layer would be inventing a layout.
    func testACompressedImageIsCarriedWholeRatherThanHalfRead() throws {
        let codecBytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]
        let payload = u64(9) + [1 /* QUIC */, 0] + u32(64) + u32(48)
            + u32(UInt32(codecBytes.count)) + codecBytes
        let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 4) + payload)

        let image = try SpiceDisplayWire.image(at: 4, in: body)
        XCTAssertEqual(image?.descriptor.type, .quic)
        XCTAssertNil(image?.bitmap, "rien ne prétend connaître la forme d'un QUIC")
        XCTAssertEqual(image?.payload, codecBytes)
    }

    /// A length larger than the message is refused rather than believed. It is
    /// the one number in a compressed image that this layer does read, so it is
    /// the one that has to be checked.
    func testACompressedImageLongerThanItsMessageIsRefused() {
        let payload = u64(9) + [1, 0] + u32(64) + u32(48) + u32(0xFFFF_FFFF)
        let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 4) + payload)
        XCTAssertThrowsError(try SpiceDisplayWire.image(at: 4, in: body)) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }

    /// The encodings whose message shape is *not* a plain length and bytes are
    /// left alone entirely rather than read with the wrong shape.
    func testAnEncodingWithADifferentMessageShapeIsNotReadWithThisOne() throws {
        for type in [UInt8(100 /* LZ_PLT */), 103 /* FROM_CACHE */, 104 /* SURFACE */] {
            let payload = u64(9) + [type, 0] + u32(64) + u32(48) + u32(6) + [1, 2, 3, 4, 5, 6]
            let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 4) + payload)
            let image = try SpiceDisplayWire.image(at: 4, in: body)
            XCTAssertNil(image?.payload, "type \(type)")
            XCTAssertNil(image?.bitmap, "type \(type)")
        }
    }

    func testAnUnknownImageTypeIsRefused() {
        let payload = u64(9) + [200, 0] + u32(64) + u32(48)
        let body = SpiceDisplayWire.Body([UInt8](repeating: 0, count: 4) + payload)
        XCTAssertThrowsError(try SpiceDisplayWire.image(at: 4, in: body)) { error in
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }
}
