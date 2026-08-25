import Foundation

/// SPICE's GLZ codec — the *global* LZ — decoding side, starting at its header.
///
/// GLZ is LZ with one addition that changes everything about how it has to be
/// decoded: a match may reach back not just into the image being decoded but
/// into an **earlier image on the same channel**. So a GLZ stream is not
/// self-contained. Handing one to the LZ decoder produces a picture assembled
/// from whatever happened to be in memory — a plausible image, and the worst
/// kind of wrong.
///
/// That is why this arrives in slices, and why the first slice is only the
/// header. The header is the one part that *is* self-contained, so it is the
/// one part that can be checked exactly before any window exists.
///
/// **GLZ does not live where LZ and QUIC live.** `lz.c` and `quic.c` are both
/// in `spice-common`; GLZ's decoder is in spice-gtk (`src/decode-glz.c`) and
/// its encoder is in spice-server (`server/glz-encoder.c`). Written from those,
/// not from the shape of the LZ code next door.
enum SpiceGLZ {
    /// The header is **not** LZ's, and the difference is not a detail.
    ///
    /// `lz_encode` writes seven 32-bit words — magic, version, type, width,
    /// height, stride, top_down — 28 bytes, and leaves a comment wondering
    /// whether type and top_down could share a byte. GLZ's `decode_header`
    /// does share them, in one byte where the low nibble is the type and the
    /// bit above it is `top_down`, and then adds two fields LZ has no notion
    /// of: the image's `id` as 64 bits and `winHeadDistance` as 32 more.
    ///
    /// 33 bytes against 28, laid out differently. An LZ reader pointed at a
    /// GLZ stream takes the packed byte for a whole word and misreads every
    /// field after it — while still finding the right magic, so the mistake
    /// survives the first check.
    struct Header: Equatable, Sendable {
        var type: SpiceLZ.ImageType
        var width: Int
        var height: Int
        var stride: Int
        var topDown: Bool
        /// This image's own id. The window is indexed by it.
        var id: UInt64
        /// How far back the oldest image this stream may still reach into is.
        /// The reference releases everything older than `id - winHeadDistance`
        /// once the gap closes.
        var winHeadDistance: UInt32
    }

    /// How many bytes `header(_:)` consumes. Named because the match loop needs
    /// to start exactly here and an off-by-one is a stream that decodes to
    /// nonsense rather than to an error.
    static let headerBytes = 33

    enum Failure: Error, Equatable {
        case notGLZ
        case unsupportedVersion(major: UInt32, minor: UInt32)
        case unknownImageType(UInt32)
        case badGeometry
        case truncated
        /// A local match reaching back before the start of the output, or a
        /// cross-image one reaching past the end of the image it names.
        case referenceBeforeStart
        /// A match naming an image the window no longer holds. Named rather
        /// than filled with whatever sits in that slot: the slot is
        /// `id % capacity`, so the wrong image is a real image.
        case referenceOutsideTheWindow
    }

    /// Reads a GLZ stream header.
    ///
    /// Big-endian throughout, like LZ's and unlike the display channel that
    /// carries it, so it borrows LZ's reader rather than `SpiceWire.Reader`.
    static func header(_ bytes: [UInt8]) throws -> Header {
        var reader = SpiceLZ.Reader(bytes)
        do {
            return try header(from: &reader)
        } catch let error as SpiceLZ.Failure where error == .truncated {
            throw Failure.truncated
        }
    }

    static func header(from reader: inout SpiceLZ.Reader) throws -> Header {
        guard try reader.u32() == SpiceLZ.magic else { throw Failure.notGLZ }

        let version = try reader.u32()
        let major = version >> 16
        let minor = version & 0xFFFF
        guard major == SpiceLZ.versionMajor, minor == SpiceLZ.versionMinor else {
            throw Failure.unsupportedVersion(major: major, minor: minor)
        }

        // One byte for both. `LZ_IMAGE_TYPE_MASK` is the low four bits and
        // `LZ_IMAGE_TYPE_LOG` is 4, so the flag is the bit just above the type
        // rather than the top bit of the byte.
        let packed = try reader.u8()
        let rawType = UInt32(packed & 0x0F)
        guard let type = SpiceLZ.ImageType(rawValue: rawType) else {
            throw Failure.unknownImageType(rawType)
        }
        let topDown = (packed >> 4) & 0x01 != 0

        let width = Int(Int32(bitPattern: try reader.u32()))
        let height = Int(Int32(bitPattern: try reader.u32()))
        let stride = Int(Int32(bitPattern: try reader.u32()))
        // Signed on the wire, and a negative one is not a small image — it is a
        // size that becomes enormous the moment it is multiplied. Refused
        // before anything is allocated from it.
        guard width > 0, height > 0, stride >= 0 else { throw Failure.badGeometry }

        var id: UInt64 = 0
        for _ in 0..<8 { id = id << 8 | UInt64(try reader.u8()) }

        return Header(
            type: type, width: width, height: height, stride: stride,
            topDown: topDown, id: id, winHeadDistance: try reader.u32()
        )
    }
}
