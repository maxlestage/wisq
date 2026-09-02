import Foundation

/// The guest agent's protocol, which is where SPICE keeps the clipboard.
///
/// Not the inputs channel, which is the guess a reader makes: the clipboard is
/// the *guest's*, so it travels to the program running inside the guest rather
/// than to the virtual hardware. Agent messages ride the main channel wrapped
/// in `AGENT_DATA`, and this file is the layer inside that wrapper.
///
/// **The clipboard structures do not have one layout.** Up to two prefixes
/// appear or vanish depending on what the two ends agreed during capability
/// exchange, and both are easy to write wrong:
///
///   * `VD_AGENT_CAP_CLIPBOARD_SELECTION` adds a selection field — and it is
///     **four bytes**, one of selection and three reserved, padded to a word.
///     Read as one byte, everything after it shifts by three;
///   * `VD_AGENT_CAP_CLIPBOARD_GRAB_SERIAL` adds a four-byte serial, on the
///     grab message only.
///
/// So one message type has four possible shapes. A client that assumes one
/// works against the server it was written for and misreads every clipboard
/// message from the next — which is why the layout here is computed from the
/// negotiated capabilities rather than fixed.
enum SpiceAgent {
    /// `VD_AGENT_PROTOCOL`. A message announcing anything else is not one of
    /// these, whatever else it looks like.
    static let protocolVersion: UInt32 = 1

    enum Message: UInt32, Equatable, Sendable {
        case mouseState = 1
        case monitorsConfig = 2
        case reply = 3
        case clipboard = 4
        case displayConfig = 5
        case announceCapabilities = 6
        case clipboardGrab = 7
        case clipboardRequest = 8
        case clipboardRelease = 9
        case fileXferStart = 10
        case fileXferStatus = 11
        case fileXferData = 12
    }

    /// Capabilities, by bit position in the announcement's bitmap.
    enum Capability: Int, Equatable, Sendable {
        case mouseState = 0
        case monitorsConfig = 1
        case reply = 2
        case clipboard = 3
        case displayConfig = 4
        case clipboardByDemand = 5
        case clipboardSelection = 6
        case sparseMonitorsConfig = 7
        case guestLineEndLF = 8
        case guestLineEndCRLF = 9
        case maxClipboard = 10
        case fileXferDisabled = 13
        case fileXferDetailedErrors = 14
        case clipboardGrabSerial = 17
    }

    /// What the clipboard holds, by the protocol's numbering.
    enum Kind: UInt32, Equatable, Sendable {
        case none = 0
        case utf8Text = 1
        case imagePNG = 2
        case imageBMP = 3
        case imageTIFF = 4
        case imageJPG = 5
    }

    /// Which clipboard, when the guest has more than one. X11 has three; a
    /// phone has the concept of exactly one, so wisq only ever speaks about
    /// the first — but it has to say *which* when the capability is on.
    enum Selection: UInt8, Equatable, Sendable {
        case clipboard = 0
        case primary = 1
        case secondary = 2
    }

    enum Failure: Error, Equatable {
        case notAnAgentMessage(protocolVersion: UInt32)
        case unknownMessage(UInt32)
        case truncated
        /// A payload longer than the header says, or shorter. Named apart from
        /// `truncated` because it means the two disagree rather than that the
        /// bytes ran out.
        case sizeMismatch(declared: UInt32, actual: Int)
    }

    /// Whether a capability bitmap has one set.
    static func supports(_ capability: Capability, in caps: [UInt32]) -> Bool {
        let word = capability.rawValue / 32
        let bit = capability.rawValue % 32
        guard word < caps.count else { return false }
        return caps[word] >> UInt32(bit) & 1 == 1
    }

    static func capabilityWords(_ capabilities: [Capability]) -> [UInt32] {
        guard let highest = capabilities.map(\.rawValue).max() else { return [] }
        var words = [UInt32](repeating: 0, count: highest / 32 + 1)
        for capability in capabilities {
            words[capability.rawValue / 32] |= 1 << UInt32(capability.rawValue % 32)
        }
        return words
    }

