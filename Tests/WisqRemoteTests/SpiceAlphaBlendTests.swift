import XCTest
@testable import WisqRemote

/// `DRAW_ALPHA_BLEND` — the one draw on this channel that really composites.
///
/// The expectations below are **pixman's own output**, not arithmetic repeated
/// here in a second form. `scripts/spice-alpha-blend/abref.c` performs the exact
/// call `__blend_image` performs — `PIXMAN_OP_OVER` with a solid mask whose
/// alpha is the message's — and prints what comes back. Recomputing the formula
/// in the test would agree with a wrong formula.
final class SpiceAlphaBlendTests: XCTestCase {
    /// One composite, in the notation the harness prints.
    struct Case {
        /// Premultiplied ARGB.
        let source: UInt32
        let destination: UInt32
        /// The message's overall alpha.
        let alpha: UInt8
        let destinationHasAlpha: Bool
        /// What pixman produced.
        let expected: UInt32
    }

    /// Straight from `./abref fixtures`.
    static let cases: [Case] = [
        Case(source: 0xFF20_3040, destination: 0x0080_6040, alpha: 0xFF,
             destinationHasAlpha: false, expected: 0xFF20_3040),
        Case(source: 0x8010_2030, destination: 0x0080_6040, alpha: 0xFF,
             destinationHasAlpha: false, expected: 0x8050_5050),
        Case(source: 0x0000_0000, destination: 0x0080_6040, alpha: 0xFF,
             destinationHasAlpha: false, expected: 0x0080_6040),
        Case(source: 0xFF20_3040, destination: 0x0080_6040, alpha: 0x00,
             destinationHasAlpha: false, expected: 0x0080_6040),
        Case(source: 0xFF20_3040, destination: 0x0080_6040, alpha: 0x80,
             destinationHasAlpha: false, expected: 0x8050_4840),
        Case(source: 0x8010_2030, destination: 0x0080_6040, alpha: 0x40,
             destinationHasAlpha: false, expected: 0x2074_5C44),
        Case(source: 0xFF20_3040, destination: 0x0080_6040, alpha: 0x01,
             destinationHasAlpha: false, expected: 0x017F_6040),
        Case(source: 0x4010_1010, destination: 0x00FF_FFFF, alpha: 0xFF,
             destinationHasAlpha: false, expected: 0x40CF_CFCF),
        Case(source: 0x8010_2030, destination: 0x4020_1008, alpha: 0xFF,
             destinationHasAlpha: true, expected: 0xA020_2834),
        Case(source: 0x8010_2030, destination: 0x4020_1008, alpha: 0x80,
             destinationHasAlpha: true, expected: 0x7020_1C1E),
        Case(source: 0xFFFF_FFFF, destination: 0x0000_0000, alpha: 0xFF,
             destinationHasAlpha: true, expected: 0xFFFF_FFFF),
        Case(source: 0x0000_0000, destination: 0xFF80_6040, alpha: 0xFF,
             destinationHasAlpha: true, expected: 0xFF80_6040),
        Case(source: 0x7F3F_1F0F, destination: 0x7F0F_1F3F, alpha: 0x7F,
             destinationHasAlpha: true, expected: 0x9F2A_2636),
        Case(source: 0xFE7E_3E1E, destination: 0x0101_0101, alpha: 0xFD,
             destinationHasAlpha: true, expected: 0xFC7D_3E1E),
    ]

    private func rect(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32)
        -> SpiceDisplayWire.Rect {
        SpiceDisplayWire.Rect(top: top, left: left, bottom: bottom, right: right)
    }

