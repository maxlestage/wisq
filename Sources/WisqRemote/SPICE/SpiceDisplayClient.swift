import Foundation

/// What the client says to the display channel, rather than what it hears.
///
/// Small, and what it decides is not. A SPICE server picks its image encoding
/// from its own configuration, and `reds.cpp` defaults that to `AUTO_GLZ`. So
/// every number in here is answering the same question — *what has this client
/// promised a server it can cope with* — and the server believes the answers
/// without checking them.
///
/// The two sizes in `initialise()` show how little that is a formality: they
/// sit in one message, they are both "how much this client will remember", and
/// the server treats one as a budget it may exceed and the other as a floor it
/// will die below. Neither is a hint.
enum SpiceDisplayClient {
    /// Client-to-server message types on the display channel.
    enum Message: UInt16, Equatable, Sendable {
        case initialise = 101
        case streamReport = 102
        case preferredCompression = 103
        case glDrawDone = 104
        case preferredVideoCodecType = 105
    }

    /// The encodings a server can be asked for.
    enum Compression: UInt8, Equatable, Sendable {
        case off = 1
        case autoGLZ = 2
        case autoLZ = 3
        case quic = 4
        case glz = 5
        case lz = 6
        case lz4 = 7
    }

    /// Display channel capabilities, by bit position in the capability words.
    ///
    /// The link message carries these as a bitmap of 32-bit words, so a
    /// capability's number is a bit index and not a value: capability 6 is bit
    /// 6 of word 0, and capability 33 would be bit 1 of word 1. Reading them as
    /// values is the mistake this enum exists to prevent.
    enum Capability: Int, Equatable, Sendable {
        case sizedStream = 0
        case monitorsConfig = 1
        case composite = 2
        case a8Surface = 3
        case streamReport = 4
        case lz4Compression = 5
        case preferredCompression = 6
        case glScanout = 7
        case multiCodec = 8
    }

    /// Whether a server's advertised capabilities include one.
    static func supports(_ capability: Capability, in caps: [UInt32]) -> Bool {
        let word = capability.rawValue / 32
        let bit = capability.rawValue % 32
        guard word < caps.count else { return false }
        return caps[word] >> UInt32(bit) & 1 == 1
    }

    /// The capability words a client sends for a set of capabilities.
    static func capabilityWords(_ capabilities: [Capability]) -> [UInt32] {
        guard let highest = capabilities.map(\.rawValue).max() else { return [] }
        var words = [UInt32](repeating: 0, count: highest / 32 + 1)
        for capability in capabilities {
            words[capability.rawValue / 32] |= 1 << UInt32(capability.rawValue % 32)
        }
        return words
    }

    // MARK: - Messages

    /// The pixmap cache this client declares, in pixels.
    ///
    /// **A number here is a promise the server keeps on this client's behalf**,
    /// and it was zero until there was a cache to make it true.
    ///
    /// The mechanism runs on the server. A guest's QXL driver marks an image
    /// `QXL_IMAGE_CACHE` when it expects to draw it again — icons, glyphs,
    /// window borders, wallpaper tiles — which `red-parse-qxl.cpp` turns into
    /// `SPICE_IMAGE_FLAGS_CACHE_ME`. On the first send,
    /// `marshal_lossy_or_lossless` calls `dcc_pixmap_cache_unlocked_add(dcc,
    /// id, width * height, …)` — so the unit is pixels — and echoes `CACHE_ME`
    /// to the client only if that add succeeded. On every later send of the
    /// same id, `fill_bits` writes `SPICE_IMAGE_TYPE_FROM_CACHE`: an
    /// identifier, and no pixels at all.
    ///
    /// Declaring a size with nothing behind it meant those draws were skipped
    /// and the region kept stale pixels. `SpicePixmapCache` is what is behind
    /// it now, and the number is what the server holds *itself* to: it evicts
    /// to stay inside, and names each eviction in `SPICE_MSG_DISPLAY_INVAL_LIST`
    /// so the two sides drop the same entries.
    ///
    /// 4 Mi pixels is 16 MiB of decoded BGRA at the ceiling, and the ceiling is
    /// reached only by a guest that really does repeat that many distinct
    /// pictures. It buys the thing a mobile link cares about: a desktop's
    /// furniture crosses the network once per connection instead of once per
    /// redraw.
    static let pixmapCachePixels: Int64 = 4 << 20

    /// The GLZ window this client declares, in pixels.
    ///
    /// **This is a floor, not a budget, and the difference is a crash.** The
    /// number goes into `SPICE_MSGC_DISPLAY_INIT`, `dcc_handle_init` hands it
    /// unchecked to `glz_enc_dictionary_create`, and every GLZ encode then
    /// starts at `glz_dictionary_window_get_new_head`, whose first act is:
    ///
    /// ```c
    /// if ((uint32_t)new_image_size > dict->window.size_limit) {
    ///     dict->cur_usr->error(dict->cur_usr, "image is bigger than window\n");
    /// }
    /// ```
    ///
    /// That `error` is `glz_usr_error`, which calls `spice_critical`, which
    /// calls `abort()`. There is no fallback path and no smaller encoding
    /// tried: a client that declares a window smaller than one image kills the
    /// server process the first time the server encodes one. `scripts/spice-glz-window/`
    /// builds the reference encoder and shows the boundary — a 64×64 image is
    /// clean at 4096 and aborts at 4095.
    ///
    /// So the size is not chosen for how much history is worth keeping. It is
    /// chosen so that **one whole frame always fits**, and the frame is the
    /// guest's, decided long after this message goes out. `1 << 23` is
    /// 8 388 608 pixels, which covers 3840×2160 with room over; a guest larger
    /// than that would trip the check, and there is nothing here that could
    /// know about it in time. spice-gtk lands in the same place from the other
    /// direction, clamping its own window to at least 12 MiB and normally
    /// choosing 32 MiB — the same 8 Mi pixels, since it divides bytes by four.
    ///
    /// The ceiling this puts on wisq's own memory is that many pixels of
    /// decoded history, 32 MiB at four bytes each, and only when a server
    /// actually fills the window: `SpiceGLZ.Window` holds what the server's
    /// `winHeadDistance` says is still reachable, not the declared maximum.
    static let glzWindowPixels: Int32 = 1 << 23