    /// How many bytes the optional selection prefix occupies.
    ///
    /// Four, not one. The struct is one byte of selection followed by three
    /// reserved, so that what comes after stays word-aligned.
    static func selectionPrefixBytes(_ caps: [UInt32]) -> Int {
        supports(.clipboardSelection, in: caps) ? 4 : 0
    }

    // MARK: - The message envelope

    struct Header: Equatable, Sendable {
        var type: Message
        var opaque: UInt64
        var size: UInt32
    }

    /// `VDAgentMessage`: protocol, type, opaque, size, then that many bytes.
    static func header(from reader: inout SpiceWire.Reader) throws -> Header {
        let version = try reader.u32()
        guard version == protocolVersion else {
            throw Failure.notAnAgentMessage(protocolVersion: version)
        }
        let rawType = try reader.u32()
        guard let type = Message(rawValue: rawType) else {
            throw Failure.unknownMessage(rawType)
        }
        return Header(type: type, opaque: try reader.u64(), size: try reader.u32())
    }

    static func message(_ type: Message, body: [UInt8]) -> [UInt8] {
        var out = SpiceWire.u32(protocolVersion)
        out += SpiceWire.u32(type.rawValue)
        out += SpiceWire.u64(0)
        out += SpiceWire.u32(UInt32(body.count))
        out += body
        return out
    }

    // MARK: - Capabilities, announced

    /// `VD_AGENT_ANNOUNCE_CAPABILITIES`: a request flag, then the bitmap.
    ///
    /// The flag is not decoration. Set, it means "tell me yours"; a client that
    /// never sets it and speaks to an agent that already announced before the
    /// client attached never learns the guest's capabilities — and the
    /// clipboard layout is computed from them, so every clipboard message it
    /// then reads is misaligned by four bytes.
    struct Announcement: Equatable, Sendable {
        /// Whether the sender wants the capabilities announced back.
        var request: Bool
        var capabilities: [UInt32]
    }

    static func announcementBody(_ announcement: Announcement) -> [UInt8] {
        announcement.capabilities.reduce(
            SpiceWire.u32(announcement.request ? 1 : 0), { $0 + SpiceWire.u32($1) }
        )
    }

    static func announcement(_ body: [UInt8]) throws -> Announcement {
        var reader = try SpiceWire.Reader(body, from: 0)
        let request = try reader.u32() != 0
        // The count is the message's length, not a number in the message, so
        // the words are appended one at a time rather than sized from anything
        // the far end chose.
        var words: [UInt32] = []
        while reader.remaining >= 4 { words.append(try reader.u32()) }
        return Announcement(request: request, capabilities: words)
    }

    /// What wisq tells the guest it can do.
    ///
    /// Short on purpose, and each one is a promise this client keeps:
    /// `clipboardByDemand` because the clipboard here is fetched when wanted
    /// rather than pushed, `clipboardSelection` because saying which selection
    /// costs four bytes and not saying it means the guest picks, and
    /// `clipboardGrabSerial` because a guest that stamps grabs can tell a stale
    /// one from a current one, and `fileXferDetailedErrors` because a refusal
    /// that says "3,2 Go libres, 5 Go à transférer" is one the user can act on
    /// where "erreur" is not — the agent only sends the detail to clients that
    /// asked (spice-gtk asks too). No monitor or display configuration is
    /// claimed: wisq does not resize the guest yet, and announcing a capability
    /// it does not honour is worse than announcing nothing.
    static let clientCapabilities: [Capability] = [
        .clipboardByDemand, .clipboardSelection, .clipboardGrabSerial,
        .fileXferDetailedErrors
    ]

    // MARK: - Clipboard

    struct Clipboard: Equatable, Sendable {
        var selection: Selection
        var kind: Kind
        var data: [UInt8]

