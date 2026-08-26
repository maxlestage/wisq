import Foundation
import WisqCore
import WisqNet
import XCTest

@testable import WisqRemote

/// The desktop geometry, at the two doors it arrives by — and the one that had
/// no lock.
///
/// I opened this expecting to find nothing between `ServerInit` and a
/// seventeen-gigabyte allocation. **That was wrong, and sabotage is what said
/// so:** removing my new check at the handshake left the suite green, because
/// `performInitialisation` had bounded the geometry all along, at 16384 a side.
/// I had read the first two lines of that function and stopped.
///
/// What was actually missing is the *other* door. A `desktopSize` rectangle
/// resizes a live session, a server may send one whenever it likes, and that
/// path was bounded by nothing. 65535 × 65535 × 4 is about seventeen gigabytes;
/// on a phone that is not an error, it is the app disappearing.
///
/// Two other things follow from looking properly. The handshake's own ceiling
/// was 16384 a side — roughly a gigabyte, and **four times looser** than what
/// `SpiceSurfaces` allows itself for the same kind of allocation. And
/// `Framebuffer`, which does the allocating, had no opinion at all. There is
/// one number now, `Framebuffer.maximumPixels`, read by both protocols and
/// checked at both doors, with the framebuffer refusing to allocate as a
/// backstop underneath.
///
/// **No test here allocates anything large.** They assert the refusal — a test
/// that actually built the seventeen gigabytes would demonstrate the bug rather
/// than the fix.
final class DesktopSizeCeilingTests: XCTestCase {
    // MARK: - What must be refused

    func testTheLargestDesktopTheWireCanNameIsRefused() {
        XCTAssertThrowsError(
            try VNCSession.requireHoldableDesktop(width: 65535, height: 65535))
    }

    /// Just past the line, and by each side separately: a guard that only
    /// checked the product would pass a 1 × 70_000_000 desktop, and one that
    /// only checked the sides would pass 65535 × 65535.
    func testJustPastTheCeilingIsRefusedByProductAndBySide() {
        XCTAssertThrowsError(
            try VNCSession.requireHoldableDesktop(
                width: Framebuffer.maximumPixels + 1, height: 1))
        XCTAssertThrowsError(
            try VNCSession.requireHoldableDesktop(
                width: 1, height: Framebuffer.maximumPixels + 1))
        XCTAssertThrowsError(
            try VNCSession.requireHoldableDesktop(width: 8193, height: 8193))
    }

    /// The refusal names the size, because the alternative is a session that
    /// stops with nothing to tell the user.
    func testTheRefusalSaysWhichDesktop() {
        do {
            try VNCSession.requireHoldableDesktop(width: 65535, height: 65535)
            XCTFail("aurait dû refuser")
        } catch {
            XCTAssertTrue("\(error)".contains("65535×65535"), "\(error)")
        }
    }

    /// A width so large that `width * height` leaves an `Int`.
    ///
    /// Found by sabotage: dropping the per-side clauses and keeping only the
    /// product left every test above green, because `maximumPixels + 1` times
    /// one is still past the product ceiling. The clause earns its place
    /// somewhere else entirely — it is what makes the product **safe to
    /// compute** before it is compared. Not reachable from RFB, whose sides are
    /// `UInt16`; reachable through `Framebuffer.canHold`, which is public.
    func testAGeometryThatWouldOverflowIsRefusedBeforeItIsMultiplied() {
        XCTAssertFalse(Framebuffer.canHold(width: Int.max, height: 2))
        XCTAssertFalse(Framebuffer.canHold(width: 2, height: Int.max))
        XCTAssertThrowsError(try VNCSession.requireHoldableDesktop(width: Int.max, height: 2))
    }

    // MARK: - Through a real handshake

    /// The handshake's refusal, driven end to end.
    ///
    /// This one passed before the slice too — `performInitialisation` already
    /// refused, with its own looser bound. What it pins now is that the two
    /// doors answer with the same number, and it asserts the **reason** rather
    /// than the failure: without any check the session dies a moment later for
    /// want of bytes, so "did it fail" would have been green either way.
    func testAServerAnnouncingAnImpossibleDesktopEndsTheSession() async throws {
        var built = Data("RFB 003.008\n".utf8)
        built.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        built.append(contentsOf: [0, 0, 0, 0])
        built.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // 65535×65535
        built.append(PixelFormat.bgra32.encoded)
        built.append(contentsOf: [0, 0, 0, 4])
        built.append(contentsOf: Array("wisq".utf8))

        let script = built
        let framebuffer = Framebuffer(width: 0, height: 0)
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            framebuffer: framebuffer,
            streamProvider: { [script] _ in MemoryByteStream(inbound: script) })

