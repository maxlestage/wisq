import Foundation
import WisqCore
import XCTest

@testable import WisqRemote

/// The audit that closes: every allocation this client sizes from a number a
/// server chose, and what holds it.
///
/// Three slices built this — the desktop, the rectangles that paint on it, and
/// the three compressed codecs. Each found the same shape, and the shape is not
/// "a missing guard". It is **a ceiling written separately that happened to
/// agree**. QUIC's per-side bound, LZ4's byte cap and the framebuffer's pixel
/// cap were all "32768" or "1 << 28" or "64 << 20" in three files, and because
/// they agreed at four bytes a pixel nobody had to notice that one of them was
/// missing half the rule.
///
/// So this file is not more of the same tests. It is the audit *as something
/// that runs*, and it holds two things prose cannot:
///
///   * every ceiling in the program is **the one number**, or is deliberately
///     smaller and pinned to stay smaller;
///   * the paths that are **not** ceiling-bounded are byte-gated, and refuse
///     for that reason rather than by accident.
///
/// That second one is the distinction the whole audit rests on. A path that
/// refuses because the bytes never arrive is safe for a different reason than
/// one that refuses because the geometry is absurd, and a test that only asked
/// "did it throw" would call them the same thing.
///
/// **What is not here, and why.** `ByteStream.pad(_:)` sizes a buffer from a
/// count, and is a *writer* — the number is wisq's own, going out. It is not an
/// attack surface and adding it to this table would say it was one.
final class AllocationCeilingAuditTests: XCTestCase {
    // MARK: - One number

