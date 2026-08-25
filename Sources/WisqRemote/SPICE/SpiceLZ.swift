import Foundation

/// SPICE's own LZ codec, decoding side.
///
/// The display channel stops at compressed payloads; this is the first of them
/// undone. LZ was chosen before QUIC and before JPEG for a reason that is about
/// this repository rather than about the codec: it is integer work on bytes
/// with no platform behind it, so a Linux runner that costs nothing can check
/// every branch of it. JPEG would mean `ImageIO` on Apple and nothing on Linux
/// — the shape of `WisqNet.SHA256`, which returns empty `Data` where CryptoKit
/// is absent and therefore agrees with itself about nothing.
///
/// Written from `spice-common`'s `lz.c` and `lz_decompress_tmpl.c`, not from
/// recall, and two things in it would have been written wrong from recall:
///
///   * **the stream header is big-endian**, inside a protocol that is
///     little-endian everywhere else — `decode_32` shifts left and ors, one
///     byte at a time. Read the other way round the magic does not match and
///     nothing after it means anything;
///   * **the lengths and distances are biased**, and biased *differently per
///     pixel type*: a match length gains 1 for RGB32, 2 for RGB16, 3 for the
///     palette types. Miss the bias and every match is short by a pixel, which
///     produces an image that is almost right — the worst kind of wrong.
enum SpiceLZ {
    /// `"LZ  "`, and it is read big-endian like the rest of the header.
    static let magic: UInt32 = 0x2020_5A4C
    static let versionMajor: UInt32 = 1
    static let versionMinor: UInt32 = 1

    /// A control byte below this is a run of literals; at or above it, a match.
    static let maxCopy = 32

    /// Distances up to this come in the control byte and one more; past it the
    /// encoder switches to a two-byte far distance biased by this value.
    static let maxDistance = 8191

    /// The image types the codec labels its streams with. The numbering is the
    /// codec's own and has nothing to do with the display channel's
    /// `bitmap_fmt`.
    enum ImageType: UInt32, Equatable, Sendable {
        case palette1LE = 1
        case palette1BE = 2
        case palette4LE = 3
        case palette4BE = 4
        case palette8 = 5
        case rgb16 = 6
        case rgb24 = 7
        case rgb32 = 8
        case rgba = 9
        case xxxa = 10
        case a8 = 11
    }

    struct Header: Equatable, Sendable {
        var type: ImageType
        var width: Int
        var height: Int
        var stride: Int
        var topDown: Bool
    }

    enum Failure: Error, Equatable {
        case notLZ
        case unsupportedVersion(major: UInt32, minor: UInt32)
        case unknownImageType(UInt32)
        /// Named rather than folded into `unknownImageType`: this one says the
        /// stream is perfectly valid and wisq does not decode it yet, which is
        /// a different message and a different piece of work.
        case unsupportedImageType(ImageType)
        case badGeometry
        case truncated
        /// A match reaching back before the start of the output. In C this
        /// reads whatever preceded the buffer; here it is a refusal.
        case referenceBeforeStart
        /// A palette form arrived without the palette it needs. Named rather
        /// than filled with black: a screen of black is a picture, and a wrong
        /// one.
        case missingPalette
    }

