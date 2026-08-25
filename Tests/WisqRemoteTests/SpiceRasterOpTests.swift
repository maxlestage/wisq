import XCTest
@testable import WisqRemote

/// The raster operation where it lands: on a surface, through a draw.
///
/// `SpiceROPTests` proves the descriptor collapses onto the right operation.
/// This proves the right operation reaches the right pixels — which is a
/// separate claim, and the one that was false for every draw wisq made until
/// now, because the descriptor was read off the wire and thrown away.
final class SpiceRasterOpTests: XCTestCase {
    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    private func noMask() -> SpiceDisplayWire.Mask {
        SpiceDisplayWire.Mask(flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil)
    }

    private func makeSurface(
        _ width: UInt32 = 4, _ height: UInt32 = 2,
        format: SpiceDisplayWire.SurfaceFormat = .xrgb32
    ) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: width, height: height, format: format, flags: 0
        ))
        return surfaces
    }

    private func fill(
        _ colour: UInt32, rop: UInt16, _ box: SpiceDisplayWire.Rect
    ) -> SpiceDisplayWire.Fill {
        SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
            brush: .solid(colour), rop: rop, mask: noMask()
        )
    }

    private func pixel(_ surfaces: SpiceSurfaces, _ x: Int = 0, _ y: Int = 0) -> [UInt8] {
        let surface = surfaces.surfaces[0]!
        let at = (y * surface.width + x) * 4
        return Array(surface.pixels[at..<(at + 4)])
    }

    private enum Flag {
        static let inversSource: UInt16 = 1 << 0
        static let inversBrush: UInt16 = 1 << 1
        static let put: UInt16 = 1 << 3
        static let xor: UInt16 = 1 << 6
    }

    // MARK: - Fill

    /// **The reason any of this matters.**
    ///
    /// A selection rectangle, a caret and a rubber-band outline are all drawn
    /// with XOR, so that drawing them a second time takes them off again. Read
    /// as a plain copy — which is what every fill did until now — they go on
    /// and stay on.
    func testAnXorFillTwiceLeavesTheSurfaceExactlyAsItWas() throws {
        var surfaces = try makeSurface(4, 2)
        _ = try surfaces.fill(fill(0x0012_3456, rop: 0, rect(0, 0, 2, 4)))
        let before = surfaces.surfaces[0]!.pixels

        _ = try surfaces.fill(fill(0x00AB_CDEF, rop: Flag.xor, rect(0, 0, 2, 4)))
        XCTAssertNotEqual(surfaces.surfaces[0]!.pixels, before, "sinon rien n'a été combiné")
        XCTAssertEqual(pixel(surfaces), [0x56 ^ 0xEF, 0x34 ^ 0xCD, 0x12 ^ 0xAB, 0])

        _ = try surfaces.fill(fill(0x00AB_CDEF, rop: Flag.xor, rect(0, 0, 2, 4)))
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before)
    }

    /// **A fill's rop calls the brush its source**, so the flag that inverts it
    /// is `INVERS_BRUSH`. Reading `INVERS_SRC` literally gives a fill that
    /// inverts nothing — and this is the test that separates the two, because
    /// the same descriptor is sent with both bits by different messages.
    func testAFillInvertsItsBrushAndNotItsSource() throws {
        var surfaces = try makeSurface(4, 2)

        _ = try surfaces.fill(fill(0x0012_3456, rop: Flag.put | Flag.inversBrush, rect(0, 0, 2, 4)))
        XCTAssertEqual(
            pixel(surfaces), [~UInt8(0x56), ~UInt8(0x34), ~UInt8(0x12), 0],
            "INVERS_BRUSH inverse la couleur peinte"
        )

        _ = try surfaces.fill(fill(0x0012_3456, rop: Flag.put | Flag.inversSource, rect(0, 0, 2, 4)))
        XCTAssertEqual(
            pixel(surfaces), [0x56, 0x34, 0x12, 0],
            "INVERS_SRC ne désigne aucun opérande d'un remplissage"
        )
    }

    /// A rop is applied to the pad byte too on a surface that has alpha, and
    /// not on one that does not — otherwise `invert` would fill the pad with
    /// 0xFF and every pixel would claim an opacity the surface cannot carry.
    func testThePadByteStaysZeroUnderARopOnASurfaceWithoutAlpha() throws {
        var opaqueSurface = try makeSurface(4, 2, format: .xrgb32)
        _ = try opaqueSurface.fill(fill(0xFFFF_FFFF, rop: 0x200, rect(0, 0, 2, 4)))  // OP_INVERS
        XCTAssertEqual(pixel(opaqueSurface)[3], 0)

        var withAlpha = try makeSurface(4, 2, format: .argb32)
        _ = try withAlpha.fill(fill(0x8000_0000, rop: 0, rect(0, 0, 2, 4)))
        XCTAssertEqual(pixel(withAlpha)[3], 0x80)
        _ = try withAlpha.fill(fill(0, rop: 0x200, rect(0, 0, 2, 4)))                // OP_INVERS
        XCTAssertEqual(pixel(withAlpha)[3], ~UInt8(0x80), "le rop porte sur le mot entier")
    }

    // MARK: - Copy

    private func copyOperation(
        rop: UInt16, _ box: SpiceDisplayWire.Rect
    ) -> SpiceDisplayWire.Copy {
        SpiceDisplayWire.Copy(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: box, clip: .none),
            source: nil, sourceArea: box, rop: rop, scaleMode: 0, mask: noMask()
        )
    }

    func testACopyCombinesItsImageWithWhatIsAlreadyThere() throws {
        var surfaces = try makeSurface(4, 2)
        _ = try surfaces.fill(fill(0x0012_3456, rop: 0, rect(0, 0, 2, 4)))

        let image = [UInt8](repeating: 0xF0, count: 4 * 2 * 4)
        _ = try surfaces.copy(
            copyOperation(rop: Flag.xor, rect(0, 0, 2, 4)),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(pixel(surfaces), [0x56 ^ 0xF0, 0x34 ^ 0xF0, 0x12 ^ 0xF0, 0])
    }

    /// A copy is the one message whose rop reads literally, and this pins the
    /// difference from a fill: here `INVERS_SRC` is the one that bites.
    func testACopyInvertsItsSourceAndNotItsBrush() throws {
        let image = [UInt8](repeating: 0xF0, count: 4 * 2 * 4)

        var inverted = try makeSurface(4, 2)
        _ = try inverted.copy(
            copyOperation(rop: Flag.put | Flag.inversSource, rect(0, 0, 2, 4)),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(pixel(inverted)[0], ~UInt8(0xF0))

        var plain = try makeSurface(4, 2)
        _ = try plain.copy(
            copyOperation(rop: Flag.put | Flag.inversBrush, rect(0, 0, 2, 4)),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(pixel(plain)[0], 0xF0, "une copie n'a pas de pinceau")
    }

    // MARK: - Opaque

    /// **The order is the message.**
    ///
    /// `DRAW_OPAQUE` blits its image with no raster operation at all and only
    /// then combines the brush onto it, so the rop's operands are the brush and
    /// the *image* — the destination has already been overwritten.
    ///
    /// The three values below are chosen so that the right answer and the two
    /// plausible wrong ones are all different: combining the image with the old
    /// destination, or the brush with the old destination, each gives something
    /// else. Without that the test would pass on any of the three.
    func testOpaqueBlitsTheImageAndThenCombinesTheBrushWithIt() throws {
        let destination: UInt8 = 0x0F
        let imageByte: UInt8 = 0x33
        let brushByte: UInt8 = 0x55

        var surfaces = try makeSurface(4, 2)
        _ = try surfaces.fill(
            fill(UInt32(destination) << 16 | UInt32(destination) << 8 | UInt32(destination),
                 rop: 0, rect(0, 0, 2, 4))
        )
        XCTAssertEqual(pixel(surfaces)[0], destination)

        let image = [UInt8](repeating: imageByte, count: 4 * 2 * 4)
        _ = try surfaces.opaque(
            SpiceDisplayWire.Opaque(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4),
                brush: .solid(
                    UInt32(brushByte) << 16 | UInt32(brushByte) << 8 | UInt32(brushByte)
                ),
                rop: Flag.xor, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )

        XCTAssertEqual(pixel(surfaces)[0], brushByte ^ imageByte, "pinceau sur image")
        XCTAssertNotEqual(brushByte ^ imageByte, imageByte ^ destination, "les trois diffèrent")
        XCTAssertNotEqual(brushByte ^ imageByte, brushByte ^ destination)
    }

    /// And the labelling that goes with that order: for an opaque, the flag
    /// inverting the rop's *destination* is `INVERS_SRC`, because the rop's
    /// destination is the image.
    func testOpaqueLabelsTheImageAsTheRopsDestination() throws {
        var surfaces = try makeSurface(4, 2)
        let image = [UInt8](repeating: 0x33, count: 4 * 2 * 4)
        _ = try surfaces.opaque(
            SpiceDisplayWire.Opaque(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4), brush: .solid(0x0055_5555),
                rop: Flag.xor | Flag.inversSource, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        // XOR with one operand inverted is EQUIV.
        XCTAssertEqual(pixel(surfaces)[0], SpiceROP.equiv.apply(source: 0x55, destination: 0x33))
    }

    func testOpaqueWithABrushItCannotPaintIsRefused() throws {
        var surfaces = try makeSurface(4, 2)
        let image = [UInt8](repeating: 0x33, count: 4 * 2 * 4)
        XCTAssertThrowsError(try surfaces.opaque(
            SpiceDisplayWire.Opaque(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4), brush: .none,
                rop: 0, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    // MARK: - The ternary operation on a surface

    /// `DRAW_ROP3` combines all three operands at the pixel.
    ///
    /// The opcode is `0xE2` — one that needs pattern, source *and* destination,
    /// so no two of the three can be muddled without the answer changing. A
    /// degenerate opcode like `SRCCOPY` would pass with the pattern wired to
    /// anything at all.
    func testARop3CombinesPatternSourceAndDestination() throws {
        var surfaces = try makeSurface(4, 2)
        _ = try surfaces.fill(fill(0x000F_0F0F, rop: 0, rect(0, 0, 2, 4)))

        let pattern: UInt32 = 0x0033_3333
        let sourceByte: UInt8 = 0x55
        let image = [UInt8](repeating: sourceByte, count: 4 * 2 * 4)
        _ = try surfaces.rop3(
            SpiceDisplayWire.Rop3(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4), brush: .solid(pattern),
                rop3: 0xE2, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        let expected = SpiceROP3(0xE2).apply(
            pattern: 0x33, source: sourceByte, destination: 0x0F
        )
        XCTAssertEqual(pixel(surfaces)[0], expected)
        // The three operands really are distinguishable here.
        XCTAssertNotEqual(expected, 0x33)
        XCTAssertNotEqual(expected, sourceByte)
        XCTAssertNotEqual(expected, 0x0F)
    }

    /// One of the 38 the reference aborts on. wisq evaluates the table, so it
    /// simply works — and `SRCCOPY` is the clearest of them to assert.
    func testAnOpcodeTheReferenceRefusesStillWorks() throws {
        var surfaces = try makeSurface(4, 2)
        _ = try surfaces.fill(fill(0x000F_0F0F, rop: 0, rect(0, 0, 2, 4)))
        let image = [UInt8](repeating: 0x77, count: 4 * 2 * 4)
        _ = try surfaces.rop3(
            SpiceDisplayWire.Rop3(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4), brush: .solid(0x0033_3333),
                rop3: 0xCC, scaleMode: 0, mask: noMask()          // SRCCOPY
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(pixel(surfaces)[0], 0x77, "la source l'emporte")
    }

    func testARop3WithABrushItCannotPaintIsRefused() throws {
        var surfaces = try makeSurface(4, 2)
        let image = [UInt8](repeating: 0x77, count: 4 * 2 * 4)
        XCTAssertThrowsError(try surfaces.rop3(
            SpiceDisplayWire.Rop3(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 2, 4), clip: .none),
                source: nil, sourceArea: rect(0, 0, 2, 4), brush: .none,
                rop3: 0xE2, scaleMode: 0, mask: noMask()
            ),
            source: (pixels: image, width: 4, height: 2), bytesPerSourcePixel: 4
        )) { error in
            XCTAssertEqual(error as? SpiceSurfaces.Failure, .notDrawable)
        }
    }

    // MARK: - The wire

    /// `DRAW_OPAQUE` is a copy with a brush wedged in before the rop. Read with
    /// the copy decoder, the brush's type byte becomes the low half of the rop
    /// and everything after it shifts.
    /// `DRAW_ROP3` is `DRAW_OPAQUE`'s shape with **one** byte where the rop
    /// descriptor's two were. Read with the opaque decoder, the scale mode
    /// becomes the descriptor's high half and everything after it shifts.
    func testRop3IsOpaquesShapeWithAOneByteOpcode() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(0)
        payload += u32(0) + u32(0) + u32(2) + u32(4)
        payload += [0]
        payload += u32(0)
        payload += u32(0) + u32(0) + u32(2) + u32(4)
        payload += [1] + u32(0x0012_3456)
        payload += [0xE2]                                     // rop3, one byte
        payload += [3]                                        // scale mode
        payload += [0] + u32(0) + u32(0) + u32(0)             // mask

        let decoded = try SpiceDisplayWire.rop3(payload)
        XCTAssertEqual(decoded.rop3, 0xE2)
        XCTAssertEqual(decoded.scaleMode, 3, "le mode d'échelle suit immédiatement")
        XCTAssertEqual(decoded.brush, .solid(0x0012_3456))
        XCTAssertNil(decoded.mask.bitmap)
        XCTAssertThrowsError(try SpiceDisplayWire.rop3(Array(payload.dropLast())))
    }

    func testOpaqueIsACopyWithABrushBeforeTheRop() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(0)                                     // surface
        payload += u32(0) + u32(0) + u32(2) + u32(4)          // box
        payload += [0]                                        // clip: none
        payload += u32(0)                                     // src_bitmap: null
        payload += u32(0) + u32(0) + u32(2) + u32(4)          // src_area
        payload += [1] + u32(0x0012_3456)                     // brush: solid
        payload += [0x40, 0x00]                               // rop: OP_XOR
        payload += [0]                                        // scale mode
        payload += [0] + u32(0) + u32(0) + u32(0)             // mask

        let opaque = try SpiceDisplayWire.opaque(payload)
        XCTAssertEqual(opaque.base.box, rect(0, 0, 2, 4))
        XCTAssertEqual(opaque.brush, .solid(0x0012_3456))
        XCTAssertEqual(opaque.rop, Flag.xor)
        XCTAssertEqual(opaque.scaleMode, 0)
        XCTAssertNil(opaque.mask.bitmap)
        XCTAssertNil(opaque.source, "un pointeur nul est une image mise en cache")
    }
}
