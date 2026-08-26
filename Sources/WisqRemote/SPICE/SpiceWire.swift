import Foundation

/// The SPICE wire format, as pure encoding and decoding over bytes.
///
/// Deliberately separate from the session that drives it. The session owns a
/// socket and an actor; this owns neither, so every framing rule here — the
/// magic, the packed layouts, the little-endian order, the refusal of a
/// truncated message — is checked by a test that needs no server and no
/// network. Protocol bugs live in exactly this layer, and this is the layer a
/// cheap runner can exercise exhaustively.
///
/// Little-endian throughout, which is the first thing that separates SPICE
/// from the RFB code next door: `ByteStream`'s readers are big-endian because
/// RFB is, and reaching for them here would be wrong in a way that still
/// mostly works — a length of 1 reads the same either way. So this file brings
/// its own reader rather than borrowing one that is right for the other
/// protocol.
enum SpiceWire {
    /// The four bytes that open every SPICE connection, in wire order.
    static let magic: [UInt8] = Array("REDQ".utf8)

    /// The protocol version this client speaks. SPICE has been at 2.2 since
    /// 0.8; a server answering anything else gets refused rather than guessed
    /// at.
    static let versionMajor: UInt32 = 2
    static let versionMinor: UInt32 = 2

    /// The server's public key travels inside the link reply as a fixed-width
    /// field, whatever the key actually is.
    static let publicKeyBytes = 162

    /// Channels, by the numbers the protocol assigns them.
    enum Channel: UInt8, Equatable, Sendable {
        case main = 1
        case display = 2
        case inputs = 3
        case cursor = 4
        case playback = 5
        case record = 6
    }

    /// Why a link was refused. Reported as-is rather than flattened to "failed",
    /// because these say genuinely different things to a user: a wrong password
    /// is theirs to fix, a version mismatch is not.
    enum LinkError: UInt32, Equatable, Sendable {
        case ok = 0
        case error = 1
        case invalidMagic = 2
        case invalidData = 3
        case versionMismatch = 4
        case needSecured = 5
        case needUnsecured = 6
        case permissionDenied = 7
        case badConnectionID = 8
        case channelNotAvailable = 9
    }

    /// Messages every channel understands, and the main-channel ones this
    /// milestone needs.
    enum Message {
        static let migrate: UInt16 = 1
        static let setAck: UInt16 = 2
        static let ping: UInt16 = 3
        static let waitForChannels: UInt16 = 4
        static let disconnecting: UInt16 = 5
        static let notify: UInt16 = 6
        static let mainInit: UInt16 = 103
        static let mainChannelsList: UInt16 = 104
        static let mainMouseMode: UInt16 = 105
        static let mainMultiMediaTime: UInt16 = 106
        static let mainAgentConnected: UInt16 = 107
        static let mainAgentDisconnected: UInt16 = 108
        static let mainAgentData: UInt16 = 109
        static let mainAgentToken: UInt16 = 110
        static let mainName: UInt16 = 113
        static let mainUUID: UInt16 = 114
        /// 115, and distinct from `mainAgentConnected` rather than a variant of
        /// it: this one carries the token count, and a server that sends it
        /// sends nothing else to say the agent is there. Treating only 107 as
        /// "the agent appeared" means the clipboard never starts on any server
        /// new enough to prefer this.
        static let mainAgentConnectedTokens: UInt16 = 115
    }

    enum ClientMessage {
        static let ackSync: UInt16 = 1
        static let ack: UInt16 = 2
        static let pong: UInt16 = 3
        /// 104, and it was 101 here for a long time.
        ///
        /// 101 is `CLIENT_INFO`. The main channel's client messages number
        /// from 101 in declaration order — `client_info`,
        /// `migrate_connected`, `migrate_connect_error`, then this — and the
        /// first of them is the one an eye lands on.
        ///
        /// Nothing caught it. The test asserted that what went out equalled
        /// this constant, which is true however wrong the constant is; and the
        /// scripted server sent its channel list whether or not it had been
        /// asked. Against a real server the effect is total: the list never
        /// arrives, `bringUp` runs to its limit and throws, and every channel
        /// built on top of it is unreachable.
        static let attachChannels: UInt16 = 104
        static let mouseModeRequest: UInt16 = 105
        static let agentStart: UInt16 = 106
        static let agentData: UInt16 = 107
        static let agentToken: UInt16 = 108
    }

    // MARK: - Reading

