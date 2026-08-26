import Foundation
import XCTest

@testable import WisqCore

/// The last line between a rectangle the server chose and this process's
/// memory.
///
/// `Framebuffer.write` says it outright: *"Out-of-bounds rows and columns are
/// clipped rather than trapping: a misbehaving server must not crash the app."*
/// Six guards carry that sentence. Sabotaging them one at a time gave:
///
/// | garde | sans elle |
/// | --- | --- |
/// | `write`, taille de la charge utile | **rien ne rougit** |
/// | `write`, bornes de ligne | plantage du runner |
/// | `write`, rognage de colonne | plantage du runner |
/// | `write`, `rect.x >= 0` | **rien ne rougit** |
/// | `copy`, bornes de la source | **rien ne rougit** |
/// | `copy`, bornes de la destination | **rien ne rougit** |
///
/// Quatre sur six ne tenaient à rien. Les deux autres ne tenaient qu'au fait
/// que leur absence tue le processus de test — une couverture par accident :
/// aucun test n'énonçait le rognage, donc un remaniement qui *changerait* la
/// sémantique au lieu de la supprimer serait passé.
///
/// Every rectangle here comes from a decoder, and every decoder takes its
/// dimensions off the wire.
final class FramebufferClippingTests: XCTestCase {
    private func filled(_ width: Int, _ height: Int, _ value: UInt8) -> [UInt8] {
        [UInt8](repeating: value, count: width * height * 4)
    }

    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> [UInt8] {
        let (width, _, pixels) = framebuffer.snapshot()
        let base = (y * width + x) * 4
        return Array(pixels[base..<(base + 4)])
    }

    // MARK: - The control

