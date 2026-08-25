import Foundation
import WisqNet

/// Decoding for the display channel's messages.
///
/// Kept apart from the type definitions next door because this is where the
/// judgement is: every function below reads bytes chosen by a server, and the
/// interesting part of each is what it refuses.
extension SpiceDisplayWire {
    /// A message body, and the pointer rule that goes with it.
    ///
    /// SPICE draw messages do not carry their operands inline. They carry a
    /// `uint32` offset from the start of the body, and the operand sits
    /// somewhere else in the same body — usually after the fixed part, but the
    /// protocol does not promise that and a server is free to lay it out any
    /// way it likes. So a body is addressed, not streamed.
    ///
    /// Which makes it a place where a malicious or broken server gets to choose
    /// where this code reads. The rules come from the demarshaller the protocol
    /// generates for itself: null is zero, anything at or past the end is an
    /// error.
    ///
    /// The refusal to follow an offset already on the current path is an
    /// addition, and an honest note about it: no path through this decoder can
    /// cycle today, because an image follows no further pointer and the depth
    /// is at most two. It is here for the messages not decoded yet —
    /// `DRAW_ROP3` and `DRAW_OPAQUE` nest brushes and masks that each carry an
    /// image — where a server could otherwise hand this a structure that
    /// contains itself. The test exercises `follow` directly, because a test
    /// built from a crafted message agreed with the guarded code for an
    /// unrelated reason and proved nothing.
    struct Body {
        let bytes: [UInt8]
        /// Offsets on the path from the message root to where we are now.
        private var following: Set<Int> = []

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func reader(at offset: Int = 0) throws -> SpiceWire.Reader {
            try SpiceWire.Reader(bytes, from: offset)
        }

        /// Resolves a pointer field, or reports that it was null.
        ///
        /// Returns `nil` for a null pointer, which is a normal thing for a
        /// server to send — a fill has no mask, a copy names a cached image —
        /// and is why this is an optional rather than a throw.
        func follow(_ pointer: UInt32) throws -> (reader: SpiceWire.Reader, body: Body)? {
            guard pointer != 0 else { return nil }

            let offset = Int(pointer)
            guard offset < bytes.count else { throw SpiceError.truncated }
            guard !following.contains(offset) else { throw SpiceError.invalidData }

            var nested = self
            nested.following.insert(offset)
            return (try nested.reader(at: offset), nested)
        }
    }

    // MARK: - Geometry

    static func rect(from reader: inout SpiceWire.Reader) throws -> Rect {
        // top, left, bottom, right — the protocol's order, not the usual one.
        Rect(
            top: Int32(bitPattern: try reader.u32()),
            left: Int32(bitPattern: try reader.u32()),
            bottom: Int32(bitPattern: try reader.u32()),
            right: Int32(bitPattern: try reader.u32())
        )
    }

    static func point(from reader: inout SpiceWire.Reader) throws -> Point {
        Point(
            x: Int32(bitPattern: try reader.u32()),
            y: Int32(bitPattern: try reader.u32())
        )
    }

    /// The clip is inline rather than behind a pointer — `@to_ptr` in the
    /// protocol description means the *C struct* holds a pointer, not that the
    /// wire does. Reading it as a pointer would consume four bytes and then
    /// treat a rectangle count as an offset.
    static func clip(from reader: inout SpiceWire.Reader) throws -> Clip {
        switch try reader.u8() {
        case 0:
            return .none
        case 1:
            let count = try reader.u32()
            // Appended one at a time, with no capacity reserved from `count`.
            //
            // That is the whole defence, and it is why there is no bound here.
            // A bound was written — `count` against the bytes remaining — and a
            // sabotage showed it did nothing: the array grows only as reads
            // succeed, and a read past the end throws, so a count of four
            // billion ends on the first iteration either way. The same thing
            // happened with the channel list, where the real hazard was `map`
            // reserving from an untrusted count. Reserve nothing and there is
            // nothing to bound.
            var rects: [Rect] = []
            for _ in 0..<count { rects.append(try rect(from: &reader)) }
            return .rects(rects)
        case let other:
            // `PATH` was type 2 and was removed from the protocol. Treating an
            // unknown clip as "no clip" would draw over the parts of the screen
            // the server asked to be left alone.
            _ = other
            throw SpiceError.invalidData
        }
    }

