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
        case .rgb16, .rgba, .xxxa,
             .palette1LE, .palette1BE, .palette4LE, .palette4BE, .palette8, .a8:
            // Valid streams this does not decode, each for its own reason. The
            // palette types need the palette travelling beside them and expand
            // one byte into several pixels. `a8` is a mask, not a picture.
            // `rgba` and `xxxa` are encoded as two passes, colour then alpha.
            // `rgb16`'s output pixel is a native `uint16` built from two
            // stream bytes, so its byte order in memory depends on the host —
            // a thing to settle deliberately rather than in passing.
            //
            // Named rather than half-decoded into something that would look
            // like an image.
            throw Failure.unsupportedImageType(type)
        }
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

        let pixelCount = header.width * header.height
        var out: [UInt8] = []
        out.reserveCapacity(pixelCount * bytesPerPixel)
        let limit = pixelCount * bytesPerPixel

        while out.count < limit {
            let ctrl = Int(try reader.u8())

            guard ctrl >= maxCopy else {
                // A run of literals, biased by one: a control of 0 means one
                // pixel, not none.
                for _ in 0...ctrl {
                    for _ in 0..<bytesRead { out.append(try reader.u8()) }
                    // The padding byte `rgb32` never transmits.
                    for _ in bytesRead..<bytesPerPixel { out.append(0) }
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
