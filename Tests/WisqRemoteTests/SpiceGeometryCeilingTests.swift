import Foundation
import WisqCore
import XCTest

@testable import WisqRemote

/// Three SPICE codecs, three answers to the same question.
///
/// Each of them takes a width and a height from the network and allocates from
/// the product. `SpiceSurfaces` has capped that since the slice on unreasonable
/// sizes, and `Framebuffer` and RFB joined it in the two slices before this
/// one. The codecs did not — and, measured one at a time:
///
/// | codec | par côté | produit | mesuré avant |
/// | --- | --- | --- | --- |
/// | LZ4 | 32768 | **oui** | refuse 32768² |
/// | QUIC | 32768 | non | **4,03 Gio résidents** |
/// | LZ (alpha) | aucun | non | `failed to allocate 17179869216 bytes` |
/// | LZ (simple) | aucun | non | **4 Gio réservés**, puis `truncated` |
///
/// The QUIC figure is a peak resident set that really grew, from 36 MiB, off a
/// twenty-byte header. The plain-LZ figure is peak *address space* rather than
/// resident: `reserveCapacity` maps without touching, so the pages never fault
/// in, and saying "4 GiB allocated" of that one would be overstating what was
/// observed. Both are refused now; they are not the same failure and are not
/// described as though they were.
///
/// The finding is `SpiceLZ4`'s comment, which claimed "the cap is the same one
/// the other codecs here use". It was the only one with both halves. And its
/// `1 << 28` was never a different number from the shared ceiling, only a
/// different unit — bytes rather than pixels.
///
/// **No test here allocates anything large.** They assert the refusal.
final class SpiceGeometryCeilingTests: XCTestCase {
    // MARK: - Helpers

