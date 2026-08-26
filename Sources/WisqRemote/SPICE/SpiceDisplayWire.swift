import Foundation

/// The display channel's messages, decoded.
///
/// This is the channel the other three exist to serve, and it is the one whose
/// layouts could not be written from memory: its draw messages address their
/// operands by **pointer**, and a decoder that guesses what a pointer is on the
/// wire produces a plausible parser that reads the wrong bytes. So the rules
/// below come from `spice.proto` and from the demarshaller `spice_codegen.py`
/// generates from it, not from recall:
///
///   * a pointer is a `uint32`, four bytes, little-endian like everything else;
///   * its value is an **offset from the start of the message body**, not from
///     the field, and not a length;
///   * `0` means null;
///   * an offset at or past the end of the body is an error, not a clamp.
///
/// Those four lines are the whole reason this file was not written earlier.
///
/// What this does *not* do is draw. It decodes structure — which surface, which
/// rectangle, which clip, which image and in what encoding — and stops at the
/// compressed payloads, which it reports by type and hands on as bytes. QUIC,
/// LZ, GLZ and JPEG are each their own piece of work, and pretending to have
/// them here would mean a decoder that says it understood an image it cannot
/// produce a single pixel of.
enum SpiceDisplayWire {
    // MARK: - Message identifiers
    //
    // From `enums.h`. The gaps are real: the protocol numbers these in blocks
    // and the missing values belong to messages this does not decode yet.

    enum Message: UInt16, Equatable, Sendable {
        case mode = 101
        case mark = 102
        case reset = 103
        case copyBits = 104
        case invalList = 105
        case invalAllPixmaps = 106
        case invalPalette = 107
        case invalAllPalettes = 108
        case streamCreate = 122
        case streamData = 123
        case streamClip = 124
        case streamDestroy = 125
        case streamDestroyAll = 126
        case drawFill = 302
        case drawOpaque = 303
        case drawCopy = 304
        case drawBlend = 305
        case drawBlackness = 306
        case drawWhiteness = 307
        case drawInvers = 308
        case drawRop3 = 309
        case drawStroke = 310
        case drawText = 311
        case drawTransparent = 312
        case drawAlphaBlend = 313
        case surfaceCreate = 314
        case surfaceDestroy = 315
        case streamDataSized = 316
    }

    // MARK: - Geometry

    /// `top`, `left`, `bottom`, `right` — in that order, which is not the order
    /// anyone expects and is the order the protocol uses. Read as
    /// left/top/right/bottom, every rectangle is transposed and every draw
    /// lands somewhere else.
    struct Rect: Equatable, Sendable {
        var top: Int32
        var left: Int32
        var bottom: Int32
        var right: Int32

        var width: Int32 { right - left }
        var height: Int32 { bottom - top }
    }

    struct Point: Equatable, Sendable {
        var x: Int32
        var y: Int32
    }

    /// A clip is either nothing or a list of rectangles.
    ///
    /// `SPICE_CLIP_TYPE_PATH` existed once and was removed from the protocol;
    /// a server still sending it gets refused rather than silently treated as
    /// "no clip", which would draw over parts of the screen the server asked to
    /// keep.
    enum Clip: Equatable, Sendable {
        case none
        case rects([Rect])
    }

    /// The header every draw message begins with: which surface, the bounding
    /// box, and the clip.
    struct Base: Equatable, Sendable {
        var surfaceID: UInt32
        var box: Rect
        var clip: Clip
    }

    // MARK: - Surfaces

    /// Surface pixel formats, by the numbers the protocol assigns. The values
    /// are sparse on purpose — they encode depth in the number.
    enum SurfaceFormat: UInt32, Equatable, Sendable {
        case alpha1 = 1
        case alpha8 = 8
        case rgb16_555 = 16
        case xrgb32 = 32
        case rgb16_565 = 80
        case argb32 = 96
    }

    struct SurfaceCreate: Equatable, Sendable {
        var surfaceID: UInt32
        var width: UInt32
        var height: UInt32
        var format: SurfaceFormat
        var flags: UInt32
    }

    /// The legacy "here is the screen" message, sent before surfaces existed
    /// and still sent first by every server that supports them.
    struct Mode: Equatable, Sendable {
        var width: UInt32
        var height: UInt32
        var bits: UInt32
    }

    // MARK: - Images

    /// One entry of `SPICE_MSG_DISPLAY_INVAL_LIST`.
    struct Resource: Equatable, Sendable {
        var type: UInt8
        var id: UInt64
    }

