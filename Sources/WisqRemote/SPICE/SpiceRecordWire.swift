import Foundation

/// The record channel: the phone's microphone into the guest.
///
/// The mirror of playback, and the direction is the whole difference. There,
/// the server describes a stream and sends samples; here the server describes
/// the stream it wants and **the client sends the samples**. So this file is
/// mostly an encoder, checked the way `SpiceInputs` is — no server needed,
/// because what has to be right is the bytes that go out.
enum SpiceRecordWire {
    /// What this client tells a record server it can do.
    ///
    /// **Three entries where playback has four, and that is the whole trap.**
    /// The record enum has no `LATENCY`, so `OPUS` sits at bit 2 here against
    /// bit 3 on playback. `VOLUME` happens to agree at bit 1. Borrowing the
    /// playback constant for this channel would advertise a bit the record
    /// server has no name for; borrowing this one for playback would advertise
    /// `LATENCY`. Two enums rather than one shared, for exactly that reason.
    enum Capability: Int, Equatable, Sendable {
        case celt = 0
        case volume = 1
        case opus = 2
    }

    static func capabilityWords(_ capabilities: [Capability]) -> [UInt32] {
        SpiceWire.capabilityWords(capabilities.map(\.rawValue))
    }

    /// `VOLUME` for the reason playback advertises it — `snd_send_volume` and
    /// `snd_send_mute` are gated on `SPICE_RECORD_CAP_VOLUME` and send nothing
    /// without it — and no codec, for the reason playback names no codec: this
    /// client produces raw PCM and says so in `RECORD_MODE`. Advertising `OPUS`
    /// here would be a claim about what wisq can *encode*, which is the
    /// direction that matters on this channel, and it would be false.
    static let advertised: [Capability] = [.volume]

    /// What the server sends.
    ///
    /// The numbering restarts at 101 for each direction, so a server `START`
    /// and a client `DATA` are both 101 on the same channel. Two enums rather
    /// than one, because a single one would have to pick a winner.
    enum ServerMessage: UInt16, Equatable, Sendable {
        case start = 101
        case stop = 102
        case volume = 103
        case mute = 104
    }

    /// What the client sends.
    enum ClientMessage: UInt16, Equatable, Sendable {
        case data = 101
        case mode = 102
        case startMark = 103
    }

    /// `RECORD_START` — the shape of the stream the guest is asking for.
    ///
    /// **No `time` field**, where `PLAYBACK_START` has one. The asymmetry is
    /// real and not a transcription slip: a server telling a client what to
    /// record has no clock to hand it, because the client's samples carry
    /// their own. Reading a fourth word here would consume whatever follows the
    /// message.
    struct Start: Equatable, Sendable {
        var channels: UInt32
        var format: SpicePlaybackWire.Format
        var frequency: UInt32
    }

    static func start(_ payload: [UInt8]) throws -> Start {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let channels = try reader.u32()
        let rawFormat = try reader.u16()
        guard let format = SpicePlaybackWire.Format(rawValue: rawFormat), format != .invalid else {
            throw SpiceError.invalidData
        }
        let frequency = try reader.u32()
        // The same bounds the playback side uses, for the same reason: these
        // size the capture buffer and they come off a socket.
        guard channels > 0, channels <= 8, frequency > 0, frequency <= 384_000 else {
            throw SpiceError.invalidData
        }
        return Start(channels: channels, format: format, frequency: frequency)
    }

    /// `RECORD_VOLUME` and `RECORD_MUTE` have the same shape as playback's, so
    /// they are read by the same code rather than transcribed twice.
    static func volume(_ payload: [UInt8]) throws -> [UInt16] {
        try SpicePlaybackWire.volume(payload).levels
    }

    static func mute(_ payload: [UInt8]) throws -> Bool {
        try SpicePlaybackWire.mute(payload)
    }

    // MARK: - Ce que le client envoie

    /// `RECORD_MODE` — the codec the client is about to use.
    ///
    /// **Sent before any data, and sent by us.** On playback the server chooses
    /// and the client copes; here the client chooses, so there is exactly one
    /// honest choice: `raw`, the only mode wisq can produce. Claiming Opus and
    /// sending PCM would hand the guest noise.
    ///
    /// It carries a `time` and, like its playback twin, may carry a first
    /// packet. wisq sends it empty — a mode message that also delivers samples
    /// saves one message per stream and costs a reader who has to know that.
    static func modeMessage(time: UInt32, mode: SpicePlaybackWire.DataMode = .raw) -> Data {
        Data(SpiceWire.u32(time) + SpiceWire.u16(mode.rawValue))
    }

    /// `RECORD_START_MARK` — "the samples start here".
    ///
    /// One word, and it is the client's own clock rather than the server's.
    /// It is what lets the guest line up what it records with what it played.
    static func startMarkMessage(time: UInt32) -> Data {
        Data(SpiceWire.u32(time))
    }

    /// `RECORD_DATA` — a packet of captured samples.
    ///
    /// Signed sixteen-bit little-endian, interleaved by channel: the same
    /// format the playback side reads, written rather than read. The order is
    /// worth the same care in both directions — a big-endian mistake here sends
    /// the guest noise instead of receiving it.
    static func dataMessage(time: UInt32, samples: [Int16]) -> Data {
        var bytes = SpiceWire.u32(time)
        bytes.reserveCapacity(4 + samples.count * 2)
        for sample in samples {
            let raw = UInt16(bitPattern: sample)
            bytes.append(UInt8(raw & 0xFF))
            bytes.append(UInt8(raw >> 8))
        }
        return Data(bytes)
    }
}

/// What the client is currently being asked to capture.
///
/// The mirror of `SpicePlayback`, and it answers one question: given what the
/// server asked for and what has happened since, should this packet be sent at
/// all, and does it need a mode message in front of it?
struct SpiceRecord {
    struct Stream: Equatable, Sendable {
        var channels: Int
        var frequency: Int
        var format: SpicePlaybackWire.Format
    }

    private(set) var stream: Stream?
    private(set) var isMuted = false
    private(set) var volume: [UInt16]?
    /// Whether the mode has been announced for the current stream.
    private(set) var hasAnnouncedMode = false

    mutating func start(_ start: SpiceRecordWire.Start) {
        stream = Stream(
            channels: Int(start.channels), frequency: Int(start.frequency),
            format: start.format
        )
        // **A new stream needs its mode announced again.** This is the opposite
        // of the playback side, where `STOP` deliberately keeps the codec: there
        // the server is the one who decides and does not resend it, so
        // forgetting would lose the setting. Here *we* decide, and a fresh
        // stream that never hears which codec its samples are in is a guest
        // reading PCM as whatever it assumed last.
        hasAnnouncedMode = false
    }

    mutating func stop() {
        stream = nil
        hasAnnouncedMode = false
    }

    mutating func setMuted(_ muted: Bool) { isMuted = muted }
    mutating func setVolume(_ levels: [UInt16]) { volume = levels }
    mutating func announcedMode() { hasAnnouncedMode = true }

    /// How many samples one packet of the given duration holds, or `nil` when
    /// there is no stream to size it against.
    func sampleCount(milliseconds: Int) -> Int? {
        guard let stream, milliseconds > 0 else { return nil }
        return stream.frequency * milliseconds / 1000 * stream.channels
    }

    /// Whether captured samples should go out at all.
    ///
    /// **Muted means send nothing**, not send silence. Sending zeroed samples
    /// would keep the guest's recorder running and its file growing, which is
    /// the opposite of what a user muting their microphone asked for — and on a
    /// phone it also keeps the radio busy for nothing.
    var isCapturing: Bool { stream != nil && !isMuted }
}