    static func base(from reader: inout SpiceWire.Reader) throws -> Base {
        Base(
            surfaceID: try reader.u32(),
            box: try rect(from: &reader),
            clip: try clip(from: &reader)
        )
    }

    // MARK: - Whole messages

    static func mode(_ payload: [UInt8]) throws -> Mode {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return Mode(width: try reader.u32(), height: try reader.u32(), bits: try reader.u32())
    }

    static func surfaceCreate(_ payload: [UInt8]) throws -> SurfaceCreate {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let surfaceID = try reader.u32()
        let width = try reader.u32()
        let height = try reader.u32()
        let rawFormat = try reader.u32()
        guard let format = SurfaceFormat(rawValue: rawFormat) else {
            // A format this client cannot lay out is named rather than guessed
            // at: guessing means every pixel afterwards is wrong, and wrong in
            // a way that still fills the screen with something.
            throw SpiceError.invalidData
        }
        return SurfaceCreate(
            surfaceID: surfaceID, width: width, height: height,
            format: format, flags: try reader.u32()
        )
    }

    static func surfaceDestroy(_ payload: [UInt8]) throws -> UInt32 {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return try reader.u32()
    }

    // MARK: - Images

    static func image(at pointer: UInt32, in body: Body) throws -> Image? {
        guard let (found, nested) = try body.follow(pointer) else { return nil }
        var reader = found

        let id = try reader.u64()
        let rawType = try reader.u8()
        guard let type = ImageType(rawValue: rawType) else { throw SpiceError.invalidData }
        let descriptor = ImageDescriptor(
            id: id,
            type: type,
            flags: try reader.u8(),
            width: try reader.u32(),
            height: try reader.u32()
        )

        // The compressed forms whose message shape is a plain length and that
        // many bytes. Their *contents* are the codec's business and are not
        // touched here — reading fields out of a QUIC or LZ payload would be
        // inventing a layout — but the length is the display channel's, so it
        // is read here and the bytes are carried out whole.
        //
        // The types left out are the ones whose message shape is not this:
        // `jpegAlpha` carries extra fields before its data, `zlibGlzRGB`
        // carries an uncompressed size, `fromCache` and `surface` name
        // something the client already has rather than carrying an image.
        // Each is named rather than read with the wrong shape.
        switch type {
        case .quic, .lzRGB, .glzRGB, .jpeg, .lz4:
            let size = try reader.u32()
            return Image(
                descriptor: descriptor,
                bitmap: nil,
                payload: try reader.bytes(Int(size))
            )

        case .zlibGlzRGB:
            // Two lengths, and they are not interchangeable: the first is how
            // big the GLZ stream will be once unzipped, the second how many
            // zlib bytes are actually here.
            let inflated = Int(try reader.u32())
            let size = Int(try reader.u32())
            return Image(
                descriptor: descriptor,
                bitmap: nil,
                payload: try reader.bytes(size),
                inflatedSize: inflated
            )

        case .jpegAlpha:
            // Its own shape again, and a different flag word from the bitmap's:
            // `TOP_DOWN` is bit 0 here where it is bit 2 there.
            let flags = try reader.u8()
            let jpegBytes = Int(try reader.u32())
            let size = Int(try reader.u32())
            guard jpegBytes <= size else { throw SpiceError.invalidData }
            return Image(
                descriptor: descriptor,
                bitmap: nil,
                payload: try reader.bytes(size),
                jpegAlpha: SpiceDisplayWire.Image.JPEGAlpha(
                    topDown: flags & 0x01 != 0, jpegBytes: jpegBytes
                )
            )

        case .lzPalette:
            // Its own shape: flags, then the size, then the colour table one
            // way or the other, and only then the stream. Read with the plain
            // shape above, the size would come out of the flags byte.
            let flags = try reader.u8()
            let size = Int(try reader.u32())
            var palette: SpiceDisplayWire.Palette?
            if flags & 0x02 != 0 {
                // Named from a cache this client does not keep. The stream is
                // still read so the message stays in step, but there are no
                // colours to draw it with.
                _ = try reader.u64()
            } else if let (found, _) = try nested.follow(try reader.u32()) {
                var paletteReader = found
                palette = try SpiceDisplayWire.palette(from: &paletteReader)
            }
            return Image(
                descriptor: descriptor,
                bitmap: nil,
                payload: try reader.bytes(size),
                palette: palette
            )

        case .bitmap:
            break

        default:
            _ = nested
            return Image(descriptor: descriptor, bitmap: nil, payload: nil)
        }

        let rawFormat = try reader.u8()
        guard let format = BitmapFormat(rawValue: rawFormat) else { throw SpiceError.invalidData }
        let flags = try reader.u8()
        let width = try reader.u32()
        let height = try reader.u32()
        let stride = try reader.u32()

        // `PAL_FROM_CACHE` is bit 1. Set, the palette is an identifier naming
        // a table this client does not keep; clear, it is a pointer, and one
        // that is genuinely null for the formats that need no colour table.
        let paletteFromCache = flags & 0x02 != 0
        let cachedPaletteID = paletteFromCache ? try reader.u64() : nil
        var palette: SpiceDisplayWire.Palette?
        if !paletteFromCache, let (found, _) = try body.follow(try reader.u32()) {
            var paletteReader = found
            palette = try SpiceDisplayWire.palette(from: &paletteReader)
        }

        // The pixels follow inline, here, rather than behind a pointer — the
        // one place in this message where bulk data is not pointed at. Their
        // length is `stride × height`: the server's stride, because unlike the
        // LZ header's it is the real distance between rows and rows are padded
        // to it.
        //
        // Multiplied as `Int` after both are widened, so a server sending a
        // stride and a height that overflow a `UInt32` gets a read past the
        // end rather than a small number and a buffer that fits.
        let size = Int(stride) * Int(height)

        return Image(
            descriptor: descriptor,
            bitmap: Bitmap(
                format: format, flags: flags, width: width, height: height,
                stride: stride, cachedPaletteID: cachedPaletteID, palette: palette
            ),
            payload: try reader.bytes(size)
        )
    }