    /// `SPICE_MSGC_DISPLAY_INIT`, which the server waits for before it draws.
    ///
    /// Two sizes, side by side, same shape, both "how much this client will
    /// remember" — and **the safe value is opposite for each**, which is the
    /// one thing reading the message will never tell you.
    ///
    /// The GLZ window is a floor: below one frame the server calls `abort()`,
    /// so it is as large as any frame can be. The pixmap cache is a promise to
    /// hold images the server will later send by name alone: any non-zero value
    /// makes it send names wisq cannot resolve, so it is zero. Large or the
    /// server dies; zero or the picture goes stale. Neither is a hint, and
    /// nothing in the field names, the types or the ordering distinguishes
    /// them — what does is in three different files the client never runs.
    static func initialise(
        pixmapCacheID: UInt8 = 0,
        pixmapCachePixels: Int64 = SpiceDisplayClient.pixmapCachePixels,
        glzDictionaryID: UInt8 = 0,
        glzWindowPixels: Int32 = SpiceDisplayClient.glzWindowPixels
    ) -> [UInt8] {
        var body: [UInt8] = [pixmapCacheID]
        body += SpiceWire.u64(UInt64(bitPattern: pixmapCachePixels))
        body += [glzDictionaryID]
        body += SpiceWire.u32(UInt32(bitPattern: glzWindowPixels))
        return body
    }

    /// `SPICE_MSGC_DISPLAY_PREFERRED_COMPRESSION` — one byte, the encoding
    /// wanted.
    static func preferredCompression(_ compression: Compression) -> [UInt8] {
        [compression.rawValue]
    }

    /// What to ask a server for, given what it says it can do.
    ///
    /// `nil` means send nothing: a server that has not advertised
    /// `preferredCompression` will not act on the message, and sending it
    /// anyway is a message the other end has said it does not understand.
    ///
    /// **`nil` is also the case that matters most, and it is not the quiet
    /// one.** A server this client cannot make a request of keeps the
    /// preference from its own configuration, and `reds.cpp` initialises that
    /// to `SPICE_IMAGE_COMPRESSION_AUTO_GLZ`. So GLZ is not something wisq opts
    /// into — it is the default everywhere, and asking for `autoLZ` only ever
    /// steered the servers that were listening. The same gap exists on every
    /// server for the images encoded between `DISPLAY_INIT` and this message
    /// landing. Whatever is preferred here, this client has to survive being
    /// sent GLZ, which is why `glzWindowPixels` is a correctness matter and not
    /// a tuning one.
    ///
    /// **`autoGLZ` rather than `autoLZ`.** Both send QUIC for a high-graduality
    /// bitmap and differ only in the fallback, and three things had to hold
    /// before preferring the GLZ one. All three now do:
    ///
    ///   * GLZ decodes. `.glzRGB` and `.zlibGlzRGB` both have their own tests,
    ///     and the window is threaded through the display pump;
    ///   * the forms this client refuses cannot arrive.
    ///     `get_compression_for_bitmap` downgrades `GLZ` to `LZ` whenever
    ///     `bitmap_fmt_has_graduality` is false, and that is
    ///     `bitmap_fmt_is_rgb(fmt) && fmt != SPICE_BITMAP_FMT_8BIT_A` — every
    ///     palette format fails it. So palette-GLZ is unreachable under
    ///     `autoGLZ`; the output is QUIC, GLZ-RGB, LZ or uncompressed;
    ///   * the window is large enough to encode against. It was zero, which
    ///     was not a smaller window but an `abort()` in the server.
    ///
    /// The gain is what GLZ is for: one dictionary spanning the images of a
    /// channel, where LZ starts again at every image. A desktop mostly sends
    /// the same widgets, fonts and wallpaper repeatedly, and matching across
    /// frames is the difference. Bandwidth is the scarce thing over a mobile
    /// network.
    ///
    /// **Not `lz4`, though LZ4 is decoded**, and the reason is worth stating
    /// because the opposite looks obvious on a phone: LZ4 is the cheapest of
    /// these to decode by a wide margin. But asking for it is asking for it
    /// *instead of* the automatic modes — `get_compression_for_bitmap` never
    /// reaches QUIC once the preference is `LZ4` — and QUIC is worth several
    /// times LZ4's ratio on the photographic content that dominates a desktop
    /// with a wallpaper. The decode is not the scarce thing.
    ///
    /// wisq still advertises the LZ4 capability, which is a different
    /// statement: it is permission for a server whose own configuration says
    /// LZ4, and for the images that go out before this message lands.
    static func compressionToRequest(givenServerCapabilities caps: [UInt32]) -> Compression? {
        supports(.preferredCompression, in: caps) ? .autoGLZ : nil
    }
}
