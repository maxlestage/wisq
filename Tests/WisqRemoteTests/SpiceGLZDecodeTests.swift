import XCTest
@testable import WisqRemote

/// The GLZ match loop, against a whole sequence.
///
/// This is the first GLZ test that could not exist for a single image: the
/// streams are decoded **in order through one window**, and images 1 to 3
/// reach back into the ones before them. Decoded alone they would produce
/// something; decoded together they must produce exactly what SPICE's own
/// decoder produced from the same four streams.
final class SpiceGLZDecodeTests: XCTestCase {
    func testTheSequenceDecodesToWhatTheReferenceDecoderProduced() throws {
        var window = SpiceGLZ.Window()

        for (index, fixture) in SpiceGLZFixtures.sequence.enumerated() {
            let stream = SpiceGLZFixtures.bytes(fixture.stream)
            let header = try SpiceGLZ.header(stream)
            let pixels = SpiceGLZFixtures.width * SpiceGLZFixtures.height

            let decoded = try SpiceGLZ.decodeRGB32(
                stream, from: SpiceGLZ.headerBytes, pixels: pixels,
                imageID: header.id, window: window
            )
            XCTAssertEqual(
                decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded), "image \(index)"
            )

            window.add(SpiceGLZ.Window.Image(
                id: header.id, winHeadDistance: header.winHeadDistance,
                pixels: decoded.pixels,
                width: header.width, height: header.height
            ))
            window.releaseAfterAdding()
        }
    }

    /// The same, over the two sequences added for paths the first one never
    /// took: local matches, and an image distance past the six bits the
    /// control byte holds.
    func testTheSequencesForTheUncoveredPathsAlsoDecodeExactly() throws {
        for (name, sequence) in [
            ("repeating", SpiceGLZFixtures.repeating),
            ("farBack", SpiceGLZFixtures.farBack)
        ] {
            var window = SpiceGLZ.Window()
            for (index, fixture) in sequence.enumerated() {
                let stream = SpiceGLZFixtures.bytes(fixture.stream)
                let header = try SpiceGLZ.header(stream)
                let decoded = try SpiceGLZ.decodeRGB32(
                    stream, from: SpiceGLZ.headerBytes,
                    pixels: SpiceGLZFixtures.width * SpiceGLZFixtures.height,
                    imageID: header.id, window: window
                )
                XCTAssertEqual(
                    decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded),
                    "\(name) image \(index)"
                )
                window.add(SpiceGLZ.Window.Image(
                    id: header.id, winHeadDistance: header.winHeadDistance,
                    pixels: decoded.pixels, width: header.width, height: header.height
                ))
                window.releaseAfterAdding()
            }
        }
    }

    /// The long-pixel-offset branch, which nothing smaller reaches.
    func testALocalOffsetPastTheShortFieldDecodesExactly() throws {
        let fixture = SpiceGLZFixtures.longOffset
        let stream = SpiceGLZFixtures.bytes(fixture.stream)
        let header = try SpiceGLZ.header(stream)
        XCTAssertEqual(header.width, SpiceGLZFixtures.longOffsetWidth)
        XCTAssertEqual(header.height, SpiceGLZFixtures.longOffsetHeight)

        let decoded = try SpiceGLZ.decodeRGB32(
            stream, from: SpiceGLZ.headerBytes,
            pixels: SpiceGLZFixtures.longOffsetWidth * SpiceGLZFixtures.longOffsetHeight,
            imageID: header.id, window: SpiceGLZ.Window()
        )
        XCTAssertEqual(decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded))

        // The half-repeat is what forces the offset past 4095, so it is worth
        // asserting the fixture really has it rather than trusting the note.
        let half = decoded.pixels.count / 2
        XCTAssertEqual(Array(decoded.pixels[0..<half]), Array(decoded.pixels[half...]))
    }

    /// The very-long pixel offset, against a crafted stream the reference
    /// decoder was run over.
    func testTheVeryLongOffsetMatchesTheReferenceDecoder() throws {
        let stream = SpiceGLZFixtures.bytes(SpiceGLZFixtures.craftedVeryLongOffset)
        let header = try SpiceGLZ.header(stream)
        XCTAssertEqual(header.width, SpiceGLZFixtures.craftedWidth)
        XCTAssertEqual(header.height, SpiceGLZFixtures.craftedHeight)

        let count = SpiceGLZFixtures.craftedWidth * SpiceGLZFixtures.craftedHeight
        let decoded = try SpiceGLZ.decodeRGB32(
            stream, from: SpiceGLZ.headerBytes, pixels: count,
            imageID: header.id, window: SpiceGLZ.Window()
        )
        XCTAssertEqual(decoded.pixels.count, count * 4)

        var digest: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in decoded.pixels {
            digest ^= UInt64(byte)
            digest = digest &* 0x0000_0100_0000_01B3
        }
        XCTAssertEqual(
            digest, SpiceGLZFixtures.craftedDigest,
            "chaque octet doit être celui que le décodeur de référence a produit"
        )

        // What the craft was built around, asserted rather than assumed: the
        // match at offset 131088 brings the first sixteen pixels back.
        XCTAssertEqual(
            Array(decoded.pixels[0..<64]),
            Array(decoded.pixels[(131_088 * 4)..<(131_104 * 4)])
        )
    }

    /// A cross-image match that is also past the short offset — the one
    /// combination nothing else here produces.
    func testADeepCrossImageMatchAgreesWithTheReferenceDecoder() throws {
        var window = SpiceGLZ.Window()
        let count = SpiceGLZFixtures.deepWidth * SpiceGLZFixtures.deepHeight

        for (index, fixture) in SpiceGLZFixtures.deep.enumerated() {
            let stream = SpiceGLZFixtures.bytes(fixture.stream)
            let header = try SpiceGLZ.header(stream)
            let decoded = try SpiceGLZ.decodeRGB32(
                stream, from: SpiceGLZ.headerBytes, pixels: count,
                imageID: header.id, window: window
            )
            var digest: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in decoded.pixels {
                digest ^= UInt64(byte)
                digest = digest &* 0x0000_0100_0000_01B3
            }
            XCTAssertEqual(digest, fixture.digest, "image \(index)")

            window.add(SpiceGLZ.Window.Image(
                id: header.id, winHeadDistance: header.winHeadDistance,
                pixels: decoded.pixels, width: header.width, height: header.height
            ))
            window.releaseAfterAdding()
        }
    }

    /// `rgb24` through the very same loop, which is what the reference's
    /// dispatch table says should work — and what encoding the same content
    /// both ways confirms: the two streams differ only in the type byte and
    /// the stride word, the payload being identical.
    ///
    /// This adds no coverage of the loop itself. It pins the header reading
    /// and the guard, which is the whole of what admitting rgb24 rests on.
    func testRGB24DecodesThroughTheSameLoop() throws {
        var window = SpiceGLZ.Window()
        for (index, fixture) in SpiceGLZFixtures.rgb24.enumerated() {
            let stream = SpiceGLZFixtures.bytes(fixture.stream)
            let header = try SpiceGLZ.header(stream)
            XCTAssertEqual(header.type, .rgb24, "le gabarit doit bien être du rgb24")

            let decoded = try SpiceGLZ.decodeRGB32(
                stream, from: SpiceGLZ.headerBytes,
                pixels: SpiceGLZFixtures.width * SpiceGLZFixtures.height,
                imageID: header.id, window: window
            )
            XCTAssertEqual(
                decoded.pixels, SpiceGLZFixtures.bytes(fixture.decoded), "image \(index)"
            )
            window.add(SpiceGLZ.Window.Image(
                id: header.id, winHeadDistance: header.winHeadDistance,
                pixels: decoded.pixels, width: header.width, height: header.height
            ))
            window.releaseAfterAdding()
        }
    }

    /// The whole point, stated as a test: images after the first genuinely
    /// depend on the window. Decoding one with an empty window must fail rather
    /// than produce a picture out of nothing.
    func testAnImageThatReachesBackIsRefusedWithoutItsWindow() throws {
        let fixture = SpiceGLZFixtures.sequence[1]
        let stream = SpiceGLZFixtures.bytes(fixture.stream)
        let header = try SpiceGLZ.header(stream)
        XCTAssertThrowsError(
            try SpiceGLZ.decodeRGB32(
                stream, from: SpiceGLZ.headerBytes,
                pixels: SpiceGLZFixtures.width * SpiceGLZFixtures.height,
                imageID: header.id, window: SpiceGLZ.Window()
            )
        ) {
            XCTAssertEqual($0 as? SpiceGLZ.Failure, .referenceOutsideTheWindow)
        }
    }

    /// Every byte of every stream is consumed, and no more. A loop that stops
    /// on the pixel count alone can leave a stream half-read and still look
    /// right.
    func testEachStreamIsReadToItsEnd() throws {
        var window = SpiceGLZ.Window()
        for (index, fixture) in SpiceGLZFixtures.sequence.enumerated() {
            let stream = SpiceGLZFixtures.bytes(fixture.stream)
            let header = try SpiceGLZ.header(stream)
            let decoded = try SpiceGLZ.decodeRGB32(
                stream, from: SpiceGLZ.headerBytes,
                pixels: SpiceGLZFixtures.width * SpiceGLZFixtures.height,
                imageID: header.id, window: window
            )
            XCTAssertEqual(
                decoded.bytesRead, stream.count - SpiceGLZ.headerBytes, "image \(index)"
            )
            window.add(SpiceGLZ.Window.Image(
                id: header.id, winHeadDistance: header.winHeadDistance,
                pixels: decoded.pixels, width: header.width, height: header.height
            ))
        }
    }
}