    /// Runs the codec on an image's payload, when it is one wisq decodes.
    ///
    /// Returns `nil` rather than throwing for an encoding that is simply not
    /// implemented yet: the caller's answer to "no pixels this time" is to
    /// leave that part of the screen alone, which is a different thing from
    /// "this message was malformed" and should not travel as the same error.
    ///
    /// `glzRGB` is refused rather than handed to the LZ decoder, for two
    /// reasons and not the one that looks obvious.
    ///
    /// The first is that its matches reach back into a dictionary built from
    /// *earlier images on the channel*, so decoding one on its own produces a
    /// picture assembled from whatever happened to be in memory. Sharing the
    /// entry point would be the kind of mistake that shows a plausible image.
    ///
    /// The second is that **the two headers are not the same**, which this
    /// comment used to claim they were. `lz_encode` writes seven 32-bit words
    /// — magic, version, type, width, height, stride, top_down — and leaves a
    /// note wondering whether type and top_down could share a byte. GLZ's
    /// `decode_header` does exactly that, and then adds the image `id` as 64
    /// bits and `win_head_dist` as 32 more: 33 bytes against 28, laid out
    /// differently. The LZ reader would take GLZ's packed byte for a full word
    /// and every field after it would be wrong.
    /// `zlibGlzRGB`: a GLZ stream with zlib wrapped round it.
    ///
    /// Nothing about GLZ changes — `canvas_get_zlib_glz_rgb` inflates and then
    /// calls the very same GLZ path — so this unwraps and delegates.
    ///
    /// **A fresh inflater per image, deliberately.** `decode-zlib.c` calls
    /// `inflateReset` at the top of every image, so each one is compressed
    /// independently and no dictionary carries across them. wisq's
    /// `InflateStream` was built for RFB's Zlib and ZRLE, where the dictionary
    /// *does* carry, and reusing one here would decode the first image
    /// correctly and corrupt the second — a plausible picture. A new stream has
    /// exactly the reference's semantics; the cost is a zlib init per image,
    /// which is microseconds against a decode.
    ///
    /// Stricter than the reference in one place: it warns and keeps whatever
    /// was written when the inflate falls short, and this refuses. A stream
    /// that does not produce the size its own message promised is a malformed
    /// message, not a picture.
    private static func pixels(
        ofZlibGLZ image: Image, glzWindow window: inout SpiceGLZ.Window
    ) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let payload = image.payload, let inflatedSize = image.inflatedSize else {
            return nil
        }
        // Bounded before anything is allocated from it: the size is the
        // message's word and the message is the network's.
        guard inflatedSize > 0, inflatedSize <= 1 << 28 else { return nil }