    /// `SPICE_RES_TYPE_*`. `INVALID` is zero, so pixmaps are one — and a list
    /// can name palettes too, which is why the type is kept rather than every
    /// entry being treated as an image.
    enum ResourceType {
        static let invalid: UInt8 = 0
        static let pixmap: UInt8 = 1
    }

    /// The image descriptor's flags. `SPICE_IMAGE_FLAGS_MASK` is `0x7`.
    ///
    /// `cacheMe` is the server's instruction to keep the picture, and it is set
    /// only when the server's own cache accepted it. `cacheReplaceMe` says the
    /// entry already held under this identifier is being replaced — the server
    /// re-sending losslessly what it had cached lossily — which the cache
    /// handles by storing over the old entry rather than needing its own case.
    enum ImageFlag {
        static let cacheMe: UInt8 = 1 << 0
        static let highBitsSet: UInt8 = 1 << 1
        static let cacheReplaceMe: UInt8 = 1 << 2
    }

    enum ImageType: UInt8, Equatable, Sendable {
        case bitmap = 0
        case quic = 1
        case lzPalette = 100
        case lzRGB = 101
        case glzRGB = 102
        case fromCache = 103
        case surface = 104
        case jpeg = 105
        case fromCacheLossless = 106
        case zlibGlzRGB = 107
        case jpegAlpha = 108
        case lz4 = 109
    }

    enum BitmapFormat: UInt8, Equatable, Sendable {
        case oneBitLE = 1
        case oneBitBE = 2
        case fourBitLE = 3
        case fourBitBE = 4
        case eightBit = 5
        case sixteenBit = 6
        case twentyFourBit = 7
        case thirtyTwoBit = 8
        case rgba = 9
        case eightBitAlpha = 10
    }

    /// The header on every image, whatever its encoding.
    struct ImageDescriptor: Equatable, Sendable {
        var id: UInt64
        var type: ImageType
        var flags: UInt8
        var width: UInt32
        var height: UInt32
    }

    /// An uncompressed bitmap's shape. The pixels themselves are not read here:
    /// `stride` and `y` say how many bytes they occupy, and the caller that
    /// actually paints is the one that should decide whether to copy them.
    struct Bitmap: Equatable, Sendable {
        var format: BitmapFormat
        var flags: UInt8
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        /// Set when the palette lives in the client's cache rather than in this
        /// message.
        var cachedPaletteID: UInt64?
        /// The colour table, when this message carried one. Absent for the
        /// formats that need none, and for the ones that named a cached table
        /// this client does not keep.
        var palette: Palette?

        /// `SPICE_BITMAP_FLAGS_TOP_DOWN`, bit 2.
        ///
        /// **Absent means bottom-up**, the way a Windows DIB is stored: the
        /// first row in the data is the last row on screen. Ignoring it does
        /// not fail, it renders the desktop upside down — and only for the
        /// servers that send it that way.
        var topDown: Bool { flags & 0x04 != 0 }
    }

    /// A colour table, as the display channel carries one.
    ///
    /// Little-endian throughout, unlike the one inside an LZ stream's
    /// big-endian header — they are the same structure read by two different
    /// readers, and this is the channel's.
    ///
    /// The count is a number the server chose, so the colours are appended one
    /// at a time rather than reserved for: a palette claiming sixty-five
    /// thousand entries should run out of bytes, not out of memory.
    struct Palette: Equatable, Sendable {
        var unique: UInt64
        var colours: [UInt32]
    }

    static func palette(from reader: inout SpiceWire.Reader) throws -> Palette {
        let unique = try reader.u64()
        let count = Int(try reader.u16())
        var colours: [UInt32] = []
        for _ in 0..<count { colours.append(try reader.u32()) }
        return Palette(unique: unique, colours: colours)
    }

    /// An image as far as this decoder goes: always its descriptor, its shape
    /// when the encoding is one whose shape is plain, and the codec's own bytes
    /// when it is not.
    ///
    /// `payload` is deliberately undecoded. Reading structure and running a
    /// codec are different jobs with different failure modes, and keeping them
    /// apart is what lets the codecs be tested against their own reference
    /// implementations rather than through a display message.
    struct Image: Equatable, Sendable {
        var descriptor: ImageDescriptor
        var bitmap: Bitmap?
        var payload: [UInt8]?
        /// Where the JPEG ends and the alpha stream begins, for `jpegAlpha`.
        ///
        /// Two codecs share one payload there, and the boundary is a number in
        /// the message rather than something the bytes announce — a JPEG's end
        /// marker would be a guess, and the alpha stream has no magic of its
        /// own that could not also occur inside JPEG data.
        struct JPEGAlpha: Equatable, Sendable {
            /// `SPICE_JPEG_ALPHA_FLAGS_TOP_DOWN`, bit 0. Its own flag word,
            /// not the bitmap one: `TOP_DOWN` is bit 0 here and bit 2 there.
            var topDown: Bool
            var jpegBytes: Int
        }
        var jpegAlpha: JPEGAlpha?

