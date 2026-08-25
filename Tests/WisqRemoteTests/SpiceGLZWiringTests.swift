import XCTest
@testable import WisqNet
@testable import WisqRemote

/// `.glzRGB` on the display channel's own entry point.
///
/// The codec being right is one thing; the window surviving from one image to
/// the next is another, and it is the whole difference between GLZ and LZ. A
/// wiring that decoded each image against a fresh window would pass every
/// codec test in this repository and still show a wrong picture.
final class SpiceGLZWiringTests: XCTestCase {
    private func glzImage(_ fixture: SpiceGLZFixtures.Case) -> SpiceDisplayWire.Image {
        SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: fixture.id, type: .glzRGB, flags: 0,
                width: UInt32(SpiceGLZFixtures.width),
                height: UInt32(SpiceGLZFixtures.height)
            ),
            bitmap: nil, payload: SpiceGLZFixtures.bytes(fixture.stream)
        )
    }

    func testTheSequenceReachesTheDecoderThroughTheDisplayChannel() throws {
        var window = SpiceGLZ.Window()
        for (index, fixture) in SpiceGLZFixtures.sequence.enumerated() {
            let decoded = try XCTUnwrap(
                try SpiceDisplayWire.pixels(of: glzImage(fixture), glzWindow: &window),
                "image \(index) : rien dessiné, donc rien de branché"
            )
            XCTAssertEqual(decoded.width, SpiceGLZFixtures.width, "image \(index)")
            XCTAssertEqual(decoded.height, SpiceGLZFixtures.height, "image \(index)")
            XCTAssertEqual(
                decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded), "image \(index)"
            )
        }
    }

    /// **The window has to survive between images.** Decoding the same sequence
    /// with a window rebuilt each time must fail — if it did not, the window
    /// would be doing nothing and this wiring would be untested.
    func testAWindowRebuiltForEachImageCannotDecodeTheSequence() throws {
        var failed = false
        for fixture in SpiceGLZFixtures.sequence.dropFirst() {
            var fresh = SpiceGLZ.Window()
            if (try? SpiceDisplayWire.pixels(of: glzImage(fixture), glzWindow: &fresh)) == nil {
                failed = true
            }
        }
        XCTAssertTrue(failed, "sinon la fenêtre ne sert à rien et ce branchement ne teste rien")
    }

    /// Only GLZ images enter the window. An LZ image decoded through the same
    /// entry point must leave it untouched, or the ids collide with GLZ's and a
    /// later match resolves to the wrong picture.
    func testOnlyGLZImagesEnterTheWindow() throws {
        var window = SpiceGLZ.Window()
        let lz = SpiceLZFixtures.all[0]
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 0, type: .lzRGB, flags: 0,
                width: UInt32(lz.width), height: UInt32(lz.height)
            ),
            bitmap: nil, payload: bytes(lz.stream)
        )
        _ = try SpiceDisplayWire.pixels(of: image, glzWindow: &window)
        XCTAssertEqual(window.count, 0, "seul GLZ garnit la fenêtre")
    }

    /// `rgb16`, `rgb24` and `rgba` all reach the decoder through the channel.
    func testEveryHandledTypeReachesTheDecoder() throws {
        for (name, cases) in [
            ("rgb24", SpiceGLZFixtures.rgb24),
            ("rgb16", SpiceGLZFixtures.rgb16),
            ("rgba", SpiceGLZFixtures.rgba)
        ] {
            var window = SpiceGLZ.Window()
            for (index, fixture) in cases.enumerated() {
                let decoded = try XCTUnwrap(
                    try SpiceDisplayWire.pixels(of: glzImage(fixture), glzWindow: &window),
                    "\(name) image \(index)"
                )
                XCTAssertEqual(
                    decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded),
                    "\(name) image \(index)"
                )
            }
        }
    }

    /// A GLZ type this decoder does not handle yet answers "no pixels" rather
    /// than being run through a loop that would produce an image.
    func testAPaletteGLZTypeIsNotAttempted() throws {
        var window = SpiceGLZ.Window()
        var raw = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        raw[8] = 0x15                       // plt8, top_down
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 0, type: .glzRGB, flags: 0,
                width: UInt32(SpiceGLZFixtures.width),
                height: UInt32(SpiceGLZFixtures.height)
            ),
            bitmap: nil, payload: raw
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image, glzWindow: &window))
        XCTAssertEqual(window.count, 0, "et rien n'entre dans la fenêtre")
    }

    /// The message says a size and the stream says a size; a disagreement means
    /// the two halves describe different pictures.
    func testASizeThatContradictsTheMessageIsNotDrawn() throws {
        var window = SpiceGLZ.Window()
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 0, type: .glzRGB, flags: 0,
                width: UInt32(SpiceGLZFixtures.width + 1),
                height: UInt32(SpiceGLZFixtures.height)
            ),
            bitmap: nil, payload: SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].stream)
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image, glzWindow: &window))
    }

    /// **The window has to survive between pump calls**, which is the property
    /// the session's `run()` depends on and the one a convenience overload
    /// would quietly break.
    ///
    /// Two COPY messages carrying GLZ images 0 and 1, pumped one at a time
    /// through the same window. Image 1 refers back to image 0, so a window
    /// rebuilt between calls draws nothing the second time.
    func testTheWindowSurvivesFromOnePumpToTheNext() async throws {
        var inbound = surfaceCreate(16, 12)
        for fixture in SpiceGLZFixtures.sequence.prefix(2) {
            inbound += message(
                SpiceDisplayWire.Message.drawCopy.rawValue, copyBody(fixture)
            )
        }
        let channel = SpiceDisplayChannel(stream: MemoryByteStream(inbound: inbound))
        var surfaces = SpiceSurfaces()
        var glz = SpiceGLZ.Window()

        var first = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 2)
        XCTAssertEqual(first.undrawable, 0, "l'image 0 se décode sans fenêtre")
        first = try await channel.pump(into: &surfaces, glz: &glz, serial: 1, limit: 1)
        XCTAssertEqual(
            first.undrawable, 0,
            "l'image 1 renvoie à l'image 0 : sans fenêtre conservée, rien n'est dessiné"
        )
        XCTAssertEqual(glz.count, 2, "les deux images sont dans la fenêtre")
    }

    private func copyBody(_ fixture: SpiceGLZFixtures.Case) -> [UInt8] {
        let payload = SpiceGLZFixtures.bytes(fixture.stream)
        var body = u32(0)
        body += i32(0) + i32(0) + i32(16) + i32(12)     // box
        body += [0]                                      // no clip
        let imageOffset = UInt32(body.count + 4 + 16 + 2 + 1 + 13)
        body += u32(imageOffset)                         // src_bitmap
        body += i32(0) + i32(0) + i32(16) + i32(12)      // src_area
        body += [0, 0] + [0]                             // rop, scale mode
        body += [0] + i32(0) + i32(0) + u32(0)           // mask
        body += u32(UInt32(fixture.id)) + u32(0)         // image id, 64-bit
        body += [UInt8(SpiceDisplayWire.ImageType.glzRGB.rawValue), 0]
        body += u32(16) + u32(12)
        body += u32(UInt32(payload.count)) + payload
        return body
    }

    private func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }

    private func surfaceCreate(_ width: UInt32, _ height: UInt32) -> Data {
        message(
            SpiceDisplayWire.Message.surfaceCreate.rawValue,
            u32(0) + u32(width) + u32(height) + u32(32) + u32(0)
        )
    }

    private func message(_ type: UInt16, _ body: [UInt8]) -> Data {
        SpiceWire.message(type, serial: 1, payload: Data(body))
    }

    // MARK: - zlibGlzRGB

    /// Zipped GLZ decodes to exactly what unzipped GLZ decodes to, which is the
    /// whole claim: the wrapper is a wrapper.
    func testZlibWrappedGLZDecodesToTheSamePixels() throws {
        var window = SpiceGLZ.Window()
        for (index, wrapped) in SpiceGLZFixtures.zlibWrapped.enumerated() {
            let decoded = try XCTUnwrap(
                try SpiceDisplayWire.pixels(of: zlibImage(wrapped), glzWindow: &window),
                "image \(index)"
            )
            XCTAssertEqual(
                decoded.pixels,
                SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[index].decoded),
                "image \(index)"
            )
        }
    }

    /// **Two images, because one cannot show a dictionary carried wrongly.**
    /// `decode-zlib.c` resets before every image, so each is compressed on its
    /// own; an inflater reused with its dictionary intact gets the first right
    /// and the second wrong.
    func testTheSecondZippedImageIsNotCorruptedByTheFirst() throws {
        var window = SpiceGLZ.Window()
        _ = try SpiceDisplayWire.pixels(
            of: zlibImage(SpiceGLZFixtures.zlibWrapped[0]), glzWindow: &window
        )
        let second = try XCTUnwrap(try SpiceDisplayWire.pixels(
            of: zlibImage(SpiceGLZFixtures.zlibWrapped[1]), glzWindow: &window
        ))
        XCTAssertEqual(
            second.pixels, SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[1].decoded)
        )
    }

    /// The message promises an inflated size. A stream that does not produce it
    /// is a malformed message, not a picture — stricter than the reference,
    /// which warns and keeps whatever was written.
    func testAnInflatedSizeThatTheStreamDoesNotProduceIsRefused() throws {
        var window = SpiceGLZ.Window()
        var wrapped = SpiceGLZFixtures.zlibWrapped[0]
        wrapped = SpiceGLZFixtures.Zlib(
            compressed: wrapped.compressed,
            inflatedSize: wrapped.inflatedSize + 1, id: wrapped.id
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: zlibImage(wrapped), glzWindow: &window))
    }

    /// Payload that is not zlib at all throws rather than drawing.
    func testAPayloadThatIsNotZlibIsRefused() {
        var window = SpiceGLZ.Window()
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 0, type: .zlibGlzRGB, flags: 0,
                width: UInt32(SpiceGLZFixtures.width),
                height: UInt32(SpiceGLZFixtures.height)
            ),
            bitmap: nil, payload: [UInt8](repeating: 0x41, count: 64), inflatedSize: 100
        )
        XCTAssertThrowsError(try SpiceDisplayWire.pixels(of: image, glzWindow: &window))
    }

    private func zlibImage(_ wrapped: SpiceGLZFixtures.Zlib) -> SpiceDisplayWire.Image {
        SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: wrapped.id, type: .zlibGlzRGB, flags: 0,
                width: UInt32(SpiceGLZFixtures.width),
                height: UInt32(SpiceGLZFixtures.height)
            ),
            bitmap: nil,
            payload: SpiceGLZFixtures.bytes(wrapped.compressed),
            inflatedSize: wrapped.inflatedSize
        )
    }

    private func bytes(_ hex: String) -> [UInt8] { SpiceGLZFixtures.bytes(hex) }
}