        let inflated = try InflateStream().inflate(Data(payload))
        guard inflated.count == inflatedSize else { return nil }

        var unwrapped = image
        unwrapped.descriptor.type = .glzRGB
        unwrapped.payload = [UInt8](inflated)
        unwrapped.inflatedSize = nil
        return try pixels(of: unwrapped, glzWindow: &window)
    }

    /// The same, for a channel that keeps a GLZ window.
    ///
    /// GLZ is the one codec whose entry point cannot be static: a stream means
    /// nothing without the images that came before it on the same channel. So
    /// the window is threaded in, and every image decoded through here is added
    /// to it — including images of other codecs? **No**, and that is worth
    /// being explicit about: only GLZ images enter the window, because only GLZ
    /// streams are ever referenced by later ones. The reference does the same;
    /// `glz_decoder_window_add` is called from the GLZ decoder alone.
    ///
    /// Everything else is handed to `pixels(of:)` unchanged.
    static func pixels(
        of image: Image, glzWindow window: inout SpiceGLZ.Window
    ) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        switch image.descriptor.type {
        case .glzRGB: break
        case .zlibGlzRGB:
            return try pixels(ofZlibGLZ: image, glzWindow: &window)
        default:
            return try pixels(of: image)
        }
        guard let payload = image.payload else { return nil }

        let header = try SpiceGLZ.header(payload)
        // `rgb24` goes through the same loop, and that is the reference's
        // arrangement rather than a shortcut: `DECODE_TO_RGB32` sends types 7,
        // 8 and 9 all to `glz_rgb32_decode`. An rgb24 literal is three bytes on
        // the wire exactly as an rgb32 one is; only the *output* width differed
        // between the two templates, and spice-gtk always decodes to 32 bits.
        // Checked with an rgb24 fixture rather than taken on trust.
        //
        // The palette forms are refused, and **not** because they are unfinished
        // work. Nothing produces them.
        //
        // `canvas_get_glz_rgb_common` passes `NULL` where the palette would go,
        // with the reason written above it: a palettised bitmap is compressed
        // to RGB32 globally, "because same byte sequence can be transformed to
        // different RGB pixels by different plts" — which is exactly what a
        // dictionary shared across images cannot survive. The server agrees
        // from its own side: `get_compression_for_bitmap` downgrades GLZ to
        // plain LZ whenever `bitmap_fmt_has_graduality` is false, and that
        // predicate requires an RGB format, which no palettised one is.
        //
        // So the palette variants exist in spice-gtk's template only because it
        // is instantiated mechanically for every type. They are refused here
        // for the same reason the reference has no palette to hand them, and a
        // stream claiming one is a stream no honest server sent.
        let literal: SpiceGLZ.Literal
        switch header.type {
        case .rgb32, .rgb24: literal = .threeBytes
        case .rgb16: literal = .fiveFiveFive
        case .rgba: literal = .threeBytes      // the colour pass; alpha follows
        default: return nil
        }
        guard header.width == Int(image.descriptor.width),
              header.height == Int(image.descriptor.height) else { return nil }

        let pixelCount = header.width * header.height
        var decoded = try SpiceGLZ.decodeRGB32(
            payload, from: SpiceGLZ.headerBytes, pixels: pixelCount,
            imageID: header.id, window: window, literal: literal
        )

        // `rgba` is two passes over one buffer: the colour, then the alpha
        // starting exactly where the colour stopped, with its own control
        // bytes and its own matches. `decode()` in the reference does the same,
        // advancing `in_now` by what the first pass reported.
        if header.type == .rgba {
            decoded = try SpiceGLZ.decodeRGB32(
                payload, from: SpiceGLZ.headerBytes + decoded.bytesRead,
                pixels: pixelCount, imageID: header.id, window: window,
                literal: .alpha, into: decoded.pixels
            )
        }

        window.add(SpiceGLZ.Window.Image(
            id: header.id, winHeadDistance: header.winHeadDistance,
            pixels: decoded.pixels, width: header.width, height: header.height
        ))
        window.releaseAfterAdding()

        // GLZ's own rows are stored the way the stream says, and `top_down` is
        // in its header rather than in the flags beside it.
        return (
            rowsTopDown(
                decoded.pixels, width: header.width, height: header.height,
                bytesPerPixel: 4, alreadyTopDown: header.topDown
            ),
            header.width, header.height
        )
    }

    static func pixels(of image: Image) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let payload = image.payload else { return nil }
        switch image.descriptor.type {
        case .lzRGB:
            let (header, pixels) = try SpiceLZ.decompress(payload)
            let bytesPerPixel = pixels.count / max(header.width * header.height, 1)
            // The stream says which way up it is, and until now nothing asked.
            // A bottom-up stream decoded as if it were top-down is not a
            // failure, it is the desktop upside down.
            return (
                rowsTopDown(
                    pixels, width: header.width, height: header.height,
                    bytesPerPixel: bytesPerPixel, alreadyTopDown: header.topDown
                ),
                header.width, header.height
            )

        case .lzPalette:
            // The colours are the message's, the indices are the codec's, and
            // the orientation is the *stream's* — not the flags beside it. A
            // reader who takes `TOP_DOWN` from the outer flags gets palettised
            // images upside down and nothing else, which is a bug that hides
            // behind whichever encoding the server happens to pick.
            guard let palette = image.palette else { return nil }
            let (header, indices) = try SpiceLZ.decompress(payload)
            let pixels = try SpiceLZ.pixels(
                fromIndices: indices, type: header.type,
                width: header.width, height: header.height,
                palette: SpiceLZ.Palette(unique: palette.unique, colours: palette.colours)
            )
            return (
                rowsTopDown(
                    pixels, width: header.width, height: header.height,
                    bytesPerPixel: 4, alreadyTopDown: header.topDown
                ),
                header.width, header.height
            )

        case .jpeg:
            // Nil rather than a throw where there is no decoder: a platform
            // without ImageIO leaves that part of the screen alone, which is
            // "not drawn this time" and not "this message was malformed".
            guard JPEGDecoder.isAvailable,
                  let decoded = try? JPEGDecoder.decode(Data(payload)) else { return nil }
            return (decoded.bgra, decoded.width, decoded.height)

        case .jpegAlpha:
            guard let shape = image.jpegAlpha, SpiceJPEGAlphaDecoder.isAvailable else { return nil }
            guard let decoded = try SpiceJPEGAlphaDecoder.pixels(payload, shape: shape) else {
                return nil
            }
            return (
                rowsTopDown(
                    decoded.pixels, width: decoded.width, height: decoded.height,
                    bytesPerPixel: 4, alreadyTopDown: shape.topDown
                ),
                decoded.width, decoded.height
            )

        case .quic:
            let decoded = try SpiceQUIC.decode(payload)
            // **No flip.** QUIC is the one compressed form that carries no
            // orientation at all: its header stops at type, width and height,
            // and `canvas_get_quic` consults no flag and reverses nothing. LZ
            // takes it from the inner stream and `jpegAlpha` from its own flag
            // byte; here there is nothing to take, and reading `TOP_DOWN` from
            // the bitmap flags beside it would invent one.
            //
            // The size must agree with what the message already said. The
            // reference asserts exactly this before it allocates, and a
            // disagreement means the two halves describe different pictures.
            //
            // One deliberate difference from `canvas_get_quic`: it refuses
            // `gray` outright, with the "should not be reached" warning that
            // says the SPICE developers expect no server to send it. That
            // refusal is a limit of its pixman path, which has no gray format
            // to draw into, not a rule of the protocol. This decoder produces
            // BGRA from gray like everything else, checked against the
            // reference *decoder* byte for byte, so it is drawn rather than
            // dropped. If the warning is right the case never arises; if it is
            // wrong, a picture is better than a hole in the screen.
            guard decoded.width == Int(image.descriptor.width),
                  decoded.height == Int(image.descriptor.height) else { return nil }
            return decoded

        case .lz4:
            // The geometry comes from the descriptor because the LZ4 header has
            // none, and the conversion is `SpiceBitmap`'s because what comes out
            // of the blocks is exactly a bitmap: packed rows, a `bitmap_fmt`,
            // and a direction. Building a synthetic `Bitmap` rather than
            // repeating four format conversions here is not tidiness — it is
            // that the 0555 expansion and the "the fourth byte of xRGB is not
            // alpha" rule are already written once and already tested, and a
            // second copy of them is a second thing to get wrong.
            //
            // The stride is `width × bytes-per-pixel` with no padding. That is
            // the encoder's layout, not an assumption: `canvas_fix_alignment`
            // exists in the reference solely to spread those packed rows out to
            // pixman's wider stride afterwards.
            let width = Int(image.descriptor.width)
            let height = Int(image.descriptor.height)
            let decoded = try SpiceLZ4.decode(payload, width: width, height: height)
            guard let bytesPerPixel = SpiceLZ4.bytesPerPixel(decoded.header.format) else {
                return nil
            }
            return (
                try SpiceBitmap.pixels(
                    Bitmap(
                        format: decoded.header.format,
                        flags: decoded.header.topDown ? 0x04 : 0,
                        width: UInt32(width), height: UInt32(height),
                        stride: UInt32(width * bytesPerPixel),
                        cachedPaletteID: nil, palette: nil
                    ),
                    data: decoded.rows
                ),
                width, height
            )

        case .bitmap:
            guard let bitmap = image.bitmap else { return nil }
            // `pixels(_:data:)` puts the rows the right way up itself: it reads
            // the stride, and flipping afterwards would need it again.
            return (
                try SpiceBitmap.pixels(bitmap, data: payload),
                Int(bitmap.width), Int(bitmap.height)
            )

        default:
            return nil
        }
    }

    /// Reverses the row order when an image says it is stored bottom-up.
    ///
    /// Whole rows rather than a transform on coordinates, because the caller
    /// copies rectangles out of this buffer and would otherwise have to carry
    /// the orientation along with it — which is the sort of thing that is
    /// remembered in three places out of four.
    static func rowsTopDown(
        _ pixels: [UInt8], width: Int, height: Int,
        bytesPerPixel: Int, alreadyTopDown: Bool
    ) -> [UInt8] {
        let rowSize = width * bytesPerPixel
        guard !alreadyTopDown, height > 1, rowSize > 0,
              pixels.count >= rowSize * height else { return pixels }

        var out = [UInt8]()
        out.reserveCapacity(pixels.count)
        for row in (0..<height).reversed() {
            out += pixels[(row * rowSize)..<((row + 1) * rowSize)]
        }
        return out
    }

    static func brush(from reader: inout SpiceWire.Reader, in body: Body) throws -> Brush {
        switch try reader.u8() {
        case 0:
            return .none
        case 1:
            return .solid(try reader.u32())
        case 2:
            let pointer = try reader.u32()
            return .pattern(image: try image(at: pointer, in: body),
                            origin: try point(from: &reader))
        default:
            throw SpiceError.invalidData
        }
    }

    static func mask(from reader: inout SpiceWire.Reader, in body: Body) throws -> Mask {
        let flags = try reader.u8()
        let origin = try point(from: &reader)
        let pointer = try reader.u32()
        return Mask(flags: flags, origin: origin, bitmap: try image(at: pointer, in: body))
    }

    // MARK: - Draw messages

    static func fill(_ payload: [UInt8]) throws -> Fill {
        let body = Body(payload)
        var reader = try body.reader()
        return Fill(
            base: try base(from: &reader),
            brush: try brush(from: &reader, in: body),
            rop: try reader.u16(),
            mask: try mask(from: &reader, in: body)
        )
    }

    /// `DRAW_OPAQUE`: a copy's fields with a brush wedged in before the rop.
    ///
    /// Reading it with the copy decoder would take the brush's type byte for
    /// the low half of the rop and every field after it would be shifted.
    static func opaque(_ payload: [UInt8]) throws -> Opaque {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let sourcePointer = try reader.u32()
        return Opaque(
            base: header,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader),
            brush: try brush(from: &reader, in: body),
            rop: try reader.u16(),
            scaleMode: try reader.u8(),
            mask: try mask(from: &reader, in: body)
        )
    }

    /// `DRAW_TRANSPARENT`: image, area, and two colour words.
    ///
    /// Shorter than every other draw with an image in it — no rop, no scale
    /// mode, no mask — so a decoder that assumed the copy layout would read two
    /// colours where the rop and scale mode belong and then run off the end.
    static func transparent(_ payload: [UInt8]) throws -> Transparent {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let sourcePointer = try reader.u32()
        return Transparent(
            base: header,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader),
            sourceColour: try reader.u32(),
            trueColour: try reader.u32()
        )
    }

    /// `DRAW_ALPHA_BLEND`: **two bytes before the image pointer.**
    ///
    /// Every other draw with an image puts the pointer straight after the base.
    /// This one puts the flags and the alpha first, so a decoder reusing the
    /// copy reader takes those two bytes plus the first two of the pointer as
    /// the pointer, and follows an offset into the middle of the message.
    static func alphaBlend(_ payload: [UInt8]) throws -> AlphaBlend {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let flags = try reader.u8()
        let alpha = try reader.u8()
        let sourcePointer = try reader.u32()
        return AlphaBlend(
            base: header, flags: flags, alpha: alpha,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader)
        )
    }

    /// `DRAW_ROP3`: `DRAW_OPAQUE`'s shape with one byte where its two-byte rop
    /// descriptor was.
    ///
    /// One byte rather than two, so reading it with the opaque decoder would
    /// take the scale mode as the descriptor's high half and shift the mask.
    static func rop3(_ payload: [UInt8]) throws -> Rop3 {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let sourcePointer = try reader.u32()
        return Rop3(
            base: header,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader),
            brush: try brush(from: &reader, in: body),
            rop3: try reader.u8(),
            scaleMode: try reader.u8(),
            mask: try mask(from: &reader, in: body)
        )
    }

    /// `DRAW_COPY_BITS`: the base, and then two words that are a point.
    ///
    /// Read as a rectangle by mistake it would consume sixteen bytes instead of
    /// eight — and there is nothing after it in the message to notice.
    static func copyBits(_ payload: [UInt8]) throws -> CopyBits {
        let body = Body(payload)
        var reader = try body.reader()
        return CopyBits(base: try base(from: &reader), source: try point(from: &reader))
    }

    /// The three operand-free rasters. One reader, because the wire shape is
    /// identical and only the message type tells them apart.
    static func maskedRaster(
        _ payload: [UInt8], _ operation: MaskedRaster.Operation
    ) throws -> MaskedRaster {
        let body = Body(payload)
        var reader = try body.reader()
        return MaskedRaster(
            base: try base(from: &reader),
            operation: operation,
            mask: try mask(from: &reader, in: body)
        )
    }

    static func copy(_ payload: [UInt8]) throws -> Copy {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let sourcePointer = try reader.u32()
        return Copy(
            base: header,
            source: try image(at: sourcePointer, in: body),
            sourceArea: try rect(from: &reader),
            rop: try reader.u16(),
            scaleMode: try reader.u8(),
            mask: try mask(from: &reader, in: body)
        )
    }
}
