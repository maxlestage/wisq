import XCTest
@testable import WisqRemote

/// `DRAW_TRANSPARENT` — a colour-key blit.
///
/// The simplest compositing on the channel: one colour in the image means
/// "leave what is underneath", every other pixel is copied. It is how an icon
/// or a cursor with a hard-edged silhouette gets drawn without an alpha
/// channel, and it was being counted as ignored.
final class SpiceTransparentTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    private func makeSurface(_ width: UInt32 = 4, _ height: UInt32 = 2) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: .xrgb32, flags: 0
        ))
        return surfaces
    }

    /// Fills the surface with one colour, through the public entry point.
    private func background(_ colour: UInt32, _ surfaces: inout SpiceSurfaces) throws {
        let surface = surfaces.surfaces[0]!
        _ = try surfaces.fill(SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(
                surfaceID: 0,
                box: rect(0, 0, Int32(surface.height), Int32(surface.width)),
                clip: .none
            ),
            brush: .solid(colour), rop: 0,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        ))
    }

    /// A source image built one pixel at a time from 32-bit xRGB words, so the
    /// key and the pixels are written in the same notation.
    private func image(_ pixels: [UInt32], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8]()
        for pixel in pixels {
            out += [
                UInt8(pixel & 0xFF), UInt8(pixel >> 8 & 0xFF),
                UInt8(pixel >> 16 & 0xFF), UInt8(pixel >> 24 & 0xFF),
            ]
        }
        XCTAssertEqual(out.count, width * height * 4)
        return out
    }

    private func operation(
        key: UInt32, _ box: SpiceDisplayWire.Rect, sourceColour: UInt32 = 0xDEAD_BEEF
    ) -> SpiceDisplayWire.Transparent {
        SpiceDisplayWire.Transparent(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
            source: nil, sourceArea: box,
            sourceColour: sourceColour, trueColour: key
        )
    }

    private func word(_ surfaces: SpiceSurfaces, _ x: Int, _ y: Int = 0) -> UInt32 {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return UInt32(surface.pixels[at])
            | UInt32(surface.pixels[at + 1]) << 8
            | UInt32(surface.pixels[at + 2]) << 16
    }

    // MARK: - The key

    func testThePixelsMatchingTheKeyAreLeftAloneAndTheRestAreCopied() throws {
        var surfaces = try makeSurface(4, 1)
        try background(0x0011_2233, &surfaces)

        let key: UInt32 = 0x00FF_00FF
        let source = image([0x00AA_BBCC, key, 0x0012_3456, key], width: 4, height: 1)
        let written = try surfaces.transparent(
            operation(key: key, rect(0, 0, 1, 4)),
            source: (pixels: source, width: 4, height: 1), bytesPerSourcePixel: 4
        )

        XCTAssertEqual(word(surfaces, 0), 0x00AA_BBCC)
        XCTAssertEqual(word(surfaces, 1), 0x0011_2233, "la clé laisse le fond")
        XCTAssertEqual(word(surfaces, 2), 0x0012_3456)
        XCTAssertEqual(word(surfaces, 3), 0x0011_2233)
        // The region reported is the rectangle, not the pixels actually
        // written — the same choice the mask makes, and for the same reason.
        XCTAssertEqual(written, [rect(0, 0, 1, 4)])
    }

    /// **The comparison is on twenty-four bits.**
    ///
    /// The reference masks the key with `0xffffff` before the loop and then
    /// compares `0xffffff & pixel`. Comparing all thirty-two would make the key
    /// miss on any source pixel whose fourth byte is not zero — which is most
    /// of them, since a decoded RGB image arrives with an opaque 0xFF there.
    func testTheFourthByteTakesNoPartInTheComparison() throws {
        var surfaces = try makeSurface(2, 1)
        try background(0x0011_2233, &surfaces)

        // Same low 24 bits as the key, different top byte, on both pixels.
        let source = image([0xFF00_FF00, 0x7F00_FF00], width: 2, height: 1)
        _ = try surfaces.transparent(
            operation(key: 0x0000_FF00, rect(0, 0, 1, 2)),
            source: (pixels: source, width: 2, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(word(surfaces, 0), 0x0011_2233, "le quatrième octet ne compte pas")
        XCTAssertEqual(word(surfaces, 1), 0x0011_2233)
    }

    /// The key's own fourth byte is ignored too, which is the other half of the
    /// same masking and is easy to implement only one way round.
    func testTheKeysOwnFourthByteIsIgnored() throws {
        var surfaces = try makeSurface(2, 1)
        try background(0x0011_2233, &surfaces)

        let source = image([0x0000_FF00, 0x00AB_CDEF], width: 2, height: 1)
        _ = try surfaces.transparent(
            operation(key: 0xAB00_FF00, rect(0, 0, 1, 2)),
            source: (pixels: source, width: 2, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(word(surfaces, 0), 0x0011_2233, "la clé masquée correspond")
        XCTAssertEqual(word(surfaces, 1), 0x00AB_CDEF)
    }

    /// **`src_color` is never read.** It is in the message; the reference keys
    /// on `true_color`. Reading the wrong one gives a picture with the wrong
    /// holes in it, which is a picture.
    func testTheOtherColourInTheMessageIsNotTheKey() throws {
        var surfaces = try makeSurface(2, 1)
        try background(0x0011_2233, &surfaces)

        let source = image([0x00AA_AAAA, 0x00BB_BBBB], width: 2, height: 1)
        _ = try surfaces.transparent(
            operation(key: 0x00AA_AAAA, rect(0, 0, 1, 2), sourceColour: 0x00BB_BBBB),
            source: (pixels: source, width: 2, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(word(surfaces, 0), 0x0011_2233, "true_color est la clé")
        XCTAssertEqual(word(surfaces, 1), 0x00BB_BBBB, "src_color ne l'est pas")
    }

    /// **The key's channels are not interchangeable.**
    ///
    /// Every key in the tests above happens to be symmetric in red and blue —
    /// `0x00FF00FF`, `0x0000FF00` — so swapping the two while unpacking the key
    /// passed all of them. Found by a sabotage that survived, not by reading.
    /// The key here is asymmetric, and the second source pixel is its mirror:
    /// a decoder with the channels crossed keys on the wrong one of the two.
    func testTheKeysRedAndBlueAreNotInterchangeable() throws {
        var surfaces = try makeSurface(2, 1)
        try background(0x0055_5555, &surfaces)

        let source = image([0x0011_2233, 0x0033_2211], width: 2, height: 1)
        _ = try surfaces.transparent(
            operation(key: 0x0011_2233, rect(0, 0, 1, 2)),
            source: (pixels: source, width: 2, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(word(surfaces, 0), 0x0055_5555, "la clé exacte laisse le fond")
        XCTAssertEqual(
            word(surfaces, 1), 0x0033_2211,
            "son miroir rouge/bleu n'est pas la clé et doit être copié"
        )
    }

    func testAThreeByteSourceKeysOnTheSameThreeBytes() throws {
        var surfaces = try makeSurface(2, 1)
        try background(0x0011_2233, &surfaces)

        let source: [UInt8] = [0x00, 0xFF, 0x00, 0xEF, 0xCD, 0xAB]   // BGR, BGR
        _ = try surfaces.transparent(
            operation(key: 0x0000_FF00, rect(0, 0, 1, 2)),
            source: (pixels: source, width: 2, height: 1), bytesPerSourcePixel: 3
        )
        XCTAssertEqual(word(surfaces, 0), 0x0011_2233)
        XCTAssertEqual(word(surfaces, 1), 0x00AB_CDEF)
        XCTAssertEqual(surfaces.surfaces[0]!.pixels[7], 0, "le pad reste nul")
    }

    func testTheClipCutsATransparentDrawLikeAnyOther() throws {
        var surfaces = try makeSurface(4, 1)
        try background(0x0011_2233, &surfaces)

        let source = image([0x00AA_AAAA, 0x00AA_AAAA, 0x00AA_AAAA, 0x00AA_AAAA],
                           width: 4, height: 1)
        var draw = operation(key: 0x0000_0000, rect(0, 0, 1, 4))
        draw.base.clip = .rects([rect(0, 0, 1, 2)])
        let written = try surfaces.transparent(
            draw, source: (pixels: source, width: 4, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(written, [rect(0, 0, 1, 2)])
        XCTAssertEqual(word(surfaces, 1), 0x00AA_AAAA)
        XCTAssertEqual(word(surfaces, 2), 0x0011_2233, "hors du clip")
    }

    /// **A clip moves which pixels get written, never which source pixel each
    /// one comes from.**
    ///
    /// `copy` has this test already; `transparent` did not, and a sabotage that
    /// took the source coordinate from the clipped rectangle instead of the box
    /// survived every other test here — because every clip in them starts at the
    /// same column as its box. Computed from the clip, the image slides sideways
    /// wherever something overlaps it.
    func testAClipDoesNotSlideTheImageSideways() throws {
        var surfaces = try makeSurface(4, 1)
        try background(0x0055_5555, &surfaces)

        let source = image(
            [0x0000_0001, 0x0000_0002, 0x0000_0003, 0x0000_0004], width: 4, height: 1
        )
        var draw = operation(key: 0x00FF_FFFF, rect(0, 0, 1, 4))
        draw.base.clip = .rects([rect(0, 2, 1, 4)])
        let written = try surfaces.transparent(
            draw, source: (pixels: source, width: 4, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(written, [rect(0, 2, 1, 4)])
        XCTAssertEqual(word(surfaces, 0), 0x0055_5555, "hors du clip")
        XCTAssertEqual(word(surfaces, 1), 0x0055_5555)
        XCTAssertEqual(word(surfaces, 2), 0x0000_0003, "colonne 2 vient du pixel 2")
        XCTAssertEqual(word(surfaces, 3), 0x0000_0004)
    }

    func testADrawOnASurfaceThatDoesNotExistIsRefused() throws {
        var surfaces = try makeSurface(2, 1)
        var draw = operation(key: 0, rect(0, 0, 1, 2))
        draw.base.surfaceID = 4
        XCTAssertThrowsError(try surfaces.transparent(
            draw, source: (pixels: [UInt8](repeating: 0, count: 8), width: 2, height: 1),
            bytesPerSourcePixel: 4
        )) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .unknownSurface(4))
        }
    }

    // MARK: - The wire

    /// **Shorter than every other draw that carries an image**: no rop, no
    /// scale mode, no mask. A decoder assuming the copy layout would read the
    /// two colours where the rop and scale mode belong.
    func testTransparentIsImageAreaAndTwoColours() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(0)                                  // surface
        payload += u32(0) + u32(0) + u32(1) + u32(2)       // box
        payload += [0]                                     // clip: none
        payload += u32(0)                                  // src_bitmap: null
        payload += u32(0) + u32(0) + u32(1) + u32(2)       // src_area
        payload += u32(0x0011_2233)                        // src_color
        payload += u32(0x00AA_BBCC)                        // true_color

        let decoded = try SpiceDisplayWire.transparent(payload)
        XCTAssertEqual(decoded.base.box, rect(0, 0, 1, 2))
        XCTAssertEqual(decoded.sourceArea, rect(0, 0, 1, 2))
        XCTAssertEqual(decoded.sourceColour, 0x0011_2233)
        XCTAssertEqual(decoded.trueColour, 0x00AA_BBCC)
        XCTAssertNil(decoded.source)
        // Exactly consumed: a payload one byte short must not decode.
        XCTAssertThrowsError(try SpiceDisplayWire.transparent(Array(payload.dropLast())))
    }
}
