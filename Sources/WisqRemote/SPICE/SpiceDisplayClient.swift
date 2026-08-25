import Foundation

/// What the client says to the display channel, rather than what it hears.
///
/// Small, and the reason it exists is not: **wisq decodes LZ, and this is how
/// it gets sent LZ.**
///
/// A SPICE server chooses its image encoding from its own configuration, and
/// the usual default is "automatic", which means QUIC for photographic content
/// and GLZ for graphic. Neither is decoded here yet. Without this message a
/// client that has an LZ decoder and nothing else watches most of the screen
/// arrive in an encoding it must skip — decoding a codec and being sent that
/// codec are two different achievements, and only the second puts a picture on
/// a phone.
///
/// So this is not a nicety deferred until the codecs are done. It is the piece
/// that makes the one finished codec worth having, and porting QUIC — some two
/// thousand lines of predictive coding — is an optimisation after it rather
/// than a prerequisite before it.
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

    /// `SPICE_MSGC_DISPLAY_INIT`, which the server waits for before it draws.
    ///
    /// The two sizes are the client saying how much it will remember. They are
    /// promises about this client's own memory, so they are chosen here rather
    /// than taken from the server: a phone is not a workstation, and a cache
    /// sized for one is a cache the other cannot hold.
    ///
    /// The GLZ dictionary window is zero, and that is a statement rather than a
    /// default: wisq does not decode GLZ, so a window would be memory reserved
    /// to hold history for images it will never assemble.
    static func initialise(
        pixmapCacheID: UInt8 = 0,
        pixmapCachePixels: Int64 = 4 << 20,
        glzDictionaryID: UInt8 = 0,
        glzWindowPixels: Int32 = 0
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
    /// `lz` rather than `autoLZ`, deliberately. The automatic modes leave the
    /// server free to send QUIC for photographic content — that is what
    /// "automatic" means — and this client cannot decode it, so an image it
    /// cannot use is worse than a less well compressed one it can.
    static func compressionToRequest(givenServerCapabilities caps: [UInt32]) -> Compression? {
        supports(.preferredCompression, in: caps) ? .lz : nil
    }
}