    /// A big-endian cursor.
    ///
    /// Its own type rather than `SpiceWire.Reader` because that one is
    /// little-endian, correctly, for everything else in this protocol. Reaching
    /// for it here would be wrong in the way that still works most of the time,
    /// which is exactly the mistake this codebase already wrote down once when
    /// it declined to borrow RFB's big-endian readers for SPICE.
    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u32() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 { value = value << 8 | UInt32(try u8()) }
            return value
        }

        // The palette is little-endian while everything above is big-endian.
        // It belongs to the display channel's message rather than to the LZ
        // stream, and that channel is little-endian throughout — so the two
        // orders genuinely meet inside one buffer, and reading either with the
        // other's helper is a colour table full of nonsense.

        mutating func u16LittleEndian() throws -> UInt16 {
            let low = try u8()
            return UInt16(low) | UInt16(try u8()) << 8
        }

        mutating func u32LittleEndian() throws -> UInt32 {
            var value: UInt32 = 0
            for shift in 0..<4 { value |= UInt32(try u8()) << (8 * shift) }
            return value
        }

        mutating func u64LittleEndian() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in 0..<8 { value |= UInt64(try u8()) << (8 * shift) }
            return value
        }
    }

    // MARK: - Header

    static func header(from reader: inout Reader) throws -> Header {
        guard try reader.u32() == magic else { throw Failure.notLZ }

        let version = try reader.u32()
        let major = version >> 16
        let minor = version & 0xFFFF
        guard major == versionMajor, minor == versionMinor else {
            throw Failure.unsupportedVersion(major: major, minor: minor)
        }

        let rawType = try reader.u32()
        guard let type = ImageType(rawValue: rawType) else {
            throw Failure.unknownImageType(rawType)
        }

        let width = Int(Int32(bitPattern: try reader.u32()))
        let height = Int(Int32(bitPattern: try reader.u32()))
        let stride = Int(Int32(bitPattern: try reader.u32()))
        // The header's dimensions are signed on the wire and a negative one is
        // not a small image, it is a size that becomes enormous the moment it
        // is multiplied. Refused before anything is allocated from it.
        guard width > 0, height > 0, stride >= 0 else { throw Failure.badGeometry }

        return Header(
            type: type, width: width, height: height, stride: stride,
            topDown: try reader.u32() != 0
        )
    }

    // MARK: - Decompression

    /// What one pixel of this type costs, and it is two different numbers.
    ///
    /// `read` is how many bytes a literal pixel takes **out of the stream**;
    /// `written` is how many it occupies in the output. For `rgb32` they differ:
    /// the codec encodes three bytes — blue, green, red — and writes a fourth
    /// zero byte of padding that was never transmitted. Reading four would take
    /// the next pixel's blue as this pixel's padding and shear the whole image
    /// by one byte per pixel.
    ///
    /// `lengthBias` is what a match length is short by, and it is per type: one
    /// for the 24- and 32-bit forms, two for 16-bit, three for the palette
    /// ones. Miss it and every match is a pixel short — an image that is almost
    /// right, which is the worst kind of wrong.
    private static func shape(
        of type: ImageType
    ) throws -> (read: Int, written: Int, lengthBias: Int) {
        switch type {
        case .rgb32: return (3, 4, 1)
        case .rgb24: return (3, 3, 1)
        case .rgb16: return (2, 2, 2)
        case .palette1LE, .palette1BE, .palette4LE, .palette4BE, .palette8:
            // One byte in, one byte out — the palette forms decompress to
            // *indices*, and turning those into pixels is a separate step that
            // needs the palette travelling beside them. Their match length is
            // biased by three, the third distinct bias in this codec.
            return (1, 1, 3)
        case .rgba, .xxxa, .a8:
            // Still not decoded, each for its own reason. `a8` is a mask, not a
            // picture; `rgba` and `xxxa` are encoded as two passes, colour then
            // alpha, so one run of this loop is half an image.
            //
            // Named rather than half-decoded into something that would look
            // like an image.
            throw Failure.unsupportedImageType(type)
        }
    }

    // MARK: - Palettes

    /// A palette as it travels: a cache identifier, a count, and that many
    /// colours.
    ///
    /// Kept as its own type rather than a bare `[UInt32]` because the count is
    /// a number the server chose, and the thing that stops it becoming an
    /// allocation is reading the colours one at a time rather than reserving
    /// for them.
    struct Palette: Equatable, Sendable {
        var unique: UInt64
        var colours: [UInt32]
    }

    static func palette(from reader: inout Reader) throws -> Palette {
        // The palette is little-endian, unlike the LZ stream header above it.
        // It belongs to the display channel's message rather than to the codec,
        // and the display channel is little-endian throughout.
        let unique = try reader.u64LittleEndian()
        let count = Int(try reader.u16LittleEndian())
        var colours: [UInt32] = []
        for _ in 0..<count { colours.append(try reader.u32LittleEndian()) }
        return Palette(unique: unique, colours: colours)
    }

    /// How many pixels one byte of indices holds, for each palette form.
    static func pixelsPerByte(_ type: ImageType) -> Int? {
        switch type {
        case .palette1LE, .palette1BE: return 8
        case .palette4LE, .palette4BE: return 2
        case .palette8: return 1
        default: return nil
        }
    }

    /// Expands decompressed indices into BGRA pixels through a palette.
    ///
    /// The orders here are the two that would have been written backwards, and
    /// each was checked against the reference decoder's own output rather than
    /// against a reading of the template macros:
    ///
    ///   * a 4-bit `LE` byte gives the **low** nibble first, `BE` the **high**;
    ///   * a 1-bit `LE` byte starts at **bit 0**, `BE` at **bit 7**.
    ///
    /// Backwards, either one produces an image — mirrored in pairs of pixels,
    /// or in groups of eight — which is exactly the kind of wrong that ships.
    ///
    /// A palette entry is `0x00RRGGBB` and the output is BGRA, so the bytes come
    /// out low-first with a zero pad: the codec never carries alpha here.
    static func pixels(
        fromIndices indices: [UInt8], type: ImageType, width: Int, height: Int,
        palette: Palette
    ) throws -> [UInt8] {
        guard let perByte = pixelsPerByte(type) else {
            throw Failure.unsupportedImageType(type)
        }
        guard !palette.colours.isEmpty else { throw Failure.missingPalette }

        // Each row starts on a byte boundary: a 5-pixel wide 4-bit image uses
        // three bytes a row, and the sixth pixel of the third byte is padding.
        // Reading straight through would shear every row after the first.
        let bytesPerRow = (width + perByte - 1) / perByte
        guard indices.count >= bytesPerRow * height else { throw Failure.truncated }

        var out: [UInt8] = []
        out.reserveCapacity(width * height * 4)

        for row in 0..<height {
            var written = 0
            for byteIndex in 0..<bytesPerRow {
                let byte = indices[row * bytesPerRow + byteIndex]
                for slot in 0..<perByte where written < width {
                    let index: Int
                    switch type {
                    case .palette8:
                        index = Int(byte)
                    case .palette4LE:
                        index = slot == 0 ? Int(byte & 0x0F) : Int(byte >> 4)
                    case .palette4BE:
                        index = slot == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
                    case .palette1LE:
                        index = Int(byte >> UInt8(slot) & 1)
                    case .palette1BE:
                        index = Int(byte >> UInt8(7 - slot) & 1)
                    default:
                        throw Failure.unsupportedImageType(type)
                    }
                    // Modulo the palette's size, which is what the codec itself
                    // does: an index past the end is a broken image, not a
                    // reason to drop the connection.
                    let colour = palette.colours[index % palette.colours.count]
                    out.append(UInt8(colour & 0xFF))
                    out.append(UInt8(colour >> 8 & 0xFF))
                    out.append(UInt8(colour >> 16 & 0xFF))
                    out.append(0)
                    written += 1
                }
            }
        }
        return out
    }

    /// Decompresses one image into its pixels, in the codec's own byte order.
    ///
    /// The output is whatever the stream's own type says — three bytes for
    /// `rgb24`, four for `rgb32` — and this deliberately does not convert:
    /// turning pixels into a framebuffer's layout is the caller's job, and
    /// folding it in here would mean a decompressor that cannot be checked
    /// against the codec's own output.
    static func decompress(_ payload: [UInt8]) throws -> (header: Header, pixels: [UInt8]) {
        var reader = Reader(payload)
        let header = try header(from: &reader)
        let (bytesRead, bytesPerPixel, lengthBias) = try shape(of: header.type)

        // How many output units the stream holds, which is *not* one per pixel
        // for the palette forms: a 4-bit image packs two pixels into a byte, so
        // an eight-wide row is four bytes and not eight. Demanding one unit per
        // pixel makes every palette stream look truncated — which is exactly
        // what happened before this was written this way.
        //
        // Each row starts on a byte boundary, so the count is per row rather
        // than over the whole image: a five-pixel 4-bit row spends three bytes
        // and wastes half of the third.
        let unitsPerRow: Int
        if let perByte = Self.pixelsPerByte(header.type) {
            unitsPerRow = (header.width + perByte - 1) / perByte
        } else {
            unitsPerRow = header.width
        }
        // The header carries a stride too, and it is deliberately not used: it
        // is the server's number, and the codec's own documentation says it
        // must equal the minimum a row needs. Computing it here means a server
        // cannot size this buffer.
        var out: [UInt8] = []
        out.reserveCapacity(unitsPerRow * header.height * bytesPerPixel)
        let limit = unitsPerRow * header.height * bytesPerPixel

        while out.count < limit {
            let ctrl = Int(try reader.u8())

            guard ctrl >= maxCopy else {
                // A run of literals, biased by one: a control of 0 means one
                // pixel, not none.
                for _ in 0...ctrl {
                    if header.type == .rgb16 {
                        // The codec reads a 16-bit pixel as `(first << 8) |
                        // second` and stores it as a machine word, so on the
                        // little-endian machines this ships to, the two bytes
                        // land in memory the other way round from the stream.
                        // Written out explicitly rather than left to whatever
                        // the host happens to do, so the output is the same
                        // everywhere and a test can say what it should be.
                        let high = try reader.u8()
                        let low = try reader.u8()
                        out.append(low)
                        out.append(high)
                    } else {
                        for _ in 0..<bytesRead { out.append(try reader.u8()) }
                        // The padding byte `rgb32` never transmits.
                        for _ in bytesRead..<bytesPerPixel { out.append(0) }
                    }
                }
                continue
            }

            // A match. The control byte carries three bits of length and five
            // of distance, and both continue into the bytes that follow.
            var length = ctrl >> 5
            var offset = (ctrl & 31) << 8
            length -= 1

            if length == 6 {
                // Length past seven is spelled out in as many bytes as it takes.
                var code: UInt8
                repeat {
                    code = try reader.u8()
                    length += Int(code)
                } while code == 255
            }

            let code = try reader.u8()
            offset += Int(code)

            // The far-distance escape, and the condition is exactly the
            // codec's: the low byte is 255 *and* the five bits from the control
            // byte were all ones. Testing only the 255 would swallow an
            // ordinary distance whose low byte happens to be 255.
            if code == 255, offset - Int(code) == 31 << 8 {
                offset = Int(try reader.u8()) << 8
                offset += Int(try reader.u8())
                offset += maxDistance
            }

            length += lengthBias
            offset += 1

            let backwards = offset * bytesPerPixel
            guard backwards <= out.count else { throw Failure.referenceBeforeStart }

            // Copied one pixel at a time, and on purpose: the match may overlap
            // its own output — a run is encoded as a distance of one — so the
            // bytes being read have to be the bytes just written.
            var source = out.count - backwards
            for _ in 0..<(length * bytesPerPixel) {
                out.append(out[source])
                source += 1
            }
        }

        // A stream that overshot said one thing in the header and another in
        // its body. Refused rather than trimmed: trimming would hand back an
        // image built from a disagreement.
        guard out.count == limit else { throw Failure.truncated }
        return (header, out)
    }
}