    /// A little-endian cursor that refuses to read past its end.
    ///
    /// Every decoder here goes through it, so "the server sent a short message"
    /// is one throw rather than a bounds check per field — the shape of bug
    /// that otherwise reads whatever memory follows.
    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = Array(data) }

        var remaining: Int { bytes.count - offset }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, remaining >= count else { throw SpiceError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }

        mutating func u16() throws -> UInt16 {
            let raw = try bytes(2)
            return UInt16(raw[0]) | UInt16(raw[1]) << 8
        }

        mutating func u32() throws -> UInt32 {
            let raw = try bytes(4)
            var value: UInt32 = 0
            for index in (0..<4).reversed() { value = value << 8 | UInt32(raw[index]) }
            return value
        }

        mutating func u64() throws -> UInt64 {
            let raw = try bytes(8)
            var value: UInt64 = 0
            for index in (0..<8).reversed() { value = value << 8 | UInt64(raw[index]) }
            return value
        }

        /// A reader positioned inside a message body.
        ///
        /// The display channel needs this: its pointers are offsets from the
        /// start of the message, so following one means reading from a place
        /// the cursor has already passed — or has not reached yet.
        init(_ raw: [UInt8], from start: Int) throws {
            guard start >= 0, start <= raw.count else { throw SpiceError.truncated }
            bytes = raw
            offset = start
        }

        /// Reads to the end. Used by messages whose tail is a variable payload.
        mutating func rest() -> [UInt8] {
            defer { offset = bytes.count }
            return Array(bytes[offset...])
        }
    }

    // MARK: - Writing

    static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) }
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(value >> (8 * $0) & 0xFF) }
    }

    // MARK: - Link

    /// The 16 bytes that open the connection, and the 18 that follow.
    ///
    /// `size` counts only what comes after the header, which is what lets a
    /// server read the header first and then the exact rest.
    static func linkRequest(
        connectionID: UInt32, channel: Channel, channelID: UInt8 = 0,
        commonCaps: [UInt32] = [], channelCaps: [UInt32] = []
    ) -> Data {
        var message: [UInt8] = []
        message += u32(connectionID)
        message += [channel.rawValue, channelID]
        message += u32(UInt32(commonCaps.count))
        message += u32(UInt32(channelCaps.count))
        // Where the capability words start, counted from the beginning of this
        // structure rather than of the whole packet — the protocol's own frame
        // of reference, and an easy one to get wrong by 16.
        message += u32(UInt32(linkMessageBytes))
        for capability in commonCaps + channelCaps { message += u32(capability) }

        var header: [UInt8] = magic
        header += u32(versionMajor)
        header += u32(versionMinor)
        header += u32(UInt32(message.count))
        return Data(header + message)
    }

    static let headerBytes = 16
    static let linkMessageBytes = 18

    struct LinkReply: Equatable, Sendable {
        var error: LinkError
        var publicKey: [UInt8]
        var commonCaps: [UInt32]
        var channelCaps: [UInt32]
    }

    /// Decodes the header the server answers with, returning how many more
    /// bytes belong to this reply.
    static func decodeLinkHeader(_ data: Data) throws -> Int {
        var reader = Reader(data)
        guard try reader.bytes(4) == magic else { throw SpiceError.notSpice }
        let major = try reader.u32()
        let minor = try reader.u32()
        guard major == versionMajor else {
            throw SpiceError.versionMismatch(major: major, minor: minor)
        }
        let size = try reader.u32()
        // A server is free to send capabilities, but a size that would have us
        // allocate megabytes for a link reply is a server we should not be
        // talking to.
        guard size >= 178, size <= 4096 else { throw SpiceError.invalidLinkSize(size) }
        return Int(size)
    }

    static func decodeLinkReply(_ data: Data) throws -> LinkReply {
        var reader = Reader(data)
        guard let error = LinkError(rawValue: try reader.u32()) else {
            throw SpiceError.invalidData
        }
        let publicKey = try reader.bytes(publicKeyBytes)
        let commonCount = try reader.u32()
        let channelCount = try reader.u32()
        _ = try reader.u32() // caps offset: the caps follow, which is all we need
        var common: [UInt32] = []
        var channel: [UInt32] = []
        for _ in 0..<commonCount { common.append(try reader.u32()) }
        for _ in 0..<channelCount { channel.append(try reader.u32()) }
        return LinkReply(
            error: error, publicKey: publicKey, commonCaps: common, channelCaps: channel
        )
    }

    /// The capability bitmap a client sends at link time, from a set of bit
    /// positions.
    ///
    /// **A capability's number is a bit index, not a value**: capability 6 is
    /// bit 6 of word 0, and capability 33 would be bit 1 of word 1. Every
    /// channel has its own numbering — the audio channels do not even agree
    /// with each other — so this takes raw indices and leaves each channel to
    /// own its enum.
    static func capabilityWords(_ bits: [Int]) -> [UInt32] {
        guard let highest = bits.max() else { return [] }
        var words = [UInt32](repeating: 0, count: highest / 32 + 1)
        for bit in bits { words[bit / 32] |= 1 << UInt32(bit % 32) }
        return words
    }

    // MARK: - Messages

    /// The 18-byte header in front of every message once the link is up.
    struct DataHeader: Equatable, Sendable {
        var serial: UInt64
        var type: UInt16
        var size: UInt32
        var subList: UInt32 = 0
    }

    static let dataHeaderBytes = 18

    static func encode(_ header: DataHeader) -> Data {
        Data(u64(header.serial) + u16(header.type) + u32(header.size) + u32(header.subList))
    }

    static func decodeDataHeader(_ data: Data) throws -> DataHeader {
        var reader = Reader(data)
        return DataHeader(
            serial: try reader.u64(), type: try reader.u16(),
            size: try reader.u32(), subList: try reader.u32()
        )
    }

    static func message(_ type: UInt16, serial: UInt64, payload: Data = Data()) -> Data {
        encode(DataHeader(serial: serial, type: type, size: UInt32(payload.count))) + payload
    }

    struct MainInit: Equatable, Sendable {
        var sessionID: UInt32
        var displayChannelsHint: UInt32
        var supportedMouseModes: UInt32
        var currentMouseMode: UInt32
        var agentConnected: Bool
        var agentTokens: UInt32
        var multiMediaTime: UInt32
        var ramHint: UInt32
    }

    static func decodeMainInit(_ data: Data) throws -> MainInit {
        var reader = Reader(data)
        return MainInit(
            sessionID: try reader.u32(),
            displayChannelsHint: try reader.u32(),
            supportedMouseModes: try reader.u32(),
            currentMouseMode: try reader.u32(),
            agentConnected: try reader.u32() != 0,
            agentTokens: try reader.u32(),
            multiMediaTime: try reader.u32(),
            ramHint: try reader.u32()
        )
    }

    struct ChannelID: Equatable, Sendable {
        var type: UInt8
        var id: UInt8
    }

    static func decodeChannelsList(_ data: Data) throws -> [ChannelID] {
        var reader = Reader(data)
        let count = try reader.u32()
        // Appended one at a time, deliberately, rather than through `map` over
        // `0..<count`. `map` reserves capacity from the sequence's count before
        // reading anything, so a server claiming four billion channels would
        // have us size an array from a number it chose — and the byte that is
        // missing would only be noticed afterwards.
        //
        // A bound on the count would also have worked, but it is a rule that
        // has to be remembered; not allocating from an untrusted number is a
        // shape that cannot be forgotten. On Linux the reservation is virtual
        // and costs nothing, so no test here can tell the two apart — which is
        // exactly why this is built not to need one.
        var channels: [ChannelID] = []
        for _ in 0..<count {
            channels.append(ChannelID(type: try reader.u8(), id: try reader.u8()))
        }
        return channels
    }

    struct Ping: Equatable, Sendable {
        var id: UInt32
        var timestamp: UInt64
    }

    static func decodePing(_ data: Data) throws -> Ping {
        var reader = Reader(data)
        return Ping(id: try reader.u32(), timestamp: try reader.u64())
    }

    static func encodePong(_ ping: Ping) -> Data {
        Data(u32(ping.id) + u64(ping.timestamp))
    }

    struct SetAck: Equatable, Sendable {
        var generation: UInt32
        var window: UInt32
    }

    static func decodeSetAck(_ data: Data) throws -> SetAck {
        var reader = Reader(data)
        return SetAck(generation: try reader.u32(), window: try reader.u32())
    }

    /// A server-sent notice. The text is what a user would be told, so it is
    /// carried out rather than logged and dropped.
    struct Notify: Equatable, Sendable {
        var severity: UInt32
        var text: String
    }

    static func decodeNotify(_ data: Data) throws -> Notify {
        var reader = Reader(data)
        _ = try reader.u64() // timestamp
        let severity = try reader.u32()
        _ = try reader.u32() // visibility
        _ = try reader.u32() // what
        let length = try reader.u32()
        let raw = try reader.bytes(Int(length))
        return Notify(severity: severity, text: String(decoding: raw, as: UTF8.self))
    }
}

/// What can go wrong before a SPICE session exists.
enum SpiceError: Error, Equatable {
    case notSpice
    case versionMismatch(major: UInt32, minor: UInt32)
    case invalidLinkSize(UInt32)
    case truncated
    case invalidData
    case refused(SpiceWire.LinkError)
    case ticketUnavailable
    /// The server talked, but never got to the point. Kept apart from each
    /// other because they say different things: one means the session never
    /// started, the other that it started and stalled.
    case noMainInit
    case noChannelList
}
