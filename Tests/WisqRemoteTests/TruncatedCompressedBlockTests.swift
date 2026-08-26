import Foundation
import WisqCore
import XCTest

@testable import WisqRemote

/// The two guards that stand between a truncated compressed block and an
/// out-of-bounds read.
///
/// `ByteCursor.read(_:)` and `ByteCursor.readUInt8()` both refuse to read past
/// the end, and **nothing held either of them**: removing the guard from either
/// one left all 964 tests green. They were right, and one careless edit away
/// from not being there at all.
///
/// The bytes they guard are not ours. A ZRLE rectangle inflates into a tile
/// stream whose palette sizes, run lengths and pixel counts are all decided by
/// the server; a short block is what a broken one — or a hostile one — sends.
/// Reading past the end of a Swift array is not an error, it is the end of the
/// process.
///
/// So the shape of every test here is: promise more than the block carries, and
/// require an **error**. A crash would not be a red test, it would be a dead
/// runner — which is the point.
final class TruncatedCompressedBlockTests: XCTestCase {
    // MARK: - The cursor on its own

    func testReadingMoreThanRemainsIsRefused() {
        var cursor = ByteCursor(Data([1, 2, 3]))
        XCTAssertThrowsError(try cursor.read(4))
    }

    /// The exact boundary in both directions: all of it is fine, one more is
    /// not. An off-by-one in the guard would pass the first and the second.
    func testTheBoundaryIsExact() throws {
        var cursor = ByteCursor(Data([1, 2, 3]))
        XCTAssertEqual(Array(try cursor.read(3)), [1, 2, 3])
        XCTAssertTrue(cursor.isAtEnd)
        XCTAssertThrowsError(try cursor.read(1))
    }

    func testReadingAByteAtTheEndIsRefused() throws {
        var cursor = ByteCursor(Data([7]))
        XCTAssertEqual(try cursor.readUInt8(), 7)
        XCTAssertThrowsError(try cursor.readUInt8())
    }

    func testAnEmptyBlockRefusesImmediately() {
        var cursor = ByteCursor(Data())
        XCTAssertThrowsError(try cursor.readUInt8())
        XCTAssertThrowsError(try cursor.read(1))
    }

    /// A pixel is three bytes, so two remaining is not enough for one — the
    /// case a block truncated mid-pixel produces.
    func testAPixelCannotBeReadFromTwoBytes() {
        var cursor = ByteCursor(Data([1, 2]))
        XCTAssertThrowsError(try cursor.readCompressedPixel())
    }

    /// A run length that says "keep reading" and then stops. The loop only ends
    /// because `readUInt8` refuses; without that guard it walks off the array.
    func testARunLengthThatNeverEndsIsRefusedRatherThanFollowed() {
        var cursor = ByteCursor(Data([255, 255, 255]))
        XCTAssertThrowsError(try cursor.readRunLength())
    }

    /// And the control, so the refusals above mean something: a block that
    /// carries what it promises is read, and read correctly.
    func testAWellFormedBlockIsReadThrough() throws {
        var cursor = ByteCursor(Data([0x0A, 0x0B, 0x0C, 0xFF, 0x02]))
        XCTAssertEqual(try cursor.readCompressedPixel(), [0x0A, 0x0B, 0x0C, 255])
        XCTAssertEqual(try cursor.readRunLength(), 258, "255 veut dire « continue », et le total gagne 1")
        XCTAssertTrue(cursor.isAtEnd)
    }

    // MARK: - Through ZRLE, where the bytes actually come from

    private func zrle(_ bytes: [UInt8], width: Int = 64, height: Int = 64) throws {
        try ZRLEDecoder.decode(
            rect: Rect(x: 0, y: 0, width: width, height: height),
            data: Data(bytes), into: Framebuffer(width: width, height: height))
    }

    /// A raw tile promises width × height pixels and carries one.
    func testARawTileShorterThanItsRectangleThrows() {
        XCTAssertThrowsError(try zrle([0x00, 1, 2, 3]))
    }

    /// A solid tile whose single colour is cut in half.
    func testASolidTileMissingItsColourThrows() {
        XCTAssertThrowsError(try zrle([0x01, 1, 2]))
    }

    /// A palette that announces sixteen entries and provides one.
    func testAPaletteShorterThanItsAnnouncedSizeThrows() {
        XCTAssertThrowsError(try zrle([0x10, 1, 2, 3]))
    }

    /// The packed indices after a valid palette, cut short.
    func testPackedIndicesRunningOutThrows() {
        XCTAssertThrowsError(try zrle([0x02, 1, 2, 3, 4, 5, 6, 0xFF]))
    }

    /// A run-length tile that stops between a colour and its length.
    func testARunLengthTileCutBetweenColourAndLengthThrows() {
        XCTAssertThrowsError(try zrle([0x80, 1, 2, 3]))
    }

    /// The block that stops before the tile even declares what it is.
    func testAnEmptyBlockThrowsRatherThanPaintingNothing() {
        XCTAssertThrowsError(try zrle([]))
    }

    /// The control again, at this level: a solid tile that carries its colour
    /// decodes, and paints. Without this the tests above would pass for a
    /// decoder that refused everything.
    func testASolidTileThatCarriesItsColourIsPainted() throws {
        let framebuffer = Framebuffer(width: 2, height: 2)
        try ZRLEDecoder.decode(
            rect: Rect(x: 0, y: 0, width: 2, height: 2),
            data: Data([0x01, 9, 8, 7]), into: framebuffer)
        let pixels = framebuffer.snapshot().pixels
        XCTAssertEqual(Array(pixels[0..<4]), [9, 8, 7, 255])
        XCTAssertEqual(Array(pixels[12..<16]), [9, 8, 7, 255], "les quatre pixels de la tuile")
    }
}
