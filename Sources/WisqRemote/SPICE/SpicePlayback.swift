import Foundation

/// What the playback channel is currently playing, and what comes out of it.
///
/// A value rather than an audio engine, for the reason `TransportTuning` is a
/// value: everything decided here — which codec is in force, whether a packet
/// can be played, how many frames it holds, whether it is muted — is decidable
/// without a speaker, and a Linux runner can check all of it. What is left for
/// the platform is handing the frames to AVAudioEngine.
struct SpicePlayback {
    /// A stream the server has started.
    struct Stream: Equatable, Sendable {
        var channels: Int
        var frequency: Int
        var format: SpicePlaybackWire.Format
    }

    /// Samples ready to be played, as interleaved signed sixteen-bit frames.
    struct Frames: Equatable, Sendable {
        var samples: [Int16]
        var channels: Int
        var frequency: Int
        /// The server's multimedia clock for the first frame, in milliseconds.
        var time: UInt32

        var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
    }

    private(set) var stream: Stream?
    /// The codec in force. **`raw` until a `MODE` message says otherwise**,
    /// because a server that never sends one is sending PCM — the reference
    /// initialises its own mode the same way, and treating "no mode yet" as
    /// "unknown" would drop the opening of every such stream.
    private(set) var mode: SpicePlaybackWire.DataMode = .raw
    private(set) var isMuted = false
    /// Per-channel levels as the server last sent them, `nil` if it never has.
    private(set) var volume: [UInt16]?
    /// What the server says its own buffer is worth, in milliseconds.
    private(set) var latencyMilliseconds: UInt32?

    mutating func start(_ start: SpicePlaybackWire.Start) {
        stream = Stream(
            channels: Int(start.channels), frequency: Int(start.frequency),
            format: start.format
        )
    }

    /// `PLAYBACK_STOP`.
    ///
    /// **The mode is not reset**, and that is the reference's behaviour rather
    /// than an oversight: a server that stops and restarts a stream does not
    /// resend `MODE`, so forgetting it here would make everything after the
    /// restart undecodable. Only the stream's shape goes.
    mutating func stop() { stream = nil }

    mutating func setMode(_ mode: SpicePlaybackWire.DataMode) { self.mode = mode }
    mutating func setMuted(_ muted: Bool) { isMuted = muted }
    mutating func setVolume(_ levels: [UInt16]) { volume = levels }
    mutating func setLatency(_ milliseconds: UInt32) { latencyMilliseconds = milliseconds }

    /// One packet turned into frames, or `nil` when there is nothing to play.
    ///
    /// `nil` covers four different situations and deliberately does not
    /// distinguish them, because the answer is the same for all four — play
    /// nothing, stay connected:
    ///
    ///   * no stream has started, so there is no shape to read the bytes as;
    ///   * the codec is one this build has no decoder for;
    ///   * the guest is muted;
    ///   * the packet holds no whole frame.
    ///
    /// **Muting drops the packet rather than zeroing it.** Zeroed samples are
    /// still samples: they hold the clock and the buffer at the right length,
    /// which matters for a stream that is meant to resume in time. Dropping is
    /// what the reference does, and it is also what stops a muted session from
    /// spending a phone's battery on silence.
    func frames(from packet: SpicePlaybackWire.Packet) -> Frames? {
        guard let stream, !isMuted, mode.isDecoded else { return nil }
        guard stream.format == .s16, stream.channels > 0 else { return nil }

        let bytesPerFrame = stream.channels * 2
        let frameCount = packet.data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        // Signed sixteen-bit little-endian, interleaved by channel. Reading it
        // big-endian gives samples that are still in range and still change
        // smoothly, so it sounds like loud noise rather than like nothing —
        // which is why the order is worth a test of its own.
        var samples = [Int16]()
        samples.reserveCapacity(frameCount * stream.channels)
        for index in 0..<(frameCount * stream.channels) {
            let low = UInt16(packet.data[index * 2])
            let high = UInt16(packet.data[index * 2 + 1]) << 8
            samples.append(Int16(bitPattern: low | high))
        }
        return Frames(
            samples: samples, channels: stream.channels,
            frequency: stream.frequency, time: packet.time
        )
    }
}