    /// A rectangle entirely inside the screen is written entirely. Everything
    /// below says "and this part is not written"; without this, a framebuffer
    /// that wrote nothing at all would satisfy the lot.
    func testARectangleFullyInsideIsWrittenInFull() {
        let framebuffer = Framebuffer(width: 4, height: 4)
        framebuffer.write(rect: Rect(x: 1, y: 1, width: 2, height: 2), bgra: filled(2, 2, 9))
        XCTAssertEqual(pixel(framebuffer, 1, 1), [9, 9, 9, 9])
        XCTAssertEqual(pixel(framebuffer, 2, 2), [9, 9, 9, 9])
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0], "et rien autour")
        XCTAssertEqual(pixel(framebuffer, 3, 3), [0, 0, 0, 0])
    }

    // MARK: - write

    /// A payload shorter than the rectangle it claims to fill. Nothing is
    /// written rather than reading past the end of the caller's array.
    func testAPayloadShorterThanItsRectangleIsRefused() {
        let framebuffer = Framebuffer(width: 4, height: 4)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 4, height: 4), bgra: filled(2, 2, 9))
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0], "une charge utile courte a été écrite")
    }

    /// Exactly enough is enough — the other side of the same boundary.
    func testAPayloadOfExactlyTheRightSizeIsWritten() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 2, height: 2), bgra: filled(2, 2, 5))
        XCTAssertEqual(pixel(framebuffer, 1, 1), [5, 5, 5, 5])
    }

    /// Rows past the bottom are dropped and the rows that fit are kept. Not
    /// "the whole write is refused": a server resizing its desktop sends
    /// rectangles that straddle the old edge, and losing the visible part of
    /// them would be a black band rather than a safe one.
    func testRowsPastTheBottomAreDroppedAndTheRestIsKept() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 1, width: 2, height: 4), bgra: filled(2, 4, 7))
        XCTAssertEqual(pixel(framebuffer, 0, 1), [7, 7, 7, 7], "la ligne qui tient doit être écrite")
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0], "et pas celles d'avant")
    }

    /// Columns past the right edge are clipped, and the part that fits lands.
    func testColumnsPastTheRightEdgeAreClipped() {
        let framebuffer = Framebuffer(width: 2, height: 1)
        framebuffer.write(rect: Rect(x: 1, y: 0, width: 4, height: 1), bgra: filled(4, 1, 6))
        XCTAssertEqual(pixel(framebuffer, 1, 0), [6, 6, 6, 6])
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0])
    }

    /// A rectangle starting left of the screen. `rect.x` is an `Int` from a
    /// `UInt16` on the wire today, but the guard is what makes that an
    /// implementation detail rather than the reason this does not crash.
    func testARectangleStartingLeftOfTheScreenWritesNothing() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: -2, y: 0, width: 4, height: 2), bgra: filled(4, 2, 8))
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(framebuffer, 1, 1), [0, 0, 0, 0])
    }

    func testARectangleStartingAboveTheScreenKeepsOnlyWhatFits() {
        let framebuffer = Framebuffer(width: 1, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: -1, width: 1, height: 3), bgra: filled(1, 3, 4))
        XCTAssertEqual(pixel(framebuffer, 0, 0), [4, 4, 4, 4], "la deuxième ligne source tombe en y = 0")
        XCTAssertEqual(pixel(framebuffer, 0, 1), [4, 4, 4, 4])
    }

    /// Entirely outside, in every direction, is a no-op and not a trap.
    func testARectangleEntirelyOutsideDoesNothing() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        for rect in [
            Rect(x: 10, y: 0, width: 2, height: 2),
            Rect(x: 0, y: 10, width: 2, height: 2),
            Rect(x: -10, y: 0, width: 2, height: 2),
            Rect(x: 0, y: -10, width: 2, height: 2),
        ] {
            framebuffer.write(rect: rect, bgra: filled(2, 2, 3))
        }
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(framebuffer, 1, 1), [0, 0, 0, 0])
    }

    /// A rectangle of no size at all, which a server may legitimately send.
    func testAnEmptyRectangleIsANoOp() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 0, height: 0), bgra: [])
        framebuffer.write(rect: Rect(x: 0, y: 0, width: -1, height: 2), bgra: filled(2, 2, 1))
        XCTAssertEqual(pixel(framebuffer, 0, 0), [0, 0, 0, 0])
    }

    // MARK: - copy

    /// CopyRect's source is two `UInt16`s off the wire and its destination is
    /// the rectangle header: both are the server's numbers, and both are
    /// guarded. The control first, so the refusals mean something.
    func testACopyFullyInsideMovesThePixels() {
        let framebuffer = Framebuffer(width: 4, height: 1)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 2, height: 1), bgra: filled(2, 1, 2))
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: 2, y: 0, width: 2, height: 1))
        XCTAssertEqual(pixel(framebuffer, 2, 0), [2, 2, 2, 2])
    }

    func testACopyWhoseSourceIsOffScreenDoesNotTrap() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 2, height: 2), bgra: filled(2, 2, 1))
        framebuffer.copy(from: Point(x: 10, y: 10), to: Rect(x: 0, y: 0, width: 2, height: 2))
        framebuffer.copy(from: Point(x: -5, y: -5), to: Rect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 16, "le tampon a changé de taille")
    }

    func testACopyWhoseDestinationIsOffScreenDoesNotTrap() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 2, height: 2), bgra: filled(2, 2, 1))
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: 10, y: 10, width: 2, height: 2))
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: -5, y: -5, width: 2, height: 2))
        XCTAssertEqual(pixel(framebuffer, 0, 0), [1, 1, 1, 1], "l'original doit être intact")
    }

    /// A copy larger than the screen in both directions at once: the source
    /// clip and the destination clip have to agree, or one writes rows the
    /// other never filled.
    func testACopyLargerThanTheScreenIsClippedAtBothEnds() {
        let framebuffer = Framebuffer(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 2, height: 2), bgra: filled(2, 2, 1))
        framebuffer.copy(from: Point(x: 1, y: 1), to: Rect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 16)
    }

    // MARK: - After a resize

    /// The screen can shrink under a rectangle already in flight — the server
    /// resizes, and the decoder is mid-update with the old geometry.
    func testARectangleForTheOldSizeIsClippedAfterAShrink() {
        let framebuffer = Framebuffer(width: 8, height: 8)
        framebuffer.resize(width: 2, height: 2)
        framebuffer.write(rect: Rect(x: 0, y: 0, width: 8, height: 8), bgra: filled(8, 8, 5))
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 16)
        XCTAssertEqual(pixel(framebuffer, 0, 0), [5, 5, 5, 5], "la partie qui tient doit s'écrire")
    }
}