        /// The **inflated** size of a `zlibGlzRGB` payload.
        ///
        /// Its message carries two lengths, which is why this type is not in
        /// the plain "a length and that many bytes" case: `glz_data_size` says
        /// how big the GLZ stream will be once unzipped, and `data_size` says
        /// how many zlib bytes follow. Reading the first as the second gives a
        /// length that is usually larger than the message.
        var inflatedSize: Int?

        /// The colour table for a compressed palettised stream.
        ///
        /// Apart from `bitmap.palette` because the two arrive by different
        /// routes: an uncompressed bitmap carries its table inside its own
        /// structure, while `lzPalette` carries one beside the stream. Merging
        /// them into one field would mean a `Bitmap` invented for an image
        /// that has none.
        var palette: Palette?
    }

    // MARK: - Brushes and masks

    enum Brush: Equatable, Sendable {
        case none
        case solid(UInt32)
        /// The pattern's image and where it is anchored. The image is behind a
        /// pointer like every other one.
        case pattern(image: Image?, origin: Point)
    }

    struct Mask: Equatable, Sendable {
        var flags: UInt8
        var origin: Point
        var bitmap: Image?
    }

    // MARK: - Draw messages

    struct Fill: Equatable, Sendable {
        var base: Base
        var brush: Brush
        var rop: UInt16
        var mask: Mask
    }

    struct Copy: Equatable, Sendable {
        var base: Base
        /// Null when the server refers to an image it has already cached.
        var source: Image?
        var sourceArea: Rect
        var rop: UInt16
        var scaleMode: UInt8
        var mask: Mask
    }

    /// `DRAW_OPAQUE` — a copy with a brush combined onto it.
    ///
    /// The same fields as a copy, with a `Brush` inserted before the rop. What
    /// makes it its own message is not the shape but the order of operations:
    /// the image is blitted *plainly*, and the rop then combines the brush with
    /// it. So the rop's two operands are the brush and the image, and the
    /// destination is not one of them at all.
    struct Opaque: Equatable, Sendable {
        var base: Base
        var source: Image?
        var sourceArea: Rect
        var brush: Brush
        var rop: UInt16
        var scaleMode: UInt8
        var mask: Mask
    }

    /// `DRAW_TRANSPARENT` — a colour-key blit.
    ///
    /// The odd one out among the draws: **it carries no mask and no rop.** Its
    /// whole shape is an image, an area, and two colours — and the reference
    /// reads only the second of those two. `src_color` is in the structure and
    /// `canvas_draw_transparent` never touches it.
    struct Transparent: Equatable, Sendable {
        var base: Base
        var source: Image?
        var sourceArea: Rect
        /// Present in the message and unused by the reference decoder. Kept so
        /// that the field is read rather than skipped by arithmetic.
        var sourceColour: UInt32
        /// The colour that does not get drawn.
        var trueColour: UInt32
    }

    /// `DRAW_ALPHA_BLEND` — the one draw that really composites.
    ///
    /// The flags and the alpha come *before* the image pointer, which no other
    /// draw does: every other one starts with the pointer straight after the
    /// base.
    struct AlphaBlend: Equatable, Sendable {
        /// `SPICE_ALPHA_FLAGS_DEST_HAS_ALPHA`, bit 0: read the destination's
        /// fourth byte as its alpha instead of treating it as opaque.
        static let destinationHasAlpha: UInt8 = 0x01
        /// `SPICE_ALPHA_FLAGS_SRC_SURFACE_HAS_ALPHA`, bit 1. It applies only
        /// when the source is another *surface*; on the image path the
        /// reference never passes it, and neither does this.
        static let sourceSurfaceHasAlpha: UInt8 = 0x02

        var base: Base
        var flags: UInt8
        /// An overall alpha applied on top of the source's own.
        var alpha: UInt8
        var source: Image?
        var sourceArea: Rect

        var readsDestinationAlpha: Bool { flags & Self.destinationHasAlpha != 0 }
    }

