import Foundation

/// The images the server may later send by name alone.
///
/// A SPICE server does not re-send a picture it believes the client kept. The
/// guest's QXL driver marks an image `QXL_IMAGE_CACHE` when it expects to draw
/// it again — icons, glyphs, window borders, wallpaper tiles — the server
/// records it, echoes `SPICE_IMAGE_FLAGS_CACHE_ME` to say "keep this", and
/// every later send of that identifier is `SPICE_IMAGE_TYPE_FROM_CACHE`: a
/// name, and no pixels. On a mobile link that is the difference between
/// sending an icon once and sending it twenty times.
///
/// **This cache does not evict.** That is the part worth reading twice, because
/// every instinct says a bounded cache should. The server keeps its own mirror
/// of what it thinks this client holds, and when *it* drops something it says
/// so: `dcc_pixmap_cache_unlocked_add` evicts its LRU tail and calls
/// `dcc_push_release(dcc, SPICE_RES_TYPE_PIXMAP, tail->id, …)`, which is
/// marshalled to the client as `SPICE_MSG_DISPLAY_INVAL_LIST`. Two LRU chains —
/// one ordered by the server's sends, one by this client's draws — would
/// diverge, and every divergence is a `FROM_CACHE` naming something already
/// dropped, which draws nothing at all. So the rule is: **store what you are
/// told to store, drop what you are told to drop.**
///
/// The declared size is therefore a contract rather than a hint. The server
/// holds itself to it — `cache->available` starts there and it evicts to stay
/// inside — so `budgetPixels` here only has to match what
/// `SpiceDisplayClient.pixmapCachePixels` promised. It is enforced anyway,
/// because a promise kept by the other end alone is not a bound.
struct SpicePixmapCache {
    /// A decoded image, in the client's own BGRA, ready to draw.
    struct Entry: Equatable, Sendable {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// The unit is pixels, not bytes, and it is the server's unit: it counts
    /// `image->descriptor.width * image->descriptor.height` when it decides
    /// whether an image fits. Counting bytes here would drift from the number
    /// the other end is holding itself to by exactly the depth.
    let budgetPixels: Int
    private var entries: [UInt64: Entry] = [:]
    private(set) var storedPixels = 0

    init(budgetPixels: Int = Int(SpiceDisplayClient.pixmapCachePixels)) {
        self.budgetPixels = max(0, budgetPixels)
    }

    var count: Int { entries.count }

    func image(_ id: UInt64) -> Entry? { entries[id] }

    /// Keeps an image the server asked to be kept.
    ///
    /// Refused, rather than accepted by evicting something, when it would put
    /// the cache over its budget. The server should never ask — it evicts first
    /// and tells us — so this is the backstop for a server that does not, and
    /// the honest failure is to not hold it: a `FROM_CACHE` we cannot answer
    /// skips one draw, while a phone that has quietly agreed to hold more than
    /// it said would drop the whole app.
    ///
    /// Storing again under the same identifier replaces, which is what
    /// `CACHE_REPLACE_ME` means on the wire: the server sends a lossless
    /// version of something it had cached lossily.
    @discardableResult
    mutating func store(_ id: UInt64, _ entry: Entry) -> Bool {
        let size = entry.width * entry.height
        guard size > 0 else { return false }
        let existing = entries[id].map { $0.width * $0.height } ?? 0
        guard storedPixels - existing + size <= budgetPixels else { return false }
        storedPixels += size - existing
        entries[id] = entry
        return true
    }

    /// `SPICE_MSG_DISPLAY_INVAL_LIST` names one. Dropping an identifier that is
    /// not held is not an error: the list is the server's, and it may name
    /// something this client refused to store.
    mutating func drop(_ id: UInt64) {
        guard let gone = entries.removeValue(forKey: id) else { return }
        storedPixels -= gone.width * gone.height
    }

    /// `SPICE_MSG_DISPLAY_INVAL_ALL_PIXMAPS`, and a reconnect.
    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        storedPixels = 0
    }
}

