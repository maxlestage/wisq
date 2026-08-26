import Foundation

/// The playback channel: what the guest is playing.
///
/// Decoding only, and separated from anything that makes a sound, because the
/// two have opposite testability. The wire is a handful of small messages and a
/// stateful codec setting, all of which a Linux runner can check byte by byte;
/// actually putting samples into a speaker needs AVAudioEngine, exists only on
/// Apple, and would take the whole channel behind a platform guard with it.
enum SpicePlaybackWire {
    enum Message: UInt16, Equatable, Sendable {
        case data = 101
        case mode = 102
        case start = 103
        case stop = 104
        case volume = 105
        case mute = 106
        case latency = 107
    }

    /// What this client tells a playback server it can do.
    ///
    /// **The numbering is not shared with the record channel**, which is the
    /// trap worth writing down: `VOLUME` is bit 1 in both, but `OPUS` is bit 3
    /// here and bit 2 there, because the record enum has no `LATENCY`. Using
    /// one channel's constant on the other advertises a different capability,
    /// silently and in whichever direction the transposition went.
    enum Capability: Int, Equatable, Sendable {
        case celt = 0
        case volume = 1
        case latency = 2
        case opus = 3
    }

    /// The bitmap a client sends for a set of capabilities.
    static func capabilityWords(_ capabilities: [Capability]) -> [UInt32] {
        SpiceWire.capabilityWords(capabilities.map(\.rawValue))
    }

    /// **What wisq advertises, and why the codec is not in it.**
    ///
    /// `VOLUME` because the decoders exist and are tested, and because without
    /// it the server sends nothing: `snd_send_volume` and `snd_send_mute` both
    /// open with `if (!rcc->test_remote_cap(cap)) return false`. Not
    /// advertising it did not degrade anything — SPICE's volume is the guest's
    /// own mixer setting and wisq deliberately does not apply it — it simply
    /// meant four tested readers that the wire would never reach.
    ///
    /// **`OPUS` is absent on purpose, and adding it would silence the sound.**
    /// `snd_desired_audio_mode` is the whole decision:
    ///
    /// ```c
    /// if (!playback_compression) return SPICE_AUDIO_DATA_MODE_RAW;
    /// if (client_can_opus && snd_codec_is_capable(OPUS, frequency))
    ///     return SPICE_AUDIO_DATA_MODE_OPUS;
    /// return SPICE_AUDIO_DATA_MODE_RAW;
    /// ```
    ///
    /// `client_can_opus` is `test_remote_cap(SPICE_PLAYBACK_CAP_OPUS)`, and
    /// CELT is not even in the modern path. So a client that says nothing about
    /// codecs is handed raw PCM — exactly what wisq decodes. Announcing OPUS
    /// would make the server encode Opus and wisq play nothing at all. This is
    /// the same shape as the display channel's absent `multiCodec`: an absence
    /// that looks like an oversight and is load-bearing.
    ///
    /// `LATENCY` is not advertised either, and that one is a *don't know*
    /// rather than a decision: no send of `SPICE_MSG_PLAYBACK_LATENCY` appears
    /// in the server sources vendored for this work, so what advertising it
    /// would buy is unestablished. spice-gtk does advertise it.
    static let advertised: [Capability] = [.volume]

    /// How the samples in a `DATA` message are encoded.
    ///
    /// **Only `raw` is decoded**, and the others are named rather than lumped
    /// together as unknown — the same decision the video codecs got, for the
    /// same reason: "the server chose Opus" is something a user could act on,
    /// while silence is not.
    ///
    /// `SPICE_AUDIO_DATA_MODE_INVALID` is zero, so the useful values start at
    /// one. CELT 0.5.1 is marked deprecated in the reference's own header and
    /// modern servers negotiate Opus instead; neither ships a decoder here.
    enum DataMode: UInt16, Equatable, Sendable, CaseIterable {
        case invalid = 0
        case raw = 1
        case celt = 2
        case opus = 3

        var isDecoded: Bool { self == .raw }
    }

    /// The sample format. SPICE has exactly one that is not `INVALID`.
    ///
    /// Signed sixteen-bit, interleaved by channel, little-endian — the wire's
    /// order everywhere in this protocol. A one-value enum rather than an
    /// assumption, so that a server offering something else is refused instead
    /// of being played as noise at full volume, which is what reading a
    /// float-encoded stream as `S16` sounds like.
    enum Format: UInt16, Equatable, Sendable {
        case invalid = 0
        case s16 = 1
    }

    /// `PLAYBACK_START` — the stream's shape, and when it begins.
    struct Start: Equatable, Sendable {
        var channels: UInt32
        var format: Format
        var frequency: UInt32
        /// The server's multimedia clock, in milliseconds. Shared with the
        /// display channel's stream timestamps, which is what lets sound and
        /// picture be lined up.
        var time: UInt32
    }

    /// `PLAYBACK_DATA` — one packet of samples.
    struct Packet: Equatable, Sendable {
        var time: UInt32
        var data: [UInt8]
    }

    /// `PLAYBACK_MODE` — the codec for everything that follows.
    ///
    /// It carries data of its own, which is easy to miss: the reference gives
    /// it the same `time` and trailing bytes a `DATA` message has, so a mode
    /// change can deliver its first packet in the same message. Reading only
    /// the mode and dropping the rest loses that packet.
    struct ModeChange: Equatable, Sendable {
        var time: UInt32
        var mode: DataMode
        var data: [UInt8]
    }

    /// `PLAYBACK_VOLUME` — one level a channel.
    ///
    /// The count is a byte and the levels are sixteen bits each, running to the
    /// end of the message. A stereo stream sends two; nothing says the count
    /// has to match what `START` declared, and this does not assume it does.
    struct Volume: Equatable, Sendable {
        var levels: [UInt16]
    }

    // MARK: - Décodage

    static func start(_ payload: [UInt8]) throws -> Start {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let channels = try reader.u32()
        let rawFormat = try reader.u16()
        guard let format = Format(rawValue: rawFormat), format != .invalid else {
            throw SpiceError.invalidData
        }
        let frequency = try reader.u32()
        // Both come off a socket and both are used to size buffers. A frequency
        // of zero would divide, and a channel count of zero would make every
        // frame empty; refusing is the only reading that stays a stream.
        guard channels > 0, channels <= 8, frequency > 0, frequency <= 384_000 else {
            throw SpiceError.invalidData
        }
        return Start(
            channels: channels, format: format, frequency: frequency, time: try reader.u32()
        )
    }

    static func packet(_ payload: [UInt8]) throws -> Packet {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return Packet(time: try reader.u32(), data: reader.rest())
    }

    static func modeChange(_ payload: [UInt8]) throws -> ModeChange {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let time = try reader.u32()
        let raw = try reader.u16()
        // An unknown mode is not a malformed message — it is a server offering a
        // codec this build has never heard of. Reported as `invalid` so the
        // channel can fall silent for it rather than drop the connection.
        let mode = DataMode(rawValue: raw) ?? .invalid
        return ModeChange(time: time, mode: mode, data: reader.rest())
    }

    static func volume(_ payload: [UInt8]) throws -> Volume {
        var reader = try SpiceWire.Reader(payload, from: 0)
        let count = Int(try reader.u8())
        return Volume(levels: try (0..<count).map { _ in try reader.u16() })
    }

    static func mute(_ payload: [UInt8]) throws -> Bool {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return try reader.u8() != 0
    }

    static func latency(_ payload: [UInt8]) throws -> UInt32 {
        var reader = try SpiceWire.Reader(payload, from: 0)
        return try reader.u32()
    }
}