    /// How a stream's frames are encoded.
    ///
    /// Only `mjpeg` is decoded. The other four are named rather than lumped
    /// together as "unknown", because a stream this client cannot decode is a
    /// specific thing a user might want told to them — the region freezes, and
    /// "the server chose H.264" is the explanation.
    enum VideoCodec: UInt8, Equatable, Sendable, CaseIterable {
        case mjpeg = 1
        case vp8 = 2
        case h264 = 3
        case vp9 = 4
        case h265 = 5

        /// Whether wisq has a decoder for this codec at all.
        ///
        /// A property rather than a branch buried in `frame(_:codec:)`, and
        /// that is a testability decision worth explaining. On a runner with no
        /// JPEG decoder — which is every Linux runner here — both sides of that
        /// branch return `nil`, so removing it changes nothing observable and a
        /// test cannot tell the two apart. Pulled out here, the decision is a
        /// value, and a test can check all five without decoding anything.
        ///
        /// MJPEG is the only one: each of its frames is a whole JPEG, so it
        /// costs nothing beyond the decoder `.jpeg` images already use. The
        /// other four need a real video decoder — VideoToolbox on Apple, and
        /// nothing wisq ships on Linux.
        var isDecoded: Bool { self == .mjpeg }
    }

    /// `STREAM_CREATE` — the server switching a region to video.
    ///
    /// A SPICE server watches for a rectangle that keeps changing and, past a
    /// threshold, stops sending it as draws and starts sending it as a video
    /// stream. On a desktop playing anything at all, that is where most of the
    /// pixels go — so a client that ignores streams shows a frozen rectangle
    /// exactly where the motion is.
    struct StreamCreate: Equatable, Sendable {
        var surfaceID: UInt32
        var id: UInt32
        /// `SPICE_STREAM_FLAGS_TOP_DOWN` is bit 0 — a *third* flags byte with
        /// its own bit for the same idea. A bitmap's is bit 2 and a
        /// `jpegAlpha`'s is bit 0 of a different byte.
        var flags: UInt8
        var codec: VideoCodec
        var stamp: UInt64
        /// The size of the frames on the wire.
        var streamWidth: UInt32
        var streamHeight: UInt32
        /// The size of the region on the server's screen, which need not match.
        var sourceWidth: UInt32
        var sourceHeight: UInt32
        var destination: Rect
        var clip: Clip

        var topDown: Bool { flags & 0x01 != 0 }
    }

    /// `STREAM_DATA`, and `STREAM_DATA_SIZED` which carries its own geometry.
    struct StreamData: Equatable, Sendable {
        var id: UInt32
        var multimediaTime: UInt32
        /// Present only for the sized form. When it is, it replaces the
        /// stream's own frame size and destination for this frame alone.
        var sized: Sized?
        var frame: [UInt8]

        struct Sized: Equatable, Sendable {
            var width: UInt32
            var height: UInt32
            var destination: Rect
        }
    }

    /// `DRAW_ROP3` — a ternary raster operation over pattern, source and
    /// destination.
    ///
    /// The general case the other draws are special cases of. Its shape is
    /// `DRAW_OPAQUE`'s with a single byte where the rop descriptor was: not a
    /// set of flags this time but an opcode, one of 256.
    struct Rop3: Equatable, Sendable {
        var base: Base
        var source: Image?
        var sourceArea: Rect
        var brush: Brush
        var rop3: UInt8
        var scaleMode: UInt8
        var mask: Mask
    }

    /// `DRAW_COPY_BITS` — the surface copying from itself.
    ///
    /// The smallest draw message in the protocol and one of the most used: a
    /// window scrolling, or moving, is this. There is no image, no brush and no
    /// mask, only where the pixels come from — and because source and
    /// destination are the same surface, they overlap whenever the distance is
    /// smaller than the box.
    struct CopyBits: Equatable, Sendable {
        var base: Base
        var source: Point
    }

    /// `DRAW_BLACKNESS`, `DRAW_WHITENESS` and `DRAW_INVERS`, which have the
    /// same shape and differ only in what they write.
    ///
    /// They are the raster operations that need no operand: black, white, and
    /// the complement of what is already there. A window being cleared before
    /// it repaints is usually one of the first two.
    struct MaskedRaster: Equatable, Sendable {
        enum Operation: Equatable, Sendable {
            case blackness, whiteness, invers
        }

        var base: Base
        var operation: Operation
        var mask: Mask
    }
}
