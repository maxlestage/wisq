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
}
