import XCTest
@testable import WisqRemote

/// SPICE's LZ codec, checked against SPICE's LZ encoder.
///
/// The fixtures in `SpiceLZFixtures` are real streams: `spice-common`'s own
/// `lz.c` was linked into a harness and asked to compress images built to
/// contain flat bands, a repeating pattern and noise, so literal runs, short
/// matches, long matches and the two-byte far distance all appear. That is what
/// makes these tests worth having — a fixture assembled by hand can only
/// confirm that the same person made the same assumptions twice, and both of
/// the mistakes this decoder actually made would have survived it.
final class SpiceLZTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        // The fixtures are wrapped across lines to stay readable, so the
        // whitespace comes out before anything is parsed.
        let hex = hex.filter { !$0.isWhitespace }
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// The test the whole exercise is for: every reference stream decompresses
    /// back to exactly the image the reference encoder was given.
    func testEveryReferenceStreamDecompressesToTheOriginalImage() throws {
        for fixture in SpiceLZFixtures.all {
            let (header, pixels) = try SpiceLZ.decompress(bytes(fixture.stream))

            XCTAssertEqual(header.type, fixture.type, fixture.name)
            XCTAssertEqual(header.width, fixture.width, fixture.name)
            XCTAssertEqual(header.height, fixture.height, fixture.name)

            let expected = bytes(fixture.original)
            XCTAssertEqual(pixels.count, expected.count, "\(fixture.name) : longueur")
            if pixels != expected {
                // Reported as the first disagreeing byte rather than as two
                // thousand hex characters, which no one reads.
                let at = zip(pixels, expected).enumerated().first { $0.element.0 != $0.element.1 }
                XCTFail("""
                \(fixture.name) (\(fixture.note)) : \
                premier octet différent à \(at?.offset ?? -1) — \
                obtenu \(at.map { String($0.element.0, radix: 16) } ?? "?"), \
                attendu \(at.map { String($0.element.1, radix: 16) } ?? "?")
                """)
            }
        }
    }

    /// Every fourth byte of an `rgb32` image is the padding the codec never
    /// transmits, and it must come back as zero.
    ///
    /// This test began as a comparison between the `rgb32` and `rgb24`
    /// fixtures, on the assumption that they carried the same picture at two
    /// widths. They do not: the generator fills by stride position, and the
    /// strides differ, so the two are different images. The assumption was
    /// wrong rather than the decoder, and the test now asserts the thing that
    /// is actually true.
    func testTheThirtyTwoBitFormsFourthByteIsAlwaysTheZeroPadding() throws {
        for fixture in SpiceLZFixtures.all where fixture.type == .rgb32 {
            let (_, pixels) = try SpiceLZ.decompress(bytes(fixture.stream))
            XCTAssertEqual(pixels.count, fixture.width * fixture.height * 4, fixture.name)
            for pixel in 0..<(fixture.width * fixture.height) {
                XCTAssertEqual(pixels[pixel * 4 + 3], 0, "\(fixture.name), pixel \(pixel)")
            }
        }
    }

    /// And a 24-bit image occupies exactly three bytes a pixel, with no
    /// padding invented for it.
    func testTheTwentyFourBitFormHasNoPaddingAtAll() throws {
        for fixture in SpiceLZFixtures.all where fixture.type == .rgb24 {
            let (_, pixels) = try SpiceLZ.decompress(bytes(fixture.stream))
            XCTAssertEqual(pixels.count, fixture.width * fixture.height * 3, fixture.name)
        }
    }

    // MARK: - The header

    /// The header is big-endian, inside a protocol that is little-endian
    /// everywhere else. Read the other way the magic does not match, and
    /// nothing after it means anything.
    func testTheHeaderIsBigEndianUnlikeEverythingElseInThisProtocol() throws {
        let stream = bytes(SpiceLZFixtures.all[0].stream)
        XCTAssertEqual(Array(stream.prefix(4)), [0x20, 0x20, 0x5A, 0x4C], "« LZ  » tel quel")

        var reader = SpiceLZ.Reader(stream)
        XCTAssertEqual(try reader.u32(), SpiceLZ.magic)

        // The same four bytes read little-endian, which is what borrowing the
        // rest of the protocol's reader would have produced.
        XCTAssertNotEqual(UInt32(0x4C5A_2020), SpiceLZ.magic)
    }

    func testSomethingThatIsNotAnLZStreamIsRefusedOnItsMagic() {
        for junk in [[UInt8](repeating: 0, count: 32), Array("not an lz stream at all!!".utf8)] {
            XCTAssertThrowsError(try SpiceLZ.decompress(junk)) { error in
                XCTAssertEqual(error as? SpiceLZ.Failure, .notLZ)
            }
        }
    }

    func testAFutureVersionIsNamedRatherThanAttempted() {
        var stream = bytes(SpiceLZFixtures.all[0].stream)
        stream[4] = 0
        stream[5] = 2 // major 2
        XCTAssertThrowsError(try SpiceLZ.decompress(stream)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .unsupportedVersion(major: 2, minor: 1))
        }
    }

    /// The dimensions are signed on the wire. A negative one is not a small
    /// image — it is a size that becomes enormous the moment it is multiplied,
    /// and it is refused before anything is allocated from it.
    func testANegativeDimensionIsRefusedBeforeAnythingIsAllocated() {
        for field in [12, 16] { // width, then height
            var stream = bytes(SpiceLZFixtures.all[0].stream)
            stream[field] = 0xFF
            stream[field + 1] = 0xFF
            stream[field + 2] = 0xFF
            stream[field + 3] = 0xFF
            XCTAssertThrowsError(try SpiceLZ.decompress(stream), "champ \(field)") { error in
                XCTAssertEqual(error as? SpiceLZ.Failure, .badGeometry)
            }
        }
    }

    /// A stream this decoder does not handle is named as such, separately from
    /// a type the codec itself does not define. They call for different things:
    /// one is work not done, the other is a broken stream.
    func testAValidTypeThisDecoderDoesNotHandleIsNamedApart() {
        var stream = bytes(SpiceLZFixtures.all[0].stream)
        stream[11] = 5 // PLT8, a real type, not decoded here
        XCTAssertThrowsError(try SpiceLZ.decompress(stream)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .unsupportedImageType(.palette8))
        }

        stream[11] = 99 // not a type at all
        XCTAssertThrowsError(try SpiceLZ.decompress(stream)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .unknownImageType(99))
        }
    }

    // MARK: - Refusals in the body

    /// A stream cut short must stop, not read past its end.
    func testATruncatedStreamIsRefusedAtEveryLength() {
        let full = bytes(SpiceLZFixtures.all[1].stream)
        for length in stride(from: 20, to: full.count, by: 7) {
            XCTAssertThrowsError(
                try SpiceLZ.decompress(Array(full.prefix(length))), "coupé à \(length)"
            )
        }
    }

    /// A match reaching back before the start of the output. In C this reads
    /// whatever happened to precede the buffer; here it is a refusal.
    func testAMatchReachingBeforeTheStartIsRefusedRatherThanReadingBehindTheBuffer() {
        // Header for a 4x4 rgb32 image, then a match as the very first
        // instruction — there is nothing behind it to match against.
        var stream: [UInt8] = [0x20, 0x20, 0x5A, 0x4C] // magic
        stream += [0, 1, 0, 1]                         // version 1.1
        stream += [0, 0, 0, 8]                         // rgb32
        stream += [0, 0, 0, 4] + [0, 0, 0, 4]          // 4x4
        stream += [0, 0, 0, 16]                        // stride
        stream += [0, 0, 0, 1]                         // top down
        // A match, straight away: control 0x20 is the shortest one there is —
        // length one, distance one — and there is nothing behind it to match.
        stream += [0x20, 0x00]

        XCTAssertThrowsError(try SpiceLZ.decompress(stream)) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .referenceBeforeStart)
        }
    }

    // MARK: - Through the display channel

    /// The codec reached through a real `DRAW_COPY`, which is the only way it
    /// is ever reached in service.
    ///
    /// Decoding structure and running a codec are kept apart on purpose, and
    /// that separation is worth exactly one test that crosses it — otherwise
    /// both halves can be right while nothing joins them.
    func testAnLZImageArrivesThroughADrawCopyAndComesOutAsPixels() throws {
        let fixture = SpiceLZFixtures.all[1]
        let stream = bytes(fixture.stream)

        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        func i32(_ value: Int32) -> [UInt8] { u32(UInt32(bitPattern: value)) }

        // A copy whose source points at an LZ_RGB image placed after the fixed
        // part of the message.
        var payload = u32(0)                                    // surface id
        payload += i32(0) + i32(0) + i32(8) + i32(8)            // box
        payload += [0]                                          // no clip
        let imageOffset = UInt32(payload.count + 4 + 16 + 2 + 1 + 13)
        payload += u32(imageOffset)                             // src_bitmap
        payload += i32(0) + i32(0) + i32(8) + i32(8)            // src_area
        payload += [0, 0]                                       // rop
        payload += [0]                                          // scale mode
        payload += [0] + i32(0) + i32(0) + u32(0)               // mask
        XCTAssertEqual(payload.count, Int(imageOffset), "le décalage doit viser la fin du fixe")

        payload += u32(0) + u32(0)                              // image id
        payload += [101 /* LZ_RGB */, 0]                        // type, flags
        payload += u32(8) + u32(8)                              // width, height
        payload += u32(UInt32(stream.count)) + stream           // BinaryData

        let copy = try SpiceDisplayWire.copy(payload)
        let image = try XCTUnwrap(copy.source)
        XCTAssertEqual(image.descriptor.type, .lzRGB)
        XCTAssertEqual(image.payload?.count, stream.count)

        let decoded = try XCTUnwrap(try SpiceDisplayWire.pixels(of: image))
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.pixels, bytes(fixture.original))
    }

    /// GLZ has the same stream format as LZ and must not be handed to the LZ
    /// decoder anyway: its matches reach back into a dictionary built from
    /// *earlier images on the channel*, so decoding one alone assembles a
    /// picture out of whatever happened to be around. Sharing the entry point
    /// would be the kind of mistake that produces a plausible image.
    func testAGLZImageIsNotDecodedAsIfItWereLZ() throws {
        let image = SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .glzRGB, flags: 0, width: 8, height: 8
            ),
            bitmap: nil,
            payload: bytes(SpiceLZFixtures.all[1].stream)
        )
        XCTAssertNil(try SpiceDisplayWire.pixels(of: image))
    }

    /// An encoding wisq does not decode yet answers "no pixels", not "bad
    /// message". The caller's response to the first is to leave that part of
    /// the screen alone; to the second, to drop the connection.
    func testAnUndecodedEncodingAnswersNoPixelsRatherThanAnError() throws {
        for type in [SpiceDisplayWire.ImageType.quic, .jpeg, .lz4] {
            let image = SpiceDisplayWire.Image(
                descriptor: SpiceDisplayWire.ImageDescriptor(
                    id: 1, type: type, flags: 0, width: 8, height: 8
                ),
                bitmap: nil,
                payload: [1, 2, 3, 4]
            )
            XCTAssertNil(try SpiceDisplayWire.pixels(of: image), "\(type)")
        }
    }
}