        // The reason matters, not just the failure. Without the check the
        // session does not survive this script either — it runs out of bytes a
        // moment later — so a test that only asked "did it fail" would pass for
        // a client that had already tried to allocate seventeen gigabytes.
        var reason: String?
        await session.start()
        for await event in session.events {
            if case .disconnected(let error) = event, let error { reason = "\(error)" }
        }
        let said = try XCTUnwrap(reason, "la session ne s'est pas arrêtée du tout")
        XCTAssertTrue(said.contains("65535×65535"), "arrêtée, mais pour une autre raison : \(said)")
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 0, "et n'a rien alloué")
    }

    /// The second door, which is the one a server can knock on repeatedly.
    ///
    /// The handshake happens once; `desktopSize` rectangles arrive whenever the
    /// server says so. Found by sabotage: removing the check from the resize
    /// path left everything green, because `Framebuffer` still refused to
    /// allocate — the session simply carried on with an empty screen and told
    /// nobody why.
    func testAResizeToAnImpossibleDesktopEndsTheSession() async throws {
        var built = Data("RFB 003.008\n".utf8)
        built.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        built.append(contentsOf: [0, 0, 0, 0])
        built.append(contentsOf: [0x02, 0x80, 0x01, 0xE0])  // 640×480, tenable
        built.append(PixelFormat.bgra32.encoded)
        built.append(contentsOf: [0, 0, 0, 4])
        built.append(contentsOf: Array("wisq".utf8))
        // Puis une mise à jour d'un rectangle : desktopSize, 65535×65535.
        built.append(contentsOf: [0, 0, 0, 1])
        built.append(contentsOf: [0, 0, 0, 0])
        built.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        built.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x21])  // encodage -223
        let script = built

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
        let said = try XCTUnwrap(reason, "la session a continué après un redimensionnement impossible")
        XCTAssertTrue(said.contains("65535×65535"), "arrêtée, mais pour une autre raison : \(said)")
    }

    /// The control at the same level: the identical script with an ordinary
    /// desktop gets through. Without it, a session that failed on everything
    /// would satisfy the test above.
    func testTheSameHandshakeWithAnOrdinaryDesktopSucceeds() async {
        var built = Data("RFB 003.008\n".utf8)
        built.append(contentsOf: [1, RFB.SecurityType.none.rawValue])
        built.append(contentsOf: [0, 0, 0, 0])
        built.append(contentsOf: [0x02, 0x80, 0x01, 0xE0])  // 640×480
        built.append(PixelFormat.bgra32.encoded)
        built.append(contentsOf: [0, 0, 0, 4])
        built.append(contentsOf: Array("wisq".utf8))

        let script = built
        let framebuffer = Framebuffer(width: 0, height: 0)
        let session = VNCSession(
            configuration: SessionConfiguration(host: "10.0.0.5", port: 5900),
            framebuffer: framebuffer,
            streamProvider: { [script] _ in MemoryByteStream(inbound: script) })

        var ready = false
        await session.start()
        for await event in session.events {
            if case .ready = event { ready = true }
        }
        XCTAssertTrue(ready, "un bureau de 640×480 doit passer")
        XCTAssertEqual(framebuffer.size.width, 640)
    }

    // MARK: - What must not be

    /// The other edge, and the one that decides whether the ceiling is usable:
    /// every desktop anyone would really connect to has to pass. 8K is
    /// thirty-three megapixels, half the line.
    func testTheDesktopsPeopleActuallyUseAreAccepted() throws {
        for (width, height) in [
            (640, 480), (1920, 1080), (2560, 1600), (3840, 2160), (7680, 4320), (5120, 2880),
        ] {
            XCTAssertNoThrow(
                try VNCSession.requireHoldableDesktop(width: width, height: height),
                "\(width)×\(height) devrait passer")
        }
    }

    /// A zero-sized desktop is what a server sends before it has one, and it
    /// must not be mistaken for an attack.
    func testAnEmptyDesktopIsAccepted() {
        XCTAssertNoThrow(try VNCSession.requireHoldableDesktop(width: 0, height: 0))
    }

    /// Exactly at the line, on both sides of it.
    func testTheBoundaryItselfIsAccepted() {
        XCTAssertNoThrow(
            try VNCSession.requireHoldableDesktop(width: Framebuffer.maximumPixels, height: 1))
        XCTAssertNoThrow(try VNCSession.requireHoldableDesktop(width: 8192, height: 8192))
    }

    // MARK: - The backstop underneath

    /// `Framebuffer` refuses to allocate it either way. The session's refusal
    /// is the loud half; this is the half that survives a future caller who
    /// forgets to ask.
    func testTheFramebufferRefusesToAllocateWhatItCannotHold() {
        let framebuffer = Framebuffer(width: 65535, height: 65535)
        XCTAssertEqual(framebuffer.size.width, 0, "la géométrie démesurée a été allouée")
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 0)
    }

    func testResizingPastTheCeilingLeavesNothingAllocated() {
        let framebuffer = Framebuffer(width: 64, height: 64)
        framebuffer.resize(width: 65535, height: 65535)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 0)
    }

    /// And the control, so the two above are not satisfied by a framebuffer
    /// that allocates nothing at all: an ordinary desktop is held in full.
    func testAnOrdinaryDesktopIsStillAllocated() {
        let framebuffer = Framebuffer(width: 64, height: 32)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 64 * 32 * 4)
        framebuffer.resize(width: 128, height: 16)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 128 * 16 * 4)
    }

    /// One ceiling, two protocols. SPICE has had its own since the surfaces
    /// slice; the number is now shared rather than written twice, which is the
    /// only reason RFB's absence was possible to miss.
    func testSPICEAndRFBShareTheSameCeiling() {
        XCTAssertEqual(SpiceSurfaces.maximumPixels, Framebuffer.maximumPixels)
    }
}
