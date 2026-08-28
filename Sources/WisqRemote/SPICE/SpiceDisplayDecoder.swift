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

    // MARK: - Invalidations

    /// `SPICE_MSG_DISPLAY_INVAL_LIST` — what the server has dropped.
    ///
    /// A `uint16` count, then that many `ResourceID`: a `uint8` type and a
    /// `uint64` identifier, **nine bytes with no padding between them**. Read
    /// as a naturally aligned struct the second entry would start one byte
    /// early and every identifier after the first would be nonsense.
    static func invalidations(_ payload: [UInt8]) throws -> [Resource] {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let count = Int(try reader.u16())
        var resources = [Resource]()
        resources.reserveCapacity(count)
        for _ in 0..<count {
            resources.append(Resource(type: try reader.u8(), id: try reader.u64()))
        }
        return resources
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
            var cachedPaletteID: UInt64?
            if flags & SpiceDisplayWire.BitmapFlag.paletteFromCache != 0 {
                // Named from the palette cache rather than carried. The
                // identifier is kept, not discarded: `pixels(of:caches:)`
                // resolves it. Reading and dropping it is what this did while
                // there was no cache, and it cost the colours of every such
                // image.
                cachedPaletteID = try reader.u64()
            } else if let (found, _) = try nested.follow(try reader.u32()) {
                var paletteReader = found
                palette = try SpiceDisplayWire.palette(from: &paletteReader)
            }
            return Image(
                descriptor: descriptor,
                bitmap: nil,
                payload: try reader.bytes(size),
                palette: palette,
                cachedPaletteID: cachedPaletteID,
                paletteCacheMe: flags & SpiceDisplayWire.BitmapFlag.paletteCacheMe != 0
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
        // a table in the client's palette cache; clear, it is a pointer, and
        // one that is genuinely null for the formats that need no colour table.
        let paletteFromCache = flags & SpiceDisplayWire.BitmapFlag.paletteFromCache != 0
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
        // Widening to `Int` first defeats the `UInt32` wraparound — a server
        // sending a stride and a height whose product wraps would otherwise get
        // a small number and a buffer that fits. That much the previous
        // comment here had right. What it missed is that widening does not
        // defeat `Int` overflow: both fields reach `0xFFFFFFFF`, so the product
        // reaches 1.8 × 10^19, past `Int.max`, and Swift traps. **The defence
        // was the crash site**, and twelve bytes on the wire reached it.
        //
        // Reported rather than bounded, and the difference matters. A ceiling
        // here would be a guess about what a real server sends; this is not a
        // guess about anything. Every product that fits an `Int` is unchanged,
        // and one that does not is refused — which is what an oversized `size`
        // already gets from `reader.bytes` a line later, since no message holds
        // that many bytes. The behaviour is identical everywhere it was defined.
        let (size, sizeOverflowed) = Int(stride).multipliedReportingOverflow(by: Int(height))
        guard !sizeOverflowed else { throw SpiceError.invalidData }

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

        // The message's own promise, used as the ceiling rather than only as
        // the thing compared afterwards. The comment above said this was
        // "bounded before anything is allocated from it"; that bounded the
        // *declared* size, and the inflate below could produce a hundred
        // times it before the comparison ran.
        let inflated = try InflateStream().inflate(Data(payload), limit: inflatedSize)
        guard inflated.count == inflatedSize else { return nil }

        var unwrapped = image
        unwrapped.descriptor.type = .glzRGB
        unwrapped.payload = [UInt8](inflated)
        unwrapped.inflatedSize = nil
        return try pixels(of: unwrapped, glzWindow: &window)
    }

    /// The entry point the drawing paths use: decodes, and remembers.
    ///
    /// Two things happen here that `pixels(of:glzWindow:)` deliberately does
    /// not do, because both are about what this *connection* holds rather than
    /// about any codec.
    ///
    /// **A name is resolved rather than decoded.** `fromCache` and
    /// `fromCacheLossless` carry an identifier and no pixels at all — the
    /// server has decided this client kept the picture. `nil` here means it did
    /// not, and the draw is skipped; that is the failure the declared cache
    /// size exists to make impossible, not something to paper over.
    ///
    /// **An image the server asked us to keep is kept.** `CACHE_ME` is bit 0 of
    /// the descriptor's flags, and it is set on the wire only when the server's
    /// own add succeeded — `marshal_lossy_or_lossless` sets it *after*
    /// `dcc_pixmap_cache_unlocked_add` returns true. So it is a precise
    /// instruction, not a hint, and caching anything else would fill a phone
    /// with pictures nothing will ask for again.
    ///
    /// The two cache types differ only in what the server promises about
    /// fidelity: `FROM_CACHE_LOSSLESS` says the entry has been replaced with a
    /// lossless version. Both name the same table, so both read it the same way.
    static func pixels(
        of image: Image, caches: inout SpiceDisplayCaches
    ) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        switch image.descriptor.type {
        case .fromCache, .fromCacheLossless:
            guard let held = caches.pixmaps.image(image.descriptor.id) else { return nil }
            return (held.pixels, held.width, held.height)
        default:
            break
        }

        // The colour table may be a name too, and by a different mechanism:
        // the server keeps its own palette cache of a size it never asks about
        // (`CLIENT_PALETTE_CACHE_SIZE`), so there is no declining this one.
        guard let resolved = resolvingPalette(image, in: &caches.palettes) else { return nil }
        guard let decoded = try pixels(of: resolved, glzWindow: &caches.glz) else { return nil }

        if image.descriptor.flags & ImageFlag.cacheMe != 0 {
            // The dimensions stored are the ones actually decoded rather than
            // the descriptor's. They agree for every image a server sends; if
            // they ever did not, holding the count that matches the pixels is
            // the one that keeps this cache's own budget honest.
            caches.pixmaps.store(image.descriptor.id, SpicePixmapCache.Entry(
                pixels: decoded.pixels, width: decoded.width, height: decoded.height
            ))
        }
        return decoded
    }

    /// Puts a named colour table back on an image, and keeps one the server
    /// asked to be kept.
    ///
    /// Both halves are needed in one place because the two palettised routes
    /// carry the flag differently: an uncompressed bitmap has its own `flags`
    /// word and its table inside `Bitmap`, while `lzPalette` has a flags byte
    /// of its own and its table beside the stream. The bits are the same —
    /// `PAL_CACHE_ME` is bit 0, `PAL_FROM_CACHE` is bit 1 — and they are *not*
    /// the descriptor's, where bit 0 means `CACHE_ME` and bit 2 means
    /// `CACHE_REPLACE_ME` rather than `TOP_DOWN`.
    ///
    /// **`nil` means a name this client cannot resolve**, and that is
    /// deliberately not the same as a malformed message.
    ///
    /// `SpiceBitmap.pixels` throws `missingPalette` for a palettised format
    /// with no colours, and a thrown error stops the pump — so before there was
    /// a palette cache, an image naming a cached table did not lose one draw,
    /// it **dropped the session**. Returning `nil` here routes it to the same
    /// place an undecodable codec goes: counted, that part of the screen left
    /// alone, the connection kept.
    ///
    /// A bitmap that carries no table and names none still throws, because that
    /// is a message disagreeing with itself rather than a client missing
    /// something.
    private static func resolvingPalette(
        _ image: Image, in cache: inout SpicePaletteCache
    ) -> Image? {
        var image = image

        if var bitmap = image.bitmap {
            if let named = bitmap.cachedPaletteID {
                guard let found = cache.palette(named) else { return nil }
                bitmap.palette = found
            } else if let carried = bitmap.palette,
                      bitmap.flags & BitmapFlag.paletteCacheMe != 0 {
                cache.store(carried)
            }
            image.bitmap = bitmap
        } else if let named = image.cachedPaletteID {
            guard let found = cache.palette(named) else { return nil }
            image.palette = found
        } else if let carried = image.palette, image.paletteCacheMe {
            cache.store(carried)
        }
        return image
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

    /// A stream frame's pixels, when it is a codec wisq decodes.
    ///
    /// `nil` for a codec it does not, which is "leave that part of the screen
    /// alone" and not "this message was malformed" — the same distinction the
    /// image codecs make, and it matters more here: a stream this client cannot
    /// decode is a region that freezes, while a dropped connection is the whole
    /// screen going away.
    ///
    /// **Only MJPEG.** VP8, VP9, H.264 and H.265 would each need a real video
    /// decoder — on Apple that is VideoToolbox and on Linux nothing wisq ships.
    /// They are named rather than lumped together because "the server chose
    /// H.264" is an explanation a user could act on.
    static func frame(
        _ data: StreamData, codec: VideoCodec
    ) throws -> (pixels: [UInt8], width: Int, height: Int)? {
        // **This guard changes no result, and is not there for one.** A VP8
        // frame is not valid JPEG, so handing it to the decoder anyway would
        // return nil just the same — a sabotage removing this line survives the
        // whole suite, on every platform, and that is a real equivalence rather
        // than a missing test.
        //
        // It stays because of what it stops, not what it returns: without it,
        // arbitrary bytes from a stream in a codec nobody here decodes would
        // reach the platform's image decoder. On Apple that is ImageIO, a large
        // C surface being fed network data for no reason at all. The cheapest
        // way not to have that conversation is not to make the call.
        guard codec.isDecoded else { return nil }
        // Each MJPEG frame is a complete JPEG image, which is the whole reason
        // this codec costs nothing extra: the decoder is the one `.jpeg` images
        // already use, absent on Linux and present on Apple.
        guard JPEGDecoder.isAvailable,
              let decoded = try? JPEGDecoder.decode(Data(data.frame)) else { return nil }
        return (decoded.bgra, decoded.width, decoded.height)
    }

    // MARK: - Streams

    /// `STREAM_CREATE`.
    ///
    /// Two pairs of dimensions that are easy to take for one: `stream_width`
    /// and `stream_height` are the size of the frames arriving on the wire,
    /// `src_width` and `src_height` the size of the region on the server's
    /// screen. They differ whenever the server scales before encoding, which it
    /// does routinely to save bandwidth — so using the wrong pair puts the
    /// video in the right place at the wrong size.
    static func streamCreate(_ payload: [UInt8]) throws -> StreamCreate {
        let body = Body(payload)
        var reader = try body.reader()
        let surfaceID = try reader.u32()
        let id = try reader.u32()
        let flags = try reader.u8()
        let rawCodec = try reader.u8()
        guard let codec = VideoCodec(rawValue: rawCodec) else { throw SpiceError.invalidData }
        return StreamCreate(
            surfaceID: surfaceID, id: id, flags: flags, codec: codec,
            stamp: try reader.u64(),
            streamWidth: try reader.u32(), streamHeight: try reader.u32(),
            sourceWidth: try reader.u32(), sourceHeight: try reader.u32(),
            destination: try rect(from: &reader),
            clip: try clip(from: &reader)
        )
    }

    /// `STREAM_DATA` and `STREAM_DATA_SIZED`.
    ///
    /// The sized form inserts a width, a height and a destination between the
    /// header and the length — so the two cannot share a reader, and reading a
    /// sized frame with the plain shape takes the width for the frame length.
    static func streamData(_ payload: [UInt8], sized: Bool) throws -> StreamData {
        let body = Body(payload)
        var reader = try body.reader()
        let id = try reader.u32()
        let time = try reader.u32()
        var geometry: StreamData.Sized?
        if sized {
            geometry = StreamData.Sized(
                width: try reader.u32(), height: try reader.u32(),
                destination: try rect(from: &reader)
            )
        }
        let size = Int(try reader.u32())
        return StreamData(
            id: id, multimediaTime: time, sized: geometry, frame: try reader.bytes(size)
        )
    }

    /// `STREAM_CLIP` — an id and a new clip, nothing else.
    static func streamClip(_ payload: [UInt8]) throws -> (id: UInt32, clip: Clip) {
        let body = Body(payload)
        var reader = try body.reader()
        return (id: try reader.u32(), clip: try clip(from: &reader))
    }

    /// `STREAM_DESTROY` — one word.
    static func streamDestroy(_ payload: [UInt8]) throws -> UInt32 {
        let body = Body(payload)
        var reader = try body.reader()
        return try reader.u32()
    }

    // MARK: - Strokes

    /// `DRAW_STROKE`.
    ///
    /// The field order is not the C struct's — it is the wire's, and the two
    /// differ in three places that would each silently misalign everything
    /// after them. The authority used here is the demarshaller the reference
    /// *generates* from `spice.proto`, not `draw.h`:
    ///
    ///   * the path is behind a **pointer**, like an image;
    ///   * `attr.style_nseg` and `attr.style` exist on the wire only when
    ///     `STYLED` is set. `SpiceLineAttr` in C always has both fields, so
    ///     transcribing the struct reads a length and a pointer out of the
    ///     brush that follows;
    ///   * `style` is itself a pointer to an array of `int32`, not an inline
    ///     run of them.
    static func stroke(_ payload: [UInt8]) throws -> Stroke {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let pathPointer = try reader.u32()

        let flags = try reader.u8()
        var style: [Fixed28Point4] = []
        if flags & LineAttr.styled != 0 {
            let count = Int(try reader.u8())
            let stylePointer = try reader.u32()
            style = try dashStyle(count: count, at: stylePointer, in: body)
        }

        return Stroke(
            base: header,
            path: try path(at: pathPointer, in: body),
            attr: LineAttr(flags: flags, style: style),
            brush: try brush(from: &reader, in: body),
            foreMode: try reader.u16(),
            backMode: try reader.u16()
        )
    }

    /// The dash lengths, from wherever the attribute pointed.
    ///
    /// A null pointer with a non-zero count is a message contradicting itself,
    /// and is refused rather than quietly drawn solid — a stroke that should
    /// have been dotted arriving as a solid line is a wrong picture, not a
    /// missing feature.
    private static func dashStyle(
        count: Int, at pointer: UInt32, in body: Body
    ) throws -> [Fixed28Point4] {
        guard count > 0 else { return [] }
        guard let followed = try body.follow(pointer) else { throw SpiceError.invalidData }
        var reader = followed.reader
        return try (0..<count).map { _ in Fixed28Point4(raw: Int32(bitPattern: try reader.u32())) }
    }

    /// A path, from wherever the stroke pointed.
    ///
    /// Segments sit one after another, each `5 + 8 × count` bytes:
    ///
    ///     uint8  flags      // one byte on the wire; `uint32_t` in the C struct
    ///     uint32 count
    ///     count × { int32 x, int32 y }
    ///
    /// **`@ptr_array` in `spice.proto` describes the C side, not the wire.**
    /// The generated parser walks the segments consecutively and only builds an
    /// array of pointers into its own arena afterwards — the same distinction
    /// already made for the clip's `@to_ptr`. Reading an array of offsets here
    /// would take the first segment's flags and count for a pointer.
    ///
    /// Reading `flags` as four bytes is the other way to lose: every segment
    /// after the first lands three bytes late, and the count read from the
    /// middle of a coordinate is large enough to be refused rather than drawn —
    /// which is the good outcome of a bad read, and not one to rely on.
    static func path(at pointer: UInt32, in body: Body) throws -> Path {
        guard let followed = try body.follow(pointer) else { throw SpiceError.invalidData }
        var reader = followed.reader
        let count = Int(try reader.u32())
        // Each segment costs at least five bytes, so a count larger than the
        // body could hold is refused before anything is reserved for it.
        guard count >= 0, count * 5 <= body.bytes.count else { throw SpiceError.truncated }

        var segments: [PathSegment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let flags = try reader.u8()
            let points = Int(try reader.u32())
            guard points >= 0, points * 8 <= body.bytes.count else { throw SpiceError.truncated }
            var run: [PointFix] = []
            run.reserveCapacity(points)
            for _ in 0..<points {
                run.append(PointFix(
                    x: Fixed28Point4(raw: Int32(bitPattern: try reader.u32())),
                    y: Fixed28Point4(raw: Int32(bitPattern: try reader.u32()))
                ))
            }
            segments.append(PathSegment(flags: flags, points: run))
        }
        return Path(segments: segments)
    }

    // MARK: - Text

    /// `DRAW_TEXT`.
    ///
    /// The string is behind a pointer; both brushes are inline, and there are
    /// two of them — the foreground the glyphs are painted with and the
    /// background the `back_area` is filled with. Reading one brush would take
    /// the second one's bytes for the two modes.
    static func text(_ payload: [UInt8]) throws -> Text {
        let body = Body(payload)
        var reader = try body.reader()
        let header = try base(from: &reader)
        let stringPointer = try reader.u32()
        return Text(
            base: header,
            string: try string(at: stringPointer, in: body),
            backArea: try rect(from: &reader),
            foreBrush: try brush(from: &reader, in: body),
            backBrush: try brush(from: &reader, in: body),
            foreMode: try reader.u16(),
            backMode: try reader.u16()
        )
    }

    /// A run of glyphs, from wherever the text pointed.
    ///
    /// The layout, from the generated parser:
    ///
    ///     uint16 length            // glyphs, not bytes
    ///     uint8  flags             // one of A1/A4/A8, plus TOP_DOWN
    ///     length × {
    ///         int32 render_pos.x, render_pos.y
    ///         int32 glyph_origin.x, glyph_origin.y
    ///         uint16 width, height
    ///         uint8 data[bytesPerRow(width, depth) × height]
    ///     }
    ///
    /// Each glyph's data length depends on its *own* width, so the glyphs
    /// cannot be skipped over without decoding them — there is no table of
    /// offsets, `@ptr_array` in the protocol description being about the C side
    /// as it is for a path.
    static func string(at pointer: UInt32, in body: Body) throws -> TextString {
        guard let followed = try body.follow(pointer) else { throw SpiceError.invalidData }
        var reader = followed.reader
        let count = Int(try reader.u16())
        let flags = try reader.u8()
        // A depth is needed to know how long each glyph's data is, so a string
        // this cannot measure is refused rather than half-read. Vector glyphs
        // are the real case here, and the reference draws nothing for them too.
        guard let depth = TextString(flags: flags, glyphs: []).depth else {
            throw SpiceError.invalidData
        }

        var glyphs: [RasterGlyph] = []
        glyphs.reserveCapacity(min(count, 1024))
        for _ in 0..<count {
            let renderPos = try point(from: &reader)
            let glyphOrigin = try point(from: &reader)
            let width = try reader.u16()
            let height = try reader.u16()
            let stride = TextString.bytesPerRow(width: Int(width), depth: depth)
            let length = stride * Int(height)
            guard length <= body.bytes.count else { throw SpiceError.truncated }
            glyphs.append(RasterGlyph(
                renderPos: renderPos, glyphOrigin: glyphOrigin,
                width: width, height: height,
                data: try reader.bytes(length)
            ))
        }
        return TextString(flags: flags, glyphs: glyphs)
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
