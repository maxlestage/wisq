import XCTest
@testable import WisqRemote

/// What the client says to the display channel.
///
/// The interesting assertions here are not about byte layout. They are about a
/// decision: wisq decodes LZ and nothing else, so it must *ask* for LZ, and
/// the tests below pin the two ways that can go wrong — asking a server that
/// cannot be asked, and asking for a mode that lets the server send something
/// else anyway.
final class SpiceDisplayClientTests: XCTestCase {
    /// A capability is a bit index, not a value. Read as a value, capability 6
    /// would be "the word equals 6" and every check would be wrong in a way
    /// that happens to be right for capability 1 and 2.
    func testACapabilityIsABitPositionRatherThanAValue() {
        // Bit 6 set, and nothing else.
        XCTAssertTrue(SpiceDisplayClient.supports(.preferredCompression, in: [0b0100_0000]))
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: [6]))
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: [0b0010_0000]))

        // And each capability is its own bit, not a shared one.
        let words = SpiceDisplayClient.capabilityWords([.preferredCompression, .sizedStream])
        XCTAssertEqual(words, [0b0100_0001])
        XCTAssertTrue(SpiceDisplayClient.supports(.sizedStream, in: words))
        XCTAssertTrue(SpiceDisplayClient.supports(.preferredCompression, in: words))
        XCTAssertFalse(SpiceDisplayClient.supports(.composite, in: words))
    }

    /// A server that advertises nothing, or fewer words than the capability
    /// needs, must read as "no" rather than as an index past the end.
    func testAServerThatSaysNothingSupportsNothing() {
        XCTAssertFalse(SpiceDisplayClient.supports(.preferredCompression, in: []))
        XCTAssertFalse(SpiceDisplayClient.supports(.multiCodec, in: []))
        XCTAssertNil(SpiceDisplayClient.compressionToRequest(givenServerCapabilities: []))
    }

    /// The decision this whole file exists for. A server left to its own
    /// default sends whatever it likes; asking is what turns finished codecs
    /// into a picture.
    ///
    /// It asked for plain `lz`, then `autoLZ` when QUIC was decoded, and now
    /// `autoGLZ`. Both automatic modes send QUIC for a high-graduality bitmap
    /// and differ only in the fallback, so this is the choice of what a desktop
    /// gets for its widgets and text: LZ starting fresh at every image, or GLZ
    /// matching across the whole channel.
    func testAServerThatCanBeAskedIsAskedForAutomaticGLZ() {
        let caps = SpiceDisplayClient.capabilityWords([.preferredCompression])
        XCTAssertEqual(
            SpiceDisplayClient.compressionToRequest(givenServerCapabilities: caps), .autoGLZ
        )
        XCTAssertEqual(SpiceDisplayClient.preferredCompression(.autoGLZ), [2])
    }

    /// **Asking for `autoGLZ` is only safe because the window is real**, and
    /// this is the test that ties the two together so neither can be changed
    /// back on its own.
    ///
    /// The reference encoder aborts the server — `usr->error` in
    /// `glz_dictionary_window_get_new_head`, which is `spice_critical`, which
    /// is `abort()` — for any image larger than the declared window. So a
    /// preference that can produce GLZ and a window that cannot hold a frame
    /// are individually defensible and jointly fatal.
    func testAskingForGLZRequiresAWindowThatCanHoldAFrame() {
        let caps = SpiceDisplayClient.capabilityWords([.preferredCompression])
        let asked = SpiceDisplayClient.compressionToRequest(givenServerCapabilities: caps)
        let canProduceGLZ = asked == .autoGLZ || asked == .glz
        if canProduceGLZ {
            XCTAssertGreaterThanOrEqual(
                SpiceDisplayClient.glzWindowPixels, 3840 * 2160,
                "demander GLZ avec une fenêtre trop petite fait abandonner le serveur"
            )
        }
    }

    /// The init message the server waits for before it draws anything.
    ///
    /// The window here is `0x0A0B_0C0D` rather than a round number because the
    /// field is a little-endian `int32` and four equal bytes — zero above all —
    /// agree with every byte order there is. This test used to pass zero.
    func testTheInitMessageIsLaidOutAsTheProtocolStatesIt() {
        let body = SpiceDisplayClient.initialise(
            pixmapCacheID: 1, pixmapCachePixels: 0x0102_0304,
            glzDictionaryID: 2, glzWindowPixels: 0x0A0B_0C0D
        )
        // uint8, int64 little-endian, uint8, int32 little-endian.
        XCTAssertEqual(body.count, 1 + 8 + 1 + 4)
        XCTAssertEqual(body[0], 1)
        XCTAssertEqual(Array(body[1...8]), [0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0])
        XCTAssertEqual(body[9], 2)
        XCTAssertEqual(Array(body[10...13]), [0x0D, 0x0C, 0x0B, 0x0A])
    }

    /// **The GLZ window has to hold one whole frame, or the server dies.**
    ///
    /// This asserted the opposite — that the window is zero — with the reason
    /// "wisq does not decode GLZ". That reason had already stopped being true,
    /// and the value it defended was never the harmless one it looked like:
    /// `glz_dictionary_window_get_new_head` calls `usr->error` for any image
    /// bigger than the window, `glz_usr_error` calls `spice_critical`, and that
    /// calls `abort()`. Zero is not a small window. It is a dead server on the
    /// first GLZ image, and `scripts/spice-glz-window/` shows the boundary: a
    /// 64×64 image is clean at 4096 pixels and aborts at 4095.
    ///
    /// So the floor is the largest frame a guest might send, not a judgement
    /// about how much history is useful — the resolution is not known when this
    /// message goes out.
    func testTheGLZWindowHoldsAWholeFrameBecauseASmallerOneAbortsTheServer() {
        let declared = SpiceDisplayClient.glzWindowPixels
        for (width, height, name) in [
            (1_920, 1_080, "1080p"), (2_560, 1_440, "1440p"), (3_840, 2_160, "2160p"),
        ] {
            XCTAssertGreaterThanOrEqual(declared, Int32(width * height), name)
        }
        // `LZ_MAX_WINDOW_SIZE` in `lz_common.h`. Above it
        // `glz_dictionary_window_create` returns FALSE and the dictionary is
        // never built, which is its own kind of broken.
        XCTAssertLessThanOrEqual(declared, 1 << 25)

        let body = SpiceDisplayClient.initialise()
        XCTAssertEqual(
            Array(body.suffix(4)),
            (0..<4).map { UInt8(UInt32(bitPattern: declared) >> (8 * $0) & 0xFF) },
            "la valeur par défaut du message est bien la constante"
        )
        XCTAssertNotEqual(Array(body.suffix(4)), [0, 0, 0, 0])
    }

    /// **The declared cache and the cache that exists are one promise.**
    ///
    /// This test asserted zero, and it was right to: a number here tells the
    /// server it may send `SPICE_IMAGE_TYPE_FROM_CACHE` — an identifier and no
    /// pixels — and wisq had nothing to resolve one against, so those draws
    /// were skipped and the region kept stale pixels. It stopped being right
    /// when `SpicePixmapCache` arrived, and it failed on the commit that raised
    /// the number, which is the only reason to have written it that way.
    ///
    /// What it holds now is the pairing rather than a particular value: the
    /// number announced is the budget actually enforced. A server sizing itself
    /// against one bound while this client enforces another would evict on a
    /// schedule wisq does not share, and every divergence is a name that
    /// resolves to nothing.
    ///
    /// That the resolution *works* is held next door —
    /// `testAnImageSentOnceIsDrawnTwice` sends a picture once and draws it
    /// twice, and `testAnImageNamedFromTheCacheHasNoPixelsToDraw` shows what a
    /// name alone decodes to.
    func testTheDeclaredCacheIsTheBudgetActuallyEnforced() {
        XCTAssertGreaterThan(SpiceDisplayClient.pixmapCachePixels, 0)
        XCTAssertEqual(
            SpicePixmapCache().budgetPixels, Int(SpiceDisplayClient.pixmapCachePixels),
            "le nombre annoncé et le budget tenu sont le même engagement"
        )

        // Et il part bien dans le message, en petit-boutiste sur huit octets.
        let declared = UInt64(bitPattern: SpiceDisplayClient.pixmapCachePixels)
        XCTAssertEqual(
            Array(SpiceDisplayClient.initialise()[1...8]),
            (0..<8).map { UInt8(declared >> (8 * $0) & 0xFF) }
        )
    }

    /// The two sizes in `DISPLAY_INIT` are still not the same kind of promise,
    /// and the asymmetry outlived the zero.
    ///
    /// The GLZ window is a floor: below one frame the server calls `abort()`,
    /// so it is as large as any frame can be. The pixmap cache is a ceiling on
    /// what this client agrees to hold, and it is only safe to raise alongside
    /// something that holds it. Adjacent fields, same type, opposite failures.
    func testTheWindowAndTheCacheAreNotTheSameKindOfNumber() {
        XCTAssertGreaterThanOrEqual(
            SpiceDisplayClient.glzWindowPixels, 3_840 * 2_160,
            "la fenêtre est un plancher : une image entière"
        )
        XCTAssertGreaterThan(
            SpiceDisplayClient.pixmapCachePixels, 0,
            "le cache est un plafond, tenu par SpicePixmapCache"
        )
    }

    /// The message numbers, which are not sequential from one and are easy to
    /// transpose.
    func testTheMessageNumbersAreTheProtocolsOwn() {
        XCTAssertEqual(SpiceDisplayClient.Message.initialise.rawValue, 101)
        XCTAssertEqual(SpiceDisplayClient.Message.preferredCompression.rawValue, 103)
        XCTAssertEqual(SpiceDisplayClient.Compression.lz.rawValue, 6)
        XCTAssertEqual(SpiceDisplayClient.Compression.quic.rawValue, 4)
    }
}