    /// Every ceiling that is meant to be the shared one, is.
    func testTheProtocolsShareOneCeiling() {
        XCTAssertEqual(SpiceSurfaces.maximumPixels, Framebuffer.maximumPixels)
        XCTAssertEqual(Framebuffer.maximumPixels * 4, 1 << 28)
        // RFB reads it directly rather than keeping a copy; this is what says
        // so, and it fails if a copy is ever introduced that drifts.
        XCTAssertNoThrow(
            try RFBLimits.requirePaintableRect(
                Rect(x: 0, y: 0, width: Framebuffer.maximumPixels, height: 1)))
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(
                Rect(x: 0, y: 0, width: Framebuffer.maximumPixels + 1, height: 1)))
    }

    /// The one ceiling that is deliberately different, pinned by its direction
    /// rather than its value.
    ///
    /// A glyph mask is a line of text. Holding it *equal* to the shared number
    /// would be wrong — it should be far smaller — so what is held is that it
    /// never becomes the larger of the two.
    func testTheGlyphMaskCeilingIsTighterAndStaysTighter() {
        XCTAssertLessThan(SpiceGlyphMask.maximumPixels, Framebuffer.maximumPixels)
    }

    // MARK: - The table

    /// Every entry point that takes a geometry off the wire refuses the same
    /// absurd one. The value of the table is that a codec added later is either
    /// in it or conspicuously absent.
    func testEveryGeometryEntryPointRefusesTheSameAbsurdSize() {
        // RFB: the desktop, and a rectangle painted on it.
        XCTAssertThrowsError(try VNCSession.requireHoldableDesktop(width: 65535, height: 65535))
        XCTAssertThrowsError(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 65535, height: 65535)))

        // SPICE: a surface, and the three compressed codecs.
        XCTAssertFalse(Framebuffer.canHold(width: 65535, height: 65535))
        XCTAssertThrowsError(try SpiceQUIC.decode(Self.quicHeader(65535, 65535)))
        XCTAssertThrowsError(try SpiceLZ.decompress(Self.lzHeader(type: 8, 65535, 65535)))
        XCTAssertThrowsError(
            try SpiceLZ4.decode(
                [0, 8] + [UInt8](repeating: 0, count: 16), width: 65535, height: 65535))

        // And the framebuffer underneath them all, which allocates.
        let framebuffer = Framebuffer(width: 65535, height: 65535)
        XCTAssertEqual(framebuffer.snapshot().pixels.count, 0)
    }

    /// And the same table from the other edge: an ordinary desktop passes every
    /// one of them. Without this, a client that refused everything would be
    /// indistinguishable from a correct one.
    func testEveryEntryPointAcceptsAnOrdinaryDesktop() {
        XCTAssertNoThrow(try VNCSession.requireHoldableDesktop(width: 1920, height: 1080))
        XCTAssertNoThrow(
            try RFBLimits.requirePaintableRect(Rect(x: 0, y: 0, width: 1920, height: 1080)))
        XCTAssertTrue(Framebuffer.canHold(width: 1920, height: 1080))
        XCTAssertEqual(Framebuffer(width: 64, height: 64).snapshot().pixels.count, 64 * 64 * 4)

        // The codecs get past the ceiling and fail on the stream instead, which
        // is the next test's subject.
        XCTAssertFalse(Self.refusedForGeometry(SpiceQUIC.decode, Self.quicHeader(1920, 1080)))
        XCTAssertFalse(
            Self.refusedForGeometry(SpiceLZ.decompress, Self.lzHeader(type: 8, 1920, 1080)))
    }

    // MARK: - Bounded, or byte-gated — not the same thing

    /// The paths with no ceiling of their own are safe because the server has
    /// to actually send the pixels, and this asserts they fail for **that**
    /// reason.
    ///
    /// A legal geometry with a stream that stops early must come back
    /// `truncated`, not `badGeometry`. If one of these ever started refusing on
    /// geometry it would mean a ceiling had been added without being written
    /// into the table above; if it started *succeeding*, the byte gate had
    /// gone.
    func testTheUngatedPathsRefuseForLackOfBytesRatherThanGeometry() {
        do {
            _ = try SpiceLZ.decompress(Self.lzHeader(type: 8, 640, 480))
            XCTFail("un flux tronqué doit être refusé")
        } catch SpiceLZ.Failure.truncated {
            // Attendu : la géométrie est légale, ce sont les octets qui manquent.
        } catch SpiceLZ.Failure.badGeometry {
            XCTFail("640×480 est une géométrie légale : le refus doit venir des octets")
        } catch {
            XCTFail("refusé, mais pour une autre raison : \(error)")
        }
    }

    /// RFB's compressed encodings bound their payload against the rectangle —
    /// a ceiling *derived* from a number the server chose, which is only a
    /// bound because the rectangle itself is bounded first. This pins the
    /// relationship rather than the number.
    func testTheDerivedCeilingIsBoundedBecauseTheRectangleIs() {
        let largest = Rect(x: 0, y: 0, width: 8192, height: 8192)
        XCTAssertNoThrow(try RFBLimits.requirePaintableRect(largest))
        XCTAssertEqual(
            RFBLimits.maximumCompressedBytes(for: largest),
            Framebuffer.maximumPixels * 4 + (1 << 20))
        // Before the rectangle had a ceiling this was over seventeen gigabytes.
        XCTAssertLessThan(RFBLimits.maximumCompressedBytes(for: largest), 1 << 29)
    }

    // MARK: - Fixtures

    private static func quicHeader(_ width: Int32, _ height: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        for word: UInt32 in [
            0x4349_5551, 0, 4, UInt32(bitPattern: width), UInt32(bitPattern: height),
        ] {
            bytes.append(contentsOf: [
                UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF),
                UInt8((word >> 16) & 0xFF), UInt8((word >> 24) & 0xFF),
            ])
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 64))
        return bytes
    }

    private static func lzHeader(type: UInt32, _ width: Int32, _ height: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        func be(_ word: UInt32) {
            bytes.append(contentsOf: [
                UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
                UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
            ])
        }
        be(SpiceLZ.magic)
        be(SpiceLZ.versionMajor << 16 | SpiceLZ.versionMinor)
        be(type)
        be(UInt32(bitPattern: width))
        be(UInt32(bitPattern: height))
        be(0)
        be(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return bytes
    }

    /// Whether a decoder refused this payload *for its geometry*, as opposed to
    /// getting past the ceiling and failing on the stream.
    private static func refusedForGeometry<T>(
        _ decode: ([UInt8]) throws -> T, _ payload: [UInt8]
    ) -> Bool {
        do {
            _ = try decode(payload)
            return false
        } catch let error as SpiceLZ.Failure {
            return error == .badGeometry
        } catch let error as SpiceQUIC.Failure {
            if case .badGeometry = error { return true }
            return false
        } catch {
            return false
        }
    }
}
