import Foundation
import WisqCore
import WisqNet
import XCTest

@testable import WisqRemote

/// The rectangles that paint on the screen, which had no ceiling of their own.
///
/// The slice before this one capped the **screen**. A rectangle is a different
/// number arriving by a different door, and nothing bounded it. Two encodings
/// allocate from that geometry *alone*, before a pixel byte has to arrive:
/// CopyRect, which carries no pixels at all, and RRE, which allocates its tile
/// after a count and one colour.
///
/// Measured before it was fixed, on a 64 × 64 framebuffer:
///
/// ```
/// Fatal error: failed to allocate 17179344932 bytes of memory with alignment 8
/// ```
///
/// Twelve bytes of CopyRect. `RFBLimits` said why it thought this was safe —
/// "`UInt16` … bounds every pixel product on its own" — which is true about
/// arithmetic and was read as being about size. The bound `UInt16` gives is
/// 65535² × 4, and the file wrote that number out as reassurance.
///
/// The other encodings are byte-gated: a server must actually send the pixels.
/// But their ceilings come from `maximumCompressedBytes(for:)`, which is
/// computed *from* the rectangle — 17 180 393 476 for a 65535 × 65535 one,
/// measured. A guard derived from the attacker's number grants what it should
/// refuse; it means something only now that the rectangle is bounded first.
///
/// **No test here allocates anything large.** They assert the refusal.
final class PaintableRectTests: XCTestCase {
    // MARK: - What must be refused