/// The colour tables the server may later send by name alone.
///
/// The same shape as `SpicePixmapCache` with **one difference that decides
/// everything: there is no size to declare.** `dcc_palette_cache_palette` is
/// the whole mechanism —
///
/// ```c
/// if (palette->unique) {
///     if (red_palette_cache_find(dcc, palette->unique)) {
///         *flags |= SPICE_BITMAP_FLAGS_PAL_FROM_CACHE;
///         return;                      // and the colours do not go on the wire
///     }
///     if (red_palette_cache_add(dcc, palette->unique, 1)) {
///         *flags |= SPICE_BITMAP_FLAGS_PAL_CACHE_ME;
///     }
/// }
/// ```
///
/// — and the size it enforces is `CLIENT_PALETTE_CACHE_SIZE`, a constant in the
/// server's own `dcc.h`. Nothing in `SPICE_MSGC_DISPLAY_INIT` negotiates it.
/// So where the pixmap cache could be declined by declaring zero, this one
/// cannot be declined at all: a client that keeps no palettes simply loses the
/// colours of every palettised image whose table the server has already sent,
/// and draws nothing in its place.
///
/// The eviction rule is the pixmap cache's, and the reason is the same — the
/// server names what it drops. The message differs: palettes are not in the
/// resource list, they get `SPICE_MSG_DISPLAY_INVAL_PALETTE` (107) each, or
/// `INVAL_ALL_PALETTES` (108) for the lot, as ordinary top-level messages
/// rather than something hung off a header.
///
/// The bound is in entries rather than pixels because that is what the server
/// counts: `red_palette_cache_add(dcc, palette->unique, 1)` — every table costs
/// one, whatever its length.
struct SpicePaletteCache {
    /// `CLIENT_PALETTE_CACHE_SIZE` in the server's `dcc.h`. Matched rather than
    /// chosen: the server assumes this client holds that many and never asks,
    /// so holding fewer loses colours the server is certain were kept.
    static let serverAssumedEntries = 128

    let capacity: Int
    private var entries: [UInt64: SpiceDisplayWire.Palette] = [:]

    init(capacity: Int = SpicePaletteCache.serverAssumedEntries) {
        self.capacity = max(0, capacity)
    }

    var count: Int { entries.count }

    func palette(_ unique: UInt64) -> SpiceDisplayWire.Palette? { entries[unique] }

    /// **`unique` zero is not an identifier.** `dcc_palette_cache_palette`
    /// tests `if (palette->unique)` before doing anything at all, so a table
    /// with no unique is never cached and never named — storing one under the
    /// key zero would collide every such table with every other.
    @discardableResult
    mutating func store(_ palette: SpiceDisplayWire.Palette) -> Bool {
        guard palette.unique != 0 else { return false }
        if entries[palette.unique] != nil {
            entries[palette.unique] = palette
            return true
        }
        guard entries.count < capacity else { return false }
        entries[palette.unique] = palette
        return true
    }

    /// `SPICE_MSG_DISPLAY_INVAL_PALETTE`.
    mutating func drop(_ unique: UInt64) { entries.removeValue(forKey: unique) }

    /// `SPICE_MSG_DISPLAY_INVAL_ALL_PALETTES`, and a reconnect.
    mutating func clear() { entries.removeAll(keepingCapacity: true) }
}

/// What one display connection remembers about images.
///
/// The GLZ window and the pixmap cache travel together because they are the
/// same kind of thing — state whose honest lifetime is the connection's, since
/// both are about pictures decoded earlier *on this socket*. A reconnect starts
/// with both empty, exactly as it starts with a blank screen.
///
/// Grouped rather than passed side by side for a second reason: the pump
/// already carries the surfaces, the streams and the serial, and a fifth
/// parameter without a default is where `function_parameter_count` stops the
/// build. The reference groups the same two — `spice_session_get_caches(s,
/// &c->images, &c->glz_window)` hands back exactly this pair.
struct SpiceDisplayCaches {
    var glz = SpiceGLZ.Window()
    var pixmaps = SpicePixmapCache()
    var palettes = SpicePaletteCache()
}
