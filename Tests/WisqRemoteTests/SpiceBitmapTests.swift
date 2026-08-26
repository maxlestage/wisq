import XCTest
@testable import WisqRemote

/// Uncompressed bitmaps, and which way up an image goes.
///
/// The orientation tests are the ones worth having. Getting it wrong does not
/// throw and does not produce garbage — it produces the desktop upside down,
/// against the servers that store rows bottom-up and only those. That is a bug
/// that reaches a user rather than a test.
final class SpiceBitmapTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { SpiceWire.u32(value) }

    /// The LZ fixtures are hex, wrapped across lines to stay readable.
    private func hex(_ text: String) -> [UInt8] {
        let digits = text.filter { !$0.isWhitespace }
        var out: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            out.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    private func bitmap(
        _ format: SpiceDisplayWire.BitmapFormat, width: UInt32, height: UInt32,
        stride: UInt32, topDown: Bool, palette: SpiceDisplayWire.Palette? = nil
    ) -> SpiceDisplayWire.Bitmap {
        SpiceDisplayWire.Bitmap(
            format: format, flags: topDown ? 0x04 : 0x00,
            width: width, height: height, stride: stride,
            cachedPaletteID: nil, palette: palette
        )
    }

    // MARK: - Which way up

    /// Bottom-up is the default, and it is the case a reader forgets: the flag
    /// is named `TOP_DOWN`, so its absence is the interesting state.
    func testRowsAreBottomUpUnlessTheFlagSaysOtherwise() throws {
        // Two rows of one pixel, told apart by colour: red then blue.
        let data: [UInt8] = [0, 0, 0xFF, 0] + [0xFF, 0, 0, 0]

        let bottomUp = try SpiceBitmap.pixels(
            bitmap(.thirtyTwoBit, width: 1, height: 2, stride: 4, topDown: false), data: data
        )
        XCTAssertEqual(
            Array(bottomUp.prefix(3)), [0xFF, 0, 0],
            "la première ligne des données est la dernière à l'écran : le bleu remonte"
        )
        XCTAssertEqual(Array(bottomUp.suffix(4).prefix(3)), [0, 0, 0xFF])

        let topDown = try SpiceBitmap.pixels(
            bitmap(.thirtyTwoBit, width: 1, height: 2, stride: 4, topDown: true), data: data
        )
        XCTAssertEqual(Array(topDown.prefix(3)), [0, 0, 0xFF], "et là, dans l'ordre reçu")
        XCTAssertNotEqual(bottomUp, topDown, "sinon le drapeau ne fait rien")
    }

    /// The same rule, on the LZ codec, where the flag lives in the stream's own
    /// header — and where it was parsed and then ignored.
    ///
    /// Built from a stream the reference encoder produced, with one flag byte
    /// changed. Same pixels, same everything, one bit of orientation: the
    /// output must come back with its rows reversed and nothing else touched.
    func testALZStreamThatSaysBottomUpComesBackFlipped() throws {
        let sample = SpiceLZFixtures.all[0]
        var stream = hex(sample.stream)

        // `top_down` is the seventh word of the header: magic, version, type,
        // width, height, stride, then this one.
        XCTAssertEqual(Array(stream[24..<28]), [0, 0, 0, 1], "le gabarit est bien de haut en bas")

        let upright = try SpiceDisplayWire.pixels(of: lzImage(stream, sample))
        stream[27] = 0
        let flipped = try SpiceDisplayWire.pixels(of: lzImage(stream, sample))

        guard let unwrappedUpright = upright, let unwrappedFlipped = flipped else {
            return XCTFail("les deux flux doivent se décoder")
        }
        XCTAssertEqual(unwrappedFlipped.width, unwrappedUpright.width)
        XCTAssertEqual(unwrappedFlipped.height, unwrappedUpright.height)

        let rowSize = unwrappedUpright.pixels.count / sample.height
        XCTAssertGreaterThan(rowSize, 0)
        var expected: [UInt8] = []
        for row in (0..<sample.height).reversed() {
            expected += unwrappedUpright.pixels[(row * rowSize)..<((row + 1) * rowSize)]
        }
        XCTAssertEqual(unwrappedFlipped.pixels, expected)
        XCTAssertNotEqual(
            unwrappedFlipped.pixels, unwrappedUpright.pixels,
            "le gabarit doit avoir des lignes différentes, sinon le test ne teste rien"
        )
    }

    private func lzImage(
        _ stream: [UInt8], _ sample: SpiceLZFixtures.Case
    ) -> SpiceDisplayWire.Image {
        SpiceDisplayWire.Image(
            descriptor: SpiceDisplayWire.ImageDescriptor(
                id: 1, type: .lzRGB, flags: 0,
                width: UInt32(sample.width), height: UInt32(sample.height)
            ),
            bitmap: nil, payload: stream
        )
    }

    // MARK: - Stride

    /// `stride` is the distance between rows, not the width of one. Reading
    /// straight through shears every row after the first by the padding — an
    /// image that is recognisably the right picture, sliding sideways.
    func testThePaddingBetweenRowsIsSkippedRatherThanDrawn() throws {
        // Two pixels a row, but eleven bytes between rows: three of padding,
        // set to a colour that must never appear.
        let padding: [UInt8] = [0xEE, 0xEE, 0xEE]
        let data = [UInt8]([1, 2, 3] + [4, 5, 6]) + padding
            + [UInt8]([7, 8, 9] + [10, 11, 12]) + padding

        let pixels = try SpiceBitmap.pixels(
            bitmap(.twentyFourBit, width: 2, height: 2, stride: 9, topDown: true), data: data
        )
        XCTAssertEqual(pixels, [
            1, 2, 3, 0xFF, 4, 5, 6, 0xFF,
            7, 8, 9, 0xFF, 10, 11, 12, 0xFF
        ])
        XCTAssertFalse(pixels.contains(0xEE), "le remplissage n'est pas une couleur")
    }

    /// A stride smaller than a row is a message disagreeing with itself: the
    /// rows would overlap. Refused rather than drawn as something.
    func testAStrideTooSmallForARowIsRefused() {
        XCTAssertThrowsError(
            try SpiceBitmap.pixels(
                bitmap(.thirtyTwoBit, width: 4, height: 2, stride: 8, topDown: true),
                data: [UInt8](repeating: 0, count: 64)
            )
        ) { XCTAssertEqual($0 as? SpiceBitmap.Failure, .truncated) }
    }

    /// A stride and a height whose product no `Int` can hold.
    ///
    /// Both are `UInt32` off the wire, so the product reaches 1.8 × 10^19 and
    /// Swift traps — inside the guard, at the `*`, before it could refuse
    /// anything. `testAStrideTooSmallForARowIsRefused` above does not reach it
    /// and could not: a *large* width makes `minimumRow` exceed anything a
    /// `UInt32` stride can hold, so the clause before this one short-circuits
    /// and the multiplication never runs. The shape that gets there is the
    /// opposite one — width 1, stride and height at the top of their range —
    /// which is why the case is written this way round rather than "make every
    /// number big".
    func testAStrideAndHeightWhoseProductNoIntCanHoldAreRefused() {
        for (width, height, stride) in [
            (UInt32(1), UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF)),
            (1, 0x8000_0000, 0x8000_0000),
        ] {
            XCTAssertThrowsError(
                try SpiceBitmap.pixels(
                    bitmap(.thirtyTwoBit, width: width, height: height, stride: stride,
                           topDown: true),
                    data: [UInt8](repeating: 0, count: 64)
                ), "\(width)x\(height)@\(stride)"
            ) { XCTAssertEqual($0 as? SpiceBitmap.Failure, .truncated) }
        }
    }

    /// The other edge. A product that fits and describes data that is really
    /// there must still decode — a refusal here would trade a crash for a
    /// blank screen.
    func testAnOrdinaryBitmapStillDecodesAfterTheOverflowCheck() throws {
        let out = try SpiceBitmap.pixels(
            bitmap(.thirtyTwoBit, width: 2, height: 2, stride: 8, topDown: true),
            data: [UInt8](repeating: 0x40, count: 16)
        )
        XCTAssertEqual(out.count, 2 * 2 * 4)
    }

    func testDataShorterThanTheBitmapClaimsIsRefused() {
        XCTAssertThrowsError(
            try SpiceBitmap.pixels(
                bitmap(.thirtyTwoBit, width: 4, height: 4, stride: 16, topDown: true),
                data: [UInt8](repeating: 0, count: 16)
            )
        ) { XCTAssertEqual($0 as? SpiceBitmap.Failure, .truncated) }
    }

    // MARK: - The formats

    /// The fourth byte of an `xRGB` pixel is padding, not alpha. Copied
    /// through, a fully opaque desktop arrives completely transparent — and
    /// against a server that happens to send zeroes there, nothing is drawn at
    /// all.
    func testTheFourthByteOfAnXRGBPixelIsNotAlpha() throws {
        let pixels = try SpiceBitmap.pixels(
            bitmap(.thirtyTwoBit, width: 1, height: 1, stride: 4, topDown: true),
            data: [10, 20, 30, 0x00]
        )
        XCTAssertEqual(pixels, [10, 20, 30, 0xFF])
    }

    /// And on `RGBA` it is, so the same bytes mean two different things.
    func testOnRGBATheFourthByteIsKept() throws {
        let pixels = try SpiceBitmap.pixels(
            bitmap(.rgba, width: 1, height: 1, stride: 4, topDown: true),
            data: [10, 20, 30, 0x40]
        )
        XCTAssertEqual(pixels, [10, 20, 30, 0x40])
    }

    /// 0555 expansion repeats the high bits rather than shifting and leaving
    /// zeros. Shifted alone, full white comes out at 248 and every bright
    /// colour is slightly dull — a picture that looks fine until it is put
    /// beside a correct one.
    func testFiveBitChannelsExpandToFullRangeRatherThanStoppingShort() throws {
        // 0x7FFF is white; 0x7C00 is full red.
        let data: [UInt8] = [0xFF, 0x7F, 0x00, 0x7C]
        let pixels = try SpiceBitmap.pixels(
            bitmap(.sixteenBit, width: 2, height: 1, stride: 4, topDown: true), data: data
        )
        XCTAssertEqual(Array(pixels.prefix(4)), [0xFF, 0xFF, 0xFF, 0xFF], "le blanc est 255")
        XCTAssertEqual(Array(pixels.suffix(4)), [0x00, 0x00, 0xFF, 0xFF], "le rouge saturé aussi")
    }

    /// An eight-bit alpha bitmap is a mask: the byte is opacity over black,
    /// not a grey level.
    func testAnEightBitAlphaBitmapIsAMaskRatherThanAGrey() throws {
        let pixels = try SpiceBitmap.pixels(
            bitmap(.eightBitAlpha, width: 2, height: 1, stride: 2, topDown: true),
            data: [0x00, 0x80]
        )
        XCTAssertEqual(pixels, [0, 0, 0, 0x00, 0, 0, 0, 0x80])
    }

    // MARK: - Palettes

    private let table = SpiceDisplayWire.Palette(
        unique: 0, colours: [0x0000_0000, 0x00FF_0000, 0x0000_FF00, 0x0000_00FF]
    )

    /// The same two orders the LZ codec's palette forms follow, and the same
    /// reason they are worth a test: backwards, either still produces an image,
    /// mirrored in pairs of pixels or in groups of eight.
    func testTheNibbleAndBitOrdersAreTheOnesTheProtocolMeans() throws {
        // 0x01: low nibble 1, high nibble 0.
        let littleEndian = try SpiceBitmap.pixels(
            bitmap(.fourBitLE, width: 2, height: 1, stride: 1, topDown: true, palette: table),
            data: [0x01]
        )
        XCTAssertEqual(littleEndian, [0, 0, 0xFF, 0xFF] + [0, 0, 0, 0xFF],
                       "LE : le quartet bas d'abord")

        let bigEndian = try SpiceBitmap.pixels(
            bitmap(.fourBitBE, width: 2, height: 1, stride: 1, topDown: true, palette: table),
            data: [0x01]
        )
        XCTAssertEqual(bigEndian, [0, 0, 0, 0xFF] + [0, 0, 0xFF, 0xFF],
                       "BE : le quartet haut d'abord")

        // 0x80: bit 7 set, bit 0 clear.
        let oneBitLE = try SpiceBitmap.pixels(
            bitmap(.oneBitLE, width: 8, height: 1, stride: 1, topDown: true, palette: table),
            data: [0x80]
        )
        XCTAssertEqual(Array(oneBitLE.prefix(4)), [0, 0, 0, 0xFF], "LE commence au bit 0")
        XCTAssertEqual(Array(oneBitLE.suffix(4)), [0, 0, 0xFF, 0xFF])

        let oneBitBE = try SpiceBitmap.pixels(
            bitmap(.oneBitBE, width: 8, height: 1, stride: 1, topDown: true, palette: table),
            data: [0x80]
        )
        XCTAssertEqual(Array(oneBitBE.prefix(4)), [0, 0, 0xFF, 0xFF], "BE commence au bit 7")
        XCTAssertEqual(Array(oneBitBE.suffix(4)), [0, 0, 0, 0xFF])
    }

    /// A palettised bitmap whose table lives in a cache this client does not
    /// keep has no colours to draw with. Saying so beats drawing whatever the
    /// index happens to land on.
    func testAPalettisedBitmapWithoutItsTableIsRefused() {
        XCTAssertThrowsError(
            try SpiceBitmap.pixels(
                bitmap(.eightBit, width: 2, height: 1, stride: 2, topDown: true),
                data: [0, 1]
            )
        ) { XCTAssertEqual($0 as? SpiceBitmap.Failure, .missingPalette) }
    }

    /// An index past the end of the table is a broken image, not a reason to
    /// drop the connection — the codecs themselves wrap it.
    func testAnIndexPastTheEndOfTheTableWrapsRatherThanThrowing() throws {
        let pixels = try SpiceBitmap.pixels(
            bitmap(.eightBit, width: 1, height: 1, stride: 1, topDown: true, palette: table),
            data: [5]
        )
        XCTAssertEqual(pixels, [0, 0, 0xFF, 0xFF], "5 modulo 4 : la deuxième entrée")
    }

    // MARK: - Through the display message

    /// The whole path: an image inside a draw message, decoded to pixels.
    /// Before this, an uncompressed bitmap was parsed and then dropped, so a
    /// server with image compression off drew nothing at all.
    func testAnUncompressedBitmapInAMessageBecomesPixels() throws {
        var message = u32(0)  // a word of padding so the image is not at zero
        let offset = UInt32(message.count)
        message += SpiceWire.u64(9)
        message += [0 /* BITMAP */, 0 /* flags */]
        message += u32(2) + u32(2)
        message += [8 /* 32BIT */, 0x04 /* TOP_DOWN */]
        message += u32(2) + u32(2) + u32(8)
        message += u32(0)  // null palette pointer
        message += [1, 2, 3, 0, 4, 5, 6, 0]
        message += [7, 8, 9, 0, 10, 11, 12, 0]

        let body = SpiceDisplayWire.Body(message)
        let image = try XCTUnwrap(try SpiceDisplayWire.image(at: offset, in: body))
        XCTAssertEqual(image.descriptor.type, .bitmap)
        XCTAssertEqual(image.payload?.count, 16, "les pixels suivent en ligne, pas via un pointeur")

        guard let decoded = try SpiceDisplayWire.pixels(of: image) else {
            return XCTFail("l'image doit se décoder")
        }
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.pixels, [
            1, 2, 3, 0xFF, 4, 5, 6, 0xFF,
            7, 8, 9, 0xFF, 10, 11, 12, 0xFF
        ])
    }

    /// The palette is reached through a pointer like everything else in the
    /// message, and it is little-endian — the display channel's order, not the
    /// big-endian one inside an LZ stream's header.
    func testABitmapsPaletteIsFollowedThroughItsPointer() throws {
        let paletteOffset = UInt32(64)
        var message = u32(0)
        let offset = UInt32(message.count)
        message += SpiceWire.u64(9)
        message += [0, 0]
        message += u32(2) + u32(1)
        message += [5 /* 8BIT */, 0x04 /* TOP_DOWN */]
        message += u32(2) + u32(1) + u32(2)
        message += u32(paletteOffset)
        message += [1, 0]  // two indices
        message += [UInt8](repeating: 0, count: Int(paletteOffset) - message.count)
        message += SpiceWire.u64(0xABCD)          // unique
        message += SpiceWire.u16(2)               // two entries
        message += u32(0x0000_00FF) + u32(0x00FF_0000)

        let body = SpiceDisplayWire.Body(message)
        let image = try XCTUnwrap(try SpiceDisplayWire.image(at: offset, in: body))
        XCTAssertEqual(image.bitmap?.palette?.unique, 0xABCD)
        XCTAssertEqual(image.bitmap?.palette?.colours, [0x0000_00FF, 0x00FF_0000])

        guard let decoded = try SpiceDisplayWire.pixels(of: image) else {
            return XCTFail("l'image doit se décoder")
        }
        // Entry 1 is 0x00FF0000, which is blue in BGRA; entry 0 is red.
        XCTAssertEqual(decoded.pixels, [0, 0, 0xFF, 0xFF] + [0xFF, 0, 0, 0xFF])
    }
}
