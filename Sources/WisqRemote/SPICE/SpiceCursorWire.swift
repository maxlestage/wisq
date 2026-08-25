import Foundation
import WisqCore

/// The cursor channel, decoded.
///
/// Its own channel in SPICE, and its own connection, because the pointer has to
/// keep moving while the display channel is busy sending a screenful of pixels.
/// On a phone that separation is the difference between a cursor that follows
/// the finger and one that lags a repaint.
///
/// Layouts from `spice.proto`; the two that would have been wrong from memory:
/// **`cursor_flags` is sixteen bits and `cursor_type` is eight**, so the header
/// does not start where a guess would put it, and the position is a
/// `Point16` — two *signed sixteen-bit* values, not the `Point`'s two 32-bit
/// ones that the display channel uses.
enum SpiceCursorWire {
    enum Message: UInt16, Equatable, Sendable {
        case initialise = 101
        case reset = 102
        case set = 103
        case move = 104
        case hide = 105
        case trail = 106
        case invalidateOne = 107
        case invalidateAll = 108
    }

    /// Bit flags, not an enumeration: a cursor can be both cacheable and
    /// present in the same message.
    enum Flag {
        static let none: UInt16 = 1 << 0
        static let cacheMe: UInt16 = 1 << 1
        static let fromCache: UInt16 = 1 << 2
    }

    enum Kind: UInt8, Equatable, Sendable {
        case alpha = 0
        case mono = 1
        case colour4 = 2
        case colour8 = 3
        case colour16 = 4
        case colour24 = 5
        case colour32 = 6
    }

    struct Position: Equatable, Sendable {
        var x: Int16
        var y: Int16
    }

    /// What the channel said about the pointer.
    ///
    /// `cursor` is `nil` when the message carried no image — either because the
    /// flags said `NONE`, or because it names one the client is expected to
    /// have cached. Those are different things and the second is not supported,
    /// so it is reported rather than guessed at: drawing the wrong cursor is
    /// worse than drawing none.
    struct Update: Equatable, Sendable {
        var position: Position?
        var visible: Bool
        var cursor: RemoteCursor?
        /// The server referred to a cached cursor this client does not hold.
        var wantedFromCache: Bool = false
    }

    // MARK: - Decoding

    static func position(from reader: inout SpiceWire.Reader) throws -> Position {
        Position(
            x: Int16(bitPattern: try reader.u16()),
            y: Int16(bitPattern: try reader.u16())
        )
    }

    /// `SPICE_MSG_CURSOR_INIT`: position, trail settings, visibility, cursor.
    static func initialise(_ payload: [UInt8]) throws -> Update {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let where_ = try position(from: &reader)
        _ = try reader.u16()   // trail length
        _ = try reader.u16()   // trail frequency
        let visible = try reader.u8() != 0
        let (cursor, cached) = try self.cursor(from: &reader)
        return Update(
            position: where_, visible: visible, cursor: cursor, wantedFromCache: cached
        )
    }

    /// `SPICE_MSG_CURSOR_SET`: position, visibility, cursor.
    static func set(_ payload: [UInt8]) throws -> Update {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let where_ = try position(from: &reader)
        let visible = try reader.u8() != 0
        let (cursor, cached) = try self.cursor(from: &reader)
        return Update(
            position: where_, visible: visible, cursor: cursor, wantedFromCache: cached
        )
    }

    /// `SPICE_MSG_CURSOR_MOVE`: a position and nothing else.
    static func move(_ payload: [UInt8]) throws -> Update {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return Update(position: try position(from: &reader), visible: true)
    }

    /// The `Cursor` structure: flags, then a header and pixels unless the flags
    /// say there is nothing there.
    static func cursor(
        from reader: inout SpiceWire.Reader
    ) throws -> (cursor: RemoteCursor?, fromCache: Bool) {
        let flags = try reader.u16()
        guard flags & Flag.none == 0 else { return (nil, false) }

        _ = try reader.u64()   // unique id, for the cache this client does not keep
        let rawType = try reader.u8()
        guard let kind = Kind(rawValue: rawType) else { throw SpiceError.invalidData }
        let width = Int(try reader.u16())
        let height = Int(try reader.u16())
        let hotspotX = Int(try reader.u16())
        let hotspotY = Int(try reader.u16())

        // A cursor named from the cache carries a header and no pixels. Saying
        // so beats returning an empty image, which the renderer would take for
        // "hide the pointer".
        if flags & Flag.fromCache != 0 {
            return (nil, true)
        }

        // Only the 32-bit form is turned into pixels. The others need palettes
        // or bit-mask expansion, and a cursor drawn from a guessed layout is a
        // smear that follows the finger everywhere — worse than the system
        // arrow.
        guard kind == .alpha || kind == .colour32 else { return (nil, false) }
        guard width > 0, height > 0, width <= 1024, height <= 1024 else {
            throw SpiceError.invalidData
        }

        let bytes = try reader.bytes(width * height * 4)
        return (
            RemoteCursor(
                width: width, height: height,
                hotspotX: hotspotX, hotspotY: hotspotY,
                bgra: bytes
            ),
            false
        )
    }
}