    /// A one-pixel surface holding `word`, built without reaching inside.
    private func surface(
        _ word: UInt32, hasAlpha: Bool
    ) throws -> SpiceSurfaces {
        var surfaces = SpiceSurfaces()
        try surfaces.create(SpiceDisplayWire.SurfaceCreate(
            surfaceID: 0, width: 1, height: 1,
            format: hasAlpha ? .argb32 : .xrgb32, flags: 0
        ))
        _ = try surfaces.fill(SpiceDisplayWire.Fill(
            base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 1, 1), clip: .none),
            brush: .solid(word), rop: 0,
            mask: SpiceDisplayWire.Mask(
                flags: 0, origin: SpiceDisplayWire.Point(x: 0, y: 0), bitmap: nil
            )
        ))
        return surfaces
    }

    private func word(_ surfaces: SpiceSurfaces) -> UInt32 {
        let pixels = surfaces.surfaces[0]!.pixels
        return UInt32(pixels[0]) | UInt32(pixels[1]) << 8
            | UInt32(pixels[2]) << 16 | UInt32(pixels[3]) << 24
    }

    private func bytes(_ word: UInt32) -> [UInt8] {
        [UInt8(word & 0xFF), UInt8(word >> 8 & 0xFF),
         UInt8(word >> 16 & 0xFF), UInt8(word >> 24 & 0xFF)]
    }

    // MARK: - Against pixman

    func testEveryCompositeMatchesWhatPixmanProduced() throws {
        for (index, test) in Self.cases.enumerated() {
            var surfaces = try surface(test.destination, hasAlpha: test.destinationHasAlpha)
            // The fill's own rule holds the pad at zero on an xRGB surface, so
            // only an alpha-bearing surface can be preloaded with one.
            if test.destinationHasAlpha {
                XCTAssertEqual(word(surfaces), test.destination, "cas \(index) : préparation")
            }

            _ = try surfaces.alphaBlend(
                SpiceDisplayWire.AlphaBlend(
                    base: SpiceDisplayWire.Base(
                        surfaceID: 0, box: rect(0, 0, 1, 1), clip: .none
                    ),
                    flags: test.destinationHasAlpha
                        ? SpiceDisplayWire.AlphaBlend.destinationHasAlpha : 0,
                    alpha: test.alpha, source: nil, sourceArea: rect(0, 0, 1, 1)
                ),
                source: (pixels: bytes(test.source), width: 1, height: 1),
                bytesPerSourcePixel: 4
            )

            // An xRGB surface holds its fourth byte at zero, where pixman reads
            // the x-format back as opaque; compare the colour only there.
            let mask: UInt32 = test.destinationHasAlpha ? 0xFFFF_FFFF : 0x00FF_FFFF
            XCTAssertEqual(
                word(surfaces) & mask, test.expected & mask,
                "cas \(index) : source \(String(test.source, radix: 16)) "
                    + "sur \(String(test.destination, radix: 16)) à \(test.alpha)"
            )
            if !test.destinationHasAlpha {
                XCTAssertEqual(word(surfaces) >> 24, 0, "cas \(index) : le pad reste nul")
            }
        }
    }

    /// The fixtures are not all the same composite, and a formula that returned
    /// its source unchanged would pass a table of opaque sources.
    func testTheFixturesCoverMoreThanOneOutcome() {
        let outcomes = Set(Self.cases.map(\.expected))
        XCTAssertGreaterThan(outcomes.count, 8)
        XCTAssertTrue(Self.cases.contains { $0.expected != $0.source }, "pas que des copies")
        XCTAssertTrue(
            Self.cases.contains { $0.expected != $0.destination }, "pas que des non-opérations"
        )
        XCTAssertTrue(Self.cases.contains { $0.alpha == 0 })
        XCTAssertTrue(Self.cases.contains { $0.destinationHasAlpha })
        XCTAssertTrue(Self.cases.contains { !$0.destinationHasAlpha })
    }

    // MARK: - pixman's multiply

    /// `MUL_UN8`, and the two things it is not.
    ///
    /// The obvious `a · b / 255` and the cheap `(a · b) >> 8` both disagree with
    /// it, and on ordinary values rather than exotic ones — so a blend written
    /// with either produces an image that is almost right.
    func testTheEightBitMultiplyIsPixmansAndNotOneOfTheObviousTwo() {
        XCTAssertEqual(SpiceSurfaces.multiply(0, 0), 0)
        XCTAssertEqual(SpiceSurfaces.multiply(255, 255), 255)
        XCTAssertEqual(SpiceSurfaces.multiply(255, 0), 0)
        XCTAssertEqual(SpiceSurfaces.multiply(128, 128), 64)

        var differsFromShift = 0
        var differsFromDivide = 0
        for lhs in UInt8.min...UInt8.max {
            for rhs in UInt8.min...UInt8.max {
                let got = SpiceSurfaces.multiply(lhs, rhs)
                let product = Int(lhs) * Int(rhs)
                if got != UInt8(product >> 8) { differsFromShift += 1 }
                if got != UInt8(product / 255) { differsFromDivide += 1 }
                // Never out of range, and never more than one off the exact
                // rational answer.
                XCTAssertLessThanOrEqual(abs(Int(got) - product / 255), 1, "\(lhs)·\(rhs)")
            }
        }
        XCTAssertGreaterThan(differsFromShift, 1000, "le décalage n'est pas la même fonction")
        XCTAssertGreaterThan(differsFromDivide, 100, "la division entière non plus")
    }

    // MARK: - The two flags and the early exit

    func testAnOverallAlphaOfZeroDrawsNothingAndReportsNothing() throws {
        var surfaces = try surface(0x0011_2233, hasAlpha: false)
        let before = surfaces.surfaces[0]!.pixels
        let written = try surfaces.alphaBlend(
            SpiceDisplayWire.AlphaBlend(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 1, 1), clip: .none),
                flags: 0, alpha: 0, source: nil, sourceArea: rect(0, 0, 1, 1)
            ),
            source: (pixels: bytes(0xFFFF_FFFF), width: 1, height: 1), bytesPerSourcePixel: 4
        )
        XCTAssertEqual(written, [], "rien à re-téléverser")
        XCTAssertEqual(surfaces.surfaces[0]!.pixels, before)
    }

    /// A three-byte source has no alpha of its own and is opaque — which is
    /// what pixman sees when handed an `x8r8g8b8` image.
    ///
    /// **The destination must not be black.** This test was written over a
    /// black surface, where an opaque source and a fully transparent one both
    /// leave the source's own bytes behind — so treating a three-byte source as
    /// transparent passed it. Found by a sabotage that survived. Over a
    /// non-black destination the two answers differ by the destination.
    func testAThreeByteSourceIsOpaque() throws {
        var surfaces = try surface(0x0040_4040, hasAlpha: false)
        XCTAssertEqual(word(surfaces) & 0x00FF_FFFF, 0x0040_4040, "préparation non nulle")

        _ = try surfaces.alphaBlend(
            SpiceDisplayWire.AlphaBlend(
                base: SpiceDisplayWire.Base(surfaceID: 0, box: rect(0, 0, 1, 1), clip: .none),
                flags: 0, alpha: 0xFF, source: nil, sourceArea: rect(0, 0, 1, 1)
            ),
            source: (pixels: [0x40, 0x30, 0x20], width: 1, height: 1), bytesPerSourcePixel: 3
        )
        // Opaque: the source wins outright. Transparent would have added the
        // destination on top and given 0x00607080.
        XCTAssertEqual(word(surfaces) & 0x00FF_FFFF, 0x0020_3040, "opaque : la source l'emporte")
    }

    /// **`SRC_SURFACE_HAS_ALPHA` is not read on this path.** The reference
    /// passes it only when the source is another surface; with an image it
    /// hands `blend_image` the destination flag alone.
    func testTheSourceSurfaceFlagChangesNothingWhenTheSourceIsAnImage() throws {
        func run(_ flags: UInt8) throws -> UInt32 {
            var surfaces = try surface(0x0080_6040, hasAlpha: false)
            _ = try surfaces.alphaBlend(
                SpiceDisplayWire.AlphaBlend(
                    base: SpiceDisplayWire.Base(
                        surfaceID: 0, box: rect(0, 0, 1, 1), clip: .none
                    ),
                    flags: flags, alpha: 0x80, source: nil, sourceArea: rect(0, 0, 1, 1)
                ),
                source: (pixels: bytes(0x8010_2030), width: 1, height: 1),
                bytesPerSourcePixel: 4
            )
            return word(surfaces)
        }
        XCTAssertEqual(
            try run(0), try run(SpiceDisplayWire.AlphaBlend.sourceSurfaceHasAlpha)
        )
    }

    // MARK: - The wire

    /// **Two bytes before the image pointer**, which no other draw does.
    ///
    /// A decoder reusing the copy reader takes the flags and the alpha plus the
    /// first two bytes of the pointer as the pointer, and follows an offset
    /// into the middle of the message.
    func testTheFlagsAndAlphaComeBeforeTheImagePointer() throws {
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        var payload: [UInt8] = []
        payload += u32(0)                               // surface
        payload += u32(0) + u32(0) + u32(3) + u32(5)    // box
        payload += [0]                                  // clip: none
        payload += [0x01, 0x7F]                         // flags, alpha
        payload += u32(0)                               // src_bitmap: null
        payload += u32(1) + u32(2) + u32(3) + u32(4)    // src_area

        let decoded = try SpiceDisplayWire.alphaBlend(payload)
        XCTAssertEqual(decoded.base.box, rect(0, 0, 3, 5))
        XCTAssertEqual(decoded.flags, SpiceDisplayWire.AlphaBlend.destinationHasAlpha)
        XCTAssertTrue(decoded.readsDestinationAlpha)
        XCTAssertEqual(decoded.alpha, 0x7F)
        XCTAssertEqual(decoded.sourceArea, rect(1, 2, 3, 4))
        XCTAssertNil(decoded.source)
        XCTAssertThrowsError(try SpiceDisplayWire.alphaBlend(Array(payload.dropLast())))
    }
}