        /// The text, when that is what it is.
        ///
        /// SPICE says UTF-8 and guests are not always careful about it, so a
        /// decoding that fails yields nil rather than replacement characters —
        /// pasting `����` into a document is worse than pasting nothing.
        var text: String? {
            guard kind == .utf8Text else { return nil }
            // Some agents include the terminating NUL in the payload; it is not
            // part of the text and would show up as an invisible character at
            // the end of every paste.
            var bytes = data
            while bytes.last == 0 { bytes.removeLast() }
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    /// Reads a `VD_AGENT_CLIPBOARD` body.
    static func clipboard(_ body: [UInt8], capabilities caps: [UInt32]) throws -> Clipboard {
        var reader = try SpiceWire.Reader(body, from: 0)
        let selection = try readSelection(&reader, capabilities: caps)
        let rawKind = try reader.u32()
        // An unknown kind is carried rather than refused: the data is still the
        // guest's clipboard, and a client that cannot render it should be able
        // to say so rather than drop the connection.
        let kind = Kind(rawValue: rawKind) ?? .none
        return Clipboard(selection: selection, kind: kind, data: reader.rest())
    }

    static func clipboardBody(
        _ kind: Kind, data: [UInt8],
        selection: Selection = .clipboard, capabilities caps: [UInt32]
    ) -> [UInt8] {
        writeSelection(selection, capabilities: caps) + SpiceWire.u32(kind.rawValue) + data
    }

    /// `VD_AGENT_CLIPBOARD_GRAB`: the guest saying what it now has on offer.
    struct Grab: Equatable, Sendable {
        var selection: Selection
        var serial: UInt32?
        var kinds: [Kind]
    }

    static func grab(_ body: [UInt8], capabilities caps: [UInt32]) throws -> Grab {
        var reader = try SpiceWire.Reader(body, from: 0)
        let selection = try readSelection(&reader, capabilities: caps)
        let serial = supports(.clipboardGrabSerial, in: caps) ? try reader.u32() : nil

        // The rest is a list of types, four bytes each, and its length is the
        // message's rather than a count in the message. Appended one at a time
        // so nothing is sized from a number that is not there.
        var kinds: [Kind] = []
        while reader.remaining >= 4 {
            let raw = try reader.u32()
            if let kind = Kind(rawValue: raw) { kinds.append(kind) }
        }
        return Grab(selection: selection, serial: serial, kinds: kinds)
    }

    /// The same, going out: what this client now has on offer.
    ///
    /// The serial is the guest's way of telling a grab that is current from one
    /// that raced past it, so it is the caller's counter rather than a constant
    /// — and it is written only when the capability says the far end reads it.
    /// Written when it is not read, everything after it shifts by four.
    static func grabBody(
        _ kinds: [Kind], serial: UInt32,
        selection: Selection = .clipboard, capabilities caps: [UInt32]
    ) -> [UInt8] {
        var out = writeSelection(selection, capabilities: caps)
        if supports(.clipboardGrabSerial, in: caps) { out += SpiceWire.u32(serial) }
        for kind in kinds { out += SpiceWire.u32(kind.rawValue) }
        return out
    }

    /// `VD_AGENT_CLIPBOARD_REQUEST`: asking for one of the kinds offered.
    static func requestBody(
        _ kind: Kind, selection: Selection = .clipboard, capabilities caps: [UInt32]
    ) -> [UInt8] {
        writeSelection(selection, capabilities: caps) + SpiceWire.u32(kind.rawValue)
    }

    static func request(_ body: [UInt8], capabilities caps: [UInt32]) throws -> Kind {
        var reader = try SpiceWire.Reader(body, from: 0)
        _ = try readSelection(&reader, capabilities: caps)
        return Kind(rawValue: try reader.u32()) ?? .none
    }

    /// `VD_AGENT_CLIPBOARD_RELEASE`: nothing but the selection, if that.
    static func releaseBody(
        _ selection: Selection = .clipboard, capabilities caps: [UInt32]
    ) -> [UInt8] {
        writeSelection(selection, capabilities: caps)
    }

    // MARK: - The prefix that is there or not

    private static func readSelection(
        _ reader: inout SpiceWire.Reader, capabilities caps: [UInt32]
    ) throws -> Selection {
        guard supports(.clipboardSelection, in: caps) else { return .clipboard }
        let raw = try reader.u8()
        _ = try reader.bytes(3)   // reserved, and skipped rather than assumed absent
        return Selection(rawValue: raw) ?? .clipboard
    }

    private static func writeSelection(
        _ selection: Selection, capabilities caps: [UInt32]
    ) -> [UInt8] {
        supports(.clipboardSelection, in: caps) ? [selection.rawValue, 0, 0, 0] : []
    }
}