    private func quicHeader(_ width: Int32, _ height: Int32) -> [UInt8] {
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

    /// Big-endian, unlike QUIC's next door — the two codecs disagree, and the
    /// file says so.
    private func lzHeader(type: UInt32, _ width: Int32, _ height: Int32) -> [UInt8] {
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

    private func lzGeometryIsRefused(_ payload: [UInt8], _ message: String) {
        do {
            _ = try SpiceLZ.decompress(payload)
            XCTFail(message)
        } catch SpiceLZ.Failure.badGeometry {
            // Attendu.
        } catch {
            XCTFail("\(message) — refusé, mais pour une autre raison : \(error)")
        }
    }

    // MARK: - What must be refused

    /// The one that was measured at 4.03 GiB resident. Both sides legal under
    /// the old per-side bound, the product four gigabytes.
    func testQUICRefusesAProductThatEachSidePasses() {
        XCTAssertLessThanOrEqual(32768, 1 << 15, "les deux côtés passaient l'ancienne borne")
        do {
            _ = try SpiceQUIC.decode(quicHeader(32768, 32768))
            XCTFail("32768×32768 aurait dû être refusé")
        } catch SpiceQUIC.Failure.badGeometry {
            // Attendu.
        } catch {
            XCTFail("refusé, mais pour une autre raison : \(error)")
        }
    }

    /// LZ's guard refused the sign and nothing else. A positive pair multiplies
    /// just as enormously — this is the plain path, and the one below is the
    /// alpha path, which is a separate entry point with its own allocation.
    func testLZRefusesAPositivePairThatIsStillEnormous() {
        lzGeometryIsRefused(lzHeader(type: 8, 32768, 32768), "LZ simple : 32768×32768")
        lzGeometryIsRefused(lzHeader(type: 8, 65536, 65536), "LZ simple : 65536×65536")
    }

    /// The alpha path is reached by its own function and used to allocate
    /// seventeen gigabytes before reading a byte of the stream.
    func testTheLZAlphaPathIsRefusedToo() {
        do {
            _ = try SpiceLZ.decompressWithAlpha(lzHeader(type: 9, 65536, 65536))
            XCTFail("le chemin alpha aurait dû refuser 65536×65536")
        } catch SpiceLZ.Failure.badGeometry {
            // Attendu.
        } catch {
            XCTFail("refusé, mais pour une autre raison : \(error)")
        }
    }

    /// And LZ4, which already refused it — pinned so that bringing the three
    /// into line did not quietly loosen the one that was right.
    func testLZ4StillRefusesWhatItAlwaysRefused() {
        XCTAssertThrowsError(
            try SpiceLZ4.decode([0, 8] + [UInt8](repeating: 0, count: 16), width: 32768, height: 32768))
    }

    /// The case that separates LZ4's two old guards, and the reason only one of
    /// them survived.
    ///
    /// Found by sabotage: removing either of LZ4's bounds left the suite green,
    /// because at four bytes a pixel each implies the other. They part company
    /// below that. 10000 × 10000 is a hundred megapixels — over the shared
    /// ceiling — but at **two** bytes a pixel it is 200 MiB, which the old
    /// `total <= 1 << 28` byte cap waved through. The pixel count is what
    /// protects this; the byte cap could never fire, and is gone.
    func testASixteenBitImageIsJudgedOnPixelsAndNotOnBytes() {
        let pixels = 10000 * 10000
        XCTAssertFalse(Framebuffer.canHold(width: 10000, height: 10000))
        XCTAssertLessThan(pixels * 2, 1 << 28, "l'ancien plafond en octets laissait passer celle-ci")
        // Format 0x08 est le seize bits ; deux octets par pixel.
        XCTAssertThrowsError(
            try SpiceLZ4.decode(
                [0, SpiceDisplayWire.BitmapFormat.sixteenBit.rawValue]
                    + [UInt8](repeating: 0, count: 16),
                width: 10000, height: 10000))
    }

    /// Negative sides still mean what they meant: the sign guard was not
    /// replaced by the magnitude one, it was joined by it.
    ///
    /// Sabotage found that this test alone does not hold the sign guard:
    /// deleting it left the suite green, because `canHold` refuses a negative
    /// side too — `width >= 0` is the first thing it asks. Real equivalence,
    /// for negatives. What the sign guard still covers on its own is below.
    func testANegativeSideIsStillRefused() {
        lzGeometryIsRefused(lzHeader(type: 8, -1, 16), "LZ : largeur négative")
        lzGeometryIsRefused(lzHeader(type: 8, 16, -1), "LZ : hauteur négative")
    }

    /// What only LZ's own guard refuses.
    ///
    /// `canHold` admits a zero side, deliberately — an empty screen is a thing
    /// a server sends — and it has no opinion at all about the stride, which is
    /// not one of its two arguments. So this codec's `width > 0, height > 0,
    /// stride >= 0` is not redundant; the half of it that looked redundant was
    /// only the negative case.
    func testTheThingsOnlyLZsOwnGuardRefuses() {
        lzGeometryIsRefused(lzHeader(type: 8, 0, 16), "LZ : largeur nulle")
        lzGeometryIsRefused(lzHeader(type: 8, 16, 0), "LZ : hauteur nulle")
        XCTAssertTrue(
            Framebuffer.canHold(width: 0, height: 16),
            "et le plafond partagé, lui, accepte le zéro — d'où la garde propre au codec")

        var negativeStride = lzHeader(type: 8, 16, 16)
        // Le stride est le sixième mot de l'en-tête, en gros-boutien.
        negativeStride.replaceSubrange(20..<24, with: [0xFF, 0xFF, 0xFF, 0xFF])
        lzGeometryIsRefused(negativeStride, "LZ : stride négatif")
    }

    // MARK: - One number, not three that agree

    /// `1 << 28` bytes and 64 Mpx are the same ceiling in different units. This
    /// is what made the difference between the codecs invisible.
    func testTheByteCeilingAndThePixelCeilingAreOneNumber() {
        XCTAssertEqual(Framebuffer.maximumPixels * 4, 1 << 28)
        XCTAssertEqual(SpiceSurfaces.maximumPixels, Framebuffer.maximumPixels)
    }

    /// Every geometry the three codecs accept, they accept together. A ceiling
    /// that differs per codec is how this happened in the first place.
    func testTheThreeCodecsAgreeOnWhereTheLineIs() {
        for (width, height) in [(8192, 8193), (32768, 32768), (65535, 65535), (1, 1 << 27)] {
            XCTAssertFalse(
                Framebuffer.canHold(width: width, height: height),
                "\(width)×\(height) est au-delà du plafond partagé")
            XCTAssertThrowsError(
                try SpiceQUIC.decode(quicHeader(Int32(width), Int32(height))),
                "QUIC devrait refuser \(width)×\(height)")
            lzGeometryIsRefused(
                lzHeader(type: 8, Int32(width), Int32(height)), "LZ devrait refuser \(width)×\(height)")
        }
    }

    // MARK: - What must not be refused

    /// The other edge, and the one that decides whether the ceiling is usable.
    /// A SPICE image is a piece of a screen, so these are already generous.
    func testTheImagesRealServersSendAreAccepted() {
        for (width, height) in [(1, 1), (64, 64), (1920, 1080), (3840, 2160), (7680, 4320)] {
            XCTAssertTrue(
                Framebuffer.canHold(width: width, height: height),
                "\(width)×\(height) devrait passer")
        }
    }

    /// Accepted geometry must fail for a *stream* reason, not a geometry one —
    /// otherwise a codec that refused everything would satisfy the tests above.
    func testAnOrdinaryGeometryGetsPastTheCeiling() {
        do {
            _ = try SpiceQUIC.decode(quicHeader(64, 64))
            // Décoder pour de bon serait une surprise avec cette charge utile.
        } catch SpiceQUIC.Failure.badGeometry {
            XCTFail("64×64 ne doit pas être refusé pour sa géométrie")
        } catch {
            // Toute autre erreur est attendue : la charge utile n'est pas un
            // vrai flux QUIC.
        }

        do {
            _ = try SpiceLZ.decompress(lzHeader(type: 8, 64, 64))
        } catch SpiceLZ.Failure.badGeometry {
            XCTFail("64×64 ne doit pas être refusé pour sa géométrie")
        } catch {
            // Idem : `truncated` est la bonne réponse ici.
        }
    }

    /// The largest image the client will hold is exactly at the line, on
    /// purpose: the codecs and the framebuffer share one number, so a legal
    /// screen can always arrive as one image.
    func testTheBoundaryItselfIsAccepted() {
        XCTAssertTrue(Framebuffer.canHold(width: 8192, height: 8192))
        do {
            _ = try SpiceLZ.decompress(lzHeader(type: 8, 8192, 8192))
        } catch SpiceLZ.Failure.badGeometry {
            XCTFail("8192×8192 est exactement le plafond et doit passer")
        } catch {
            // Attendu : le flux est tronqué, pas la géométrie refusée.
        }
    }
}