    func testTheLargestRectangleTheWireCanNameIsRefused() {
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 65535, height: 65535)))
    }

    /// The refusal names the rectangle: a session that stops has to be able to
    /// say what stopped it.
    func testTheRefusalSaysWhichRectangle() {
        do {
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 65535, height: 65535))
            XCTFail("aurait dû refuser")
        } catch {
            XCTAssertTrue("\(error)".contains("65535×65535"), "\(error)")
        }
    }

    /// Past the line by product and by each side separately.
    func testJustPastTheCeilingIsRefusedByProductAndBySide() {
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 8193, height: 8193)))
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(
                Rect(x: 0, y: 0, width: Framebuffer.maximumPixels + 1, height: 1)))
    }

    /// The offset is not part of the ceiling. A rectangle far off-screen paints
    /// nothing — `Framebuffer.write` clips — and refusing it would break a
    /// server whose resize crossed an update on the wire.
    func testAnOffsetRectangleIsJudgedOnItsSizeAlone() {
        XCTAssertNoThrow(
            try RFBLimits.requirePaintableRect(Rect(x: 60000, y: 60000, width: 16, height: 16)))
    }

    // MARK: - Through a real session

    private func handshake(width: UInt8, height: UInt8) -> Data {
        var built = Data("RFB 003.008\n".utf8)
        built.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        built.append(contentsOf: [0, 0, 0, 0])
        built.append(contentsOf: [0, width, 0, height])
        built.append(PixelFormat.bgra32.encoded)
        built.append(contentsOf: [0, 0, 0, 4])
        built.append(contentsOf: Array("wisq".utf8))
        return built
    }

    private func reason(for script: Data) async -> String? {
        let framebuffer = Framebuffer(width: 0, height: 0)
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            framebuffer: framebuffer,
            streamProvider: { [script] _ in MemoryByteStream(inbound: script) })
        var reason: String?
        await session.start()
        for await event in session.events {
            if case .disconnected(let error) = event, let error { reason = "\(error)" }
        }
        return reason
    }

    /// The one that killed the process. CopyRect carries no pixels, so the
    /// whole attack is the rectangle header plus a source point.
    ///
    /// It asserts the **reason**, not merely that the session stopped: without
    /// the check this script does not survive either — `Framebuffer.copy` would
    /// have been asked for seventeen gigabytes first.
    func testACopyRectOfImpossibleSizeEndsTheSession() async throws {
        var script = handshake(width: 64, height: 64)
        script.append(contentsOf: [0, 0, 0, 1])  // FramebufferUpdate, 1 rectangle
        script.append(contentsOf: [0, 0, 0, 0])  // x, y
        script.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // 65535×65535
        script.append(contentsOf: [0, 0, 0, 1])  // encodage 1 : CopyRect
        script.append(contentsOf: [0, 0, 0, 0])  // source

        let stopped = await reason(for: script)
        let said = try XCTUnwrap(stopped, "la session ne s'est pas arrêtée")
        XCTAssertTrue(said.contains("65535×65535"), "arrêtée, mais pour une autre raison : \(said)")
    }

    /// The second one that allocates from geometry alone: RRE's tile is sized
    /// by the rectangle after a subrectangle count and one background colour.
    func testAnRRERectangleOfImpossibleSizeEndsTheSession() async throws {
        var script = handshake(width: 64, height: 64)
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        script.append(contentsOf: [0, 0, 0, 2])  // encodage 2 : RRE
        script.append(contentsOf: [0, 0, 0, 0])  // aucun sous-rectangle
        script.append(contentsOf: [0, 0, 0, 255])  // couleur de fond

        let stopped = await reason(for: script)
        let said = try XCTUnwrap(stopped, "la session ne s'est pas arrêtée")
        XCTAssertTrue(said.contains("65535×65535"), "arrêtée, mais pour une autre raison : \(said)")
    }

    /// The control at the same level: the same shape of script with an ordinary
    /// rectangle paints instead of stopping. Without it, a session that refused
    /// every CopyRect would satisfy the two tests above.
    func testAnOrdinaryCopyRectStillPaints() async throws {
        var script = handshake(width: 64, height: 64)
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(contentsOf: [0, 16, 0, 16])  // 16×16
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(contentsOf: [0, 0, 0, 0])

        let said = await reason(for: script)
        XCTAssertNotEqual(
            said?.contains("peut peindre"), true, "un rectangle de 16×16 ne doit pas être refusé")
    }

    // MARK: - The edge that must not move

    /// A `desktopSize` rectangle puts the new screen size in the same four
    /// fields. It must keep reaching the resize path and its own message,
    /// rather than being caught by the paint ceiling on the way.
    func testAResizeIsStillJudgedAsAResize() async throws {
        var script = handshake(width: 64, height: 64)
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        script.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x21])  // encodage -223

        let stopped = await reason(for: script)
        let said = try XCTUnwrap(stopped)
        XCTAssertTrue(said.contains("bureau"), "un redimensionnement doit parler de bureau : \(said)")
        XCTAssertFalse(said.contains("peindre"), "et non du plafond de peinture : \(said)")
    }

    /// The cursor keeps its own tighter bound, from the pseudo-encodings slice.
    /// A 512 × 512 cursor is well inside the paint ceiling and must still be
    /// refused, with the cursor's message.
    func testTheCursorKeepsItsOwnTighterCeiling() async throws {
        var script = handshake(width: 64, height: 64)
        script.append(contentsOf: [0, 0, 0, 1])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(contentsOf: [0x02, 0x00, 0x02, 0x00])  // 512×512
        script.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x11])  // encodage -239

        let stopped = await reason(for: script)
        let said = try XCTUnwrap(stopped)
        XCTAssertTrue(said.contains("curseur"), "\(said)")
    }

    /// Every encoding that paints is covered, and no pseudo-encoding is. This
    /// is the list the guard is applied from, so it is the list that has to be
    /// pinned — an encoding added to the enum and forgotten here is the way
    /// this comes back.
    func testTheEncodingsThatPaintAreExactlyTheSeven() {
        let painting = RFB.Encoding.allCases.filter(\.carriesPixels)
        XCTAssertEqual(
            Set(painting), Set([.raw, .copyRect, .rre, .hextile, .zlib, .tight, .zrle]))
        for pseudo in [RFB.Encoding.cursor, .desktopSize, .lastRect, .desktopName,
                       .extendedDesktopSize, .continuousUpdates] {
            XCTAssertFalse(pseudo.carriesPixels, "\(pseudo) ne porte pas de pixels")
        }
    }

    // MARK: - What must not be refused

    /// Every rectangle a real server sends. A full-screen update of the largest
    /// desktop this client will hold is exactly at the line, on purpose: the
    /// two ceilings are the same number, so a legal screen can always be
    /// painted in one rectangle.
    func testTheRectanglesRealServersSendAreAccepted() {
        for (width, height) in [(1, 1), (16, 16), (640, 480), (1920, 1080), (3840, 2160),
                                (7680, 4320), (8192, 8192)] {
            XCTAssertNoThrow(
                try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: width, height: height)),
                "\(width)×\(height) devrait passer")
        }
    }

    /// An empty rectangle is an ordinary thing to receive and must not be
    /// mistaken for an attack.
    func testAnEmptyRectangleIsAccepted() {
        XCTAssertNoThrow(try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 0, height: 0)))
    }

    /// The two ceilings agree, which is what makes the sentence above true.
    func testAFullScreenRectangleIsExactlyAtTheCeiling() {
        let side = 8192  // 8192² = 64 Mpx
        XCTAssertTrue(Framebuffer.canHold(width: side, height: side))
        XCTAssertNoThrow(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: side, height: side)))
    }

    // MARK: - The backstop underneath

    /// `Framebuffer.copy` refuses on its own, for the caller that forgets to
    /// ask — the same pair as `resize` and its session-level refusal.
    func testTheFramebufferRefusesToCopyWhatItCannotHold() {
        let framebuffer = Framebuffer(width: 64, height: 64)
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: 0, y: 0, width: 65535, height: 65535))
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 64 * 64 * 4, "l'écran est intact")
    }

    /// And the control, so the test above is not satisfied by a `copy` that
    /// does nothing at all: an ordinary CopyRect still moves pixels.
    func testAnOrdinaryCopyStillMovesPixels() {
        let framebuffer = Framebuffer(width: 4, height: 2)
        framebuffer.write(
            rect: Rect(x: 0, y: 0, width: 2, height: 1),
            bgra: [1, 2, 3, 255, 4, 5, 6, 255])
        framebuffer.copy(from: Point(x: 0, y: 0), to: Rect(x: 0, y: 1, width: 2, height: 1))
        // Row stride is 4 pixels, so the second row starts at byte 16.
        let pixels = framebuffer.snapshot().pixels
        XCTAssertEqual(Array(pixels[16..<24]), [1, 2, 3, 255, 4, 5, 6, 255])
    }

    /// The derived ceiling, now that it is derived from something bounded.
    /// Before the rectangle had a ceiling this returned over seventeen
    /// gigabytes, which is the whole point: a bound computed from the
    /// attacker's number is not a bound.
    func testTheCompressedCeilingIsBoundedBecauseTheRectangleIs() {
        let largest = Rect(x: 0, y: 0, width: 8192, height: 8192)
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 65535, height: 65535)))
        XCTAssertNoThrow(try RFBLimits.requirePaintableRect(largest))
        XCTAssertEqual(
            RFBLimits.maximumCompressedBytes(for: largest), Framebuffer.maximumPixels * 4 + (1 << 20))
        XCTAssertLessThan(RFBLimits.maximumCompressedBytes(for: largest), 1 << 29)
    }
}
