import Foundation

/// The messages that ride *inside* another message, named by an offset in the
/// header rather than sent on their own.
///
/// **This exists because wisq reads the eighteen-byte header.** SPICE has two:
/// the mini header (type and size, six bytes) and the full one, whose last
/// field is `sub_list` — "offset to SpiceSubMessageList[]". Which the client
/// reads decides, on the server's side, which function runs:
///
/// ```c
/// if (dcc->is_mini_header()) {
///     send_free_list(dcc);          // a plain SPICE_MSG_LIST, or a plain INVAL_LIST
/// } else {
///     send_free_list_legacy(dcc);   // sub-marshaller + set_header_sub_list(...)
/// }
/// ```
///
/// So for this client every cache invalidation the server has ever sent
/// travelled in a sub-list. `SpiceWire.DataHeader` decoded the field and
/// nothing read it, which was harmless only because nothing was cached: with a
/// declared cache of zero the server never evicts and so never sends one.
/// It stops being harmless the moment there is a cache.
///
/// `spice-channel.c` takes both forms in one condition —
/// `if (msg_type == SPICE_MSG_LIST || sub_list_offset)` — and that is the shape
/// copied here: the offset is what matters, not the carrying message's type.
enum SpiceSubMessages {
    /// `SPICE_MSG_LIST`, in the base message range rather than the display
    /// channel's. It carries a sub-list as its whole body, where the legacy
    /// path hangs one off an ordinary message.
    static let listMessage: UInt16 = 8

    struct SubMessage: Equatable, Sendable {
        var type: UInt16
        var payload: [UInt8]
    }

    /// Reads the sub-list at `offset` in a message body.
    ///
    /// `SpiceSubMessageList` is a `uint16` followed by that many `uint32`
    /// offsets, and each offset names a `SpiceSubMessage` — `uint16 type`,
    /// `uint32 size`, then the body.
    ///
    /// **The `uint16` is a count, not a size**, whatever the reference's field
    /// name says. `SpiceSubMessageList.size` is what the header calls it, and
    /// `spice_marshaller_add_uint16(sub_list_m, sub_list_len)` is what actually
    /// goes in — the number of entries. Reading it as a byte count would ask
    /// for hundreds of offsets from a two-entry list.
    ///
    /// Offsets are measured from the start of the message body, which is also
    /// where `sub_list` itself points, so they are used as absolute indices
    /// here rather than added to anything.
    ///
    /// **Offset zero is a real offset here, not "there is no list".** The
    /// header's `sub_list` field uses 0 as its absent marker, and that check
    /// belongs to the caller reading the header — because the other carrier,
    /// `SPICE_MSG_LIST`, puts the list at the very start of its body, where 0
    /// is exactly where it lives. Folding the sentinel in here made that whole
    /// branch return nothing, silently.
    static func list(at offset: UInt32, in body: [UInt8]) throws -> [SubMessage] {
        var reader = try SpiceWire.Reader(body, from: Int(offset))
        let count = Int(try reader.u16())

        var offsets = [UInt32]()
        offsets.reserveCapacity(count)
        for _ in 0..<count { offsets.append(try reader.u32()) }

        var messages = [SubMessage]()
        messages.reserveCapacity(count)
        for start in offsets {
            var sub = try SpiceWire.Reader(body, from: Int(start))
            let type = try sub.u16()
            let size = Int(try sub.u32())
            messages.append(SubMessage(type: type, payload: try sub.bytes(size)))
        }
        return messages
    }
}
