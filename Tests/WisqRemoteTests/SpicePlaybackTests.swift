import XCTest
@testable import WisqRemote

/// The playback channel: the wire, and what the state machine decides.
final class SpicePlaybackTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func u16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(value >> (8 * $0) & 0xFF) } }

    private func startMessage(
        channels: UInt32 = 2, format: UInt16 = 1, frequency: UInt32 = 44_100, time: UInt32 = 7
    ) -> [UInt8] {
        u32(channels) + u16(format) + u32(frequency) + u32(time)
    }

    // MARK: - Le fil

    func testStartCarriesTheStreamsShapeAndItsClock() throws {
        let start = try SpicePlaybackWire.start(startMessage())
        XCTAssertEqual(start.channels, 2)
        XCTAssertEqual(start.format, .s16)
        XCTAssertEqual(start.frequency, 44_100)
        XCTAssertEqual(start.time, 7)
    }

    /// **A format this build does not know is refused rather than assumed.**
    ///
    /// SPICE has exactly one that is not `INVALID`, so anything else is a
    /// server speaking a protocol this is not. Playing a float-encoded stream
    /// as signed sixteen-bit is not a quiet failure: it is noise at full
    /// volume, out of a phone, at whatever hour it happens.
    func testAFormatThisDoesNotKnowIsRefused() {
        for format in [UInt16(0), 2, 9, 0xFFFF] {
            XCTAssertThrowsError(
                try SpicePlaybackWire.start(startMessage(format: format)),
                "format \(format)"
            )
        }
    }

    /// Zero channels makes every frame empty and zero frequency divides. Both
    /// come off a socket, so both are refused before anything is sized from
    /// them.
    func testAStreamWithNoChannelsOrNoRateIsRefused() {
        XCTAssertThrowsError(try SpicePlaybackWire.start(startMessage(channels: 0)))
        XCTAssertThrowsError(try SpicePlaybackWire.start(startMessage(frequency: 0)))
        XCTAssertThrowsError(try SpicePlaybackWire.start(startMessage(channels: 64)))
        XCTAssertThrowsError(try SpicePlaybackWire.start(startMessage(frequency: 4_000_000)))
    }

    /// **`MODE` carries a packet of its own**, which is easy to miss: the
    /// reference gives it the same `time` and trailing bytes a `DATA` message
    /// has, so a mode change can deliver its first samples in the same message.
    /// Reading the mode and dropping the rest loses them.
    func testAModeChangeCarriesItsOwnFirstPacket() throws {
        let change = try SpicePlaybackWire.modeChange(u32(99) + u16(1) + [1, 2, 3, 4])
        XCTAssertEqual(change.time, 99)
        XCTAssertEqual(change.mode, .raw)
        XCTAssertEqual(change.data, [1, 2, 3, 4], "les octets après le mode sont un paquet")
    }

    /// A codec this build has never heard of is not a malformed message — it is
    /// a server offering something newer. Reported as `invalid` so the channel
    /// can fall silent rather than drop the connection.
    func testAnUnknownCodecIsReportedRatherThanThrown() throws {
        let change = try SpicePlaybackWire.modeChange(u32(0) + u16(77) + [9])
        XCTAssertEqual(change.mode, .invalid)
    }

    func testOnlyRawIsDecodedAndTheOthersAreNamed() {
        XCTAssertTrue(SpicePlaybackWire.DataMode.raw.isDecoded)
        for mode in SpicePlaybackWire.DataMode.allCases where mode != .raw {
            XCTAssertFalse(mode.isDecoded, "\(mode)")
        }
        // Les valeurs de l'énumération de référence, en toutes lettres.
        XCTAssertEqual(SpicePlaybackWire.DataMode.invalid.rawValue, 0)
        XCTAssertEqual(SpicePlaybackWire.DataMode.raw.rawValue, 1)
        XCTAssertEqual(SpicePlaybackWire.DataMode.celt.rawValue, 2)
        XCTAssertEqual(SpicePlaybackWire.DataMode.opus.rawValue, 3)
    }

    /// A count byte, then that many sixteen-bit levels. Nothing says the count
    /// matches what `START` declared, and this does not assume it does.
    func testVolumeIsACountThenThatManyLevels() throws {
        let volume = try SpicePlaybackWire.volume([3] + u16(0x1234) + u16(0) + u16(0xFFFF))
        XCTAssertEqual(volume.levels, [0x1234, 0, 0xFFFF])
    }

    func testATruncatedVolumeIsRefusedRatherThanPaddedWithSilence() {
        XCTAssertThrowsError(try SpicePlaybackWire.volume([4] + u16(1) + u16(2)))
    }

    func testMuteAndLatencyAreTheirOwnSmallMessages() throws {
        XCTAssertTrue(try SpicePlaybackWire.mute([1]))
        XCTAssertFalse(try SpicePlaybackWire.mute([0]))
        XCTAssertEqual(try SpicePlaybackWire.latency(u32(120)), 120)
    }

    // MARK: - Ce qu'on annonce

    /// **The two audio channels do not share their numbering**, and `VOLUME`
    /// agreeing at bit 1 is exactly what makes the disagreement dangerous: a
    /// transposition passes the one capability wisq actually sends.
    ///
    /// The record enum has no `LATENCY`, so `OPUS` is bit 2 there against bit 3
    /// here. Written out at both ends rather than derived, because a number
    /// that comes from somewhere else and is checked against itself is not
    /// checked.
    func testTheAudioChannelsNumberTheirCapabilitiesDifferently() {
        XCTAssertEqual(SpicePlaybackWire.Capability.celt.rawValue, 0)
        XCTAssertEqual(SpicePlaybackWire.Capability.volume.rawValue, 1)
        XCTAssertEqual(SpicePlaybackWire.Capability.latency.rawValue, 2)
        XCTAssertEqual(SpicePlaybackWire.Capability.opus.rawValue, 3)

        XCTAssertEqual(SpiceRecordWire.Capability.celt.rawValue, 0)
        XCTAssertEqual(SpiceRecordWire.Capability.volume.rawValue, 1)
        XCTAssertEqual(SpiceRecordWire.Capability.opus.rawValue, 2)

        XCTAssertNotEqual(
            SpicePlaybackWire.Capability.opus.rawValue,
            SpiceRecordWire.Capability.opus.rawValue,
            "le même codec, deux positions — c'est le canal qui tranche"
        )
    }

    /// **Announcing a codec would silence the sound**, which is the opposite of
    /// what adding a capability usually does.
    ///
    /// `snd_desired_audio_mode` returns `OPUS` only when
    /// `test_remote_cap(SPICE_PLAYBACK_CAP_OPUS)` is set, and `RAW` otherwise —
    /// CELT is not in the modern path at all. wisq decodes raw PCM and nothing
    /// else, so saying nothing about codecs is what gets it something it can
    /// play. The same shape as the display channel's absent `multiCodec`.
    func testNoCodecIsAnnouncedOnEitherAudioChannel() {
        for capability in SpicePlaybackWire.advertised {
            XCTAssertNotEqual(capability, .opus, "annoncer Opus rendrait l'audio muet")
            XCTAssertNotEqual(capability, .celt)
        }
        for capability in SpiceRecordWire.advertised {
            XCTAssertNotEqual(capability, .opus, "wisq n'encode que du PCM")
            XCTAssertNotEqual(capability, .celt)
        }
    }

    /// **Volume is announced because otherwise it is never sent.**
    ///
    /// `snd_send_volume` and `snd_send_mute` both begin with
    /// `if (!rcc->test_remote_cap(cap)) return false`, gated on
    /// `SPICE_PLAYBACK_CAP_VOLUME` and `SPICE_RECORD_CAP_VOLUME`. Without it
    /// the four readers wisq has for those messages are decoders the wire never
    /// reaches — the `sizedStream` shape again, at a lower cost.
    func testVolumeIsAnnouncedOnBothAudioChannels() {
        XCTAssertTrue(SpicePlaybackWire.advertised.contains(.volume))
        XCTAssertTrue(SpiceRecordWire.advertised.contains(.volume))

        // Et ce qui part sur le fil est bien le bit 1, dans les deux cas.
        XCTAssertEqual(SpicePlaybackWire.capabilityWords(SpicePlaybackWire.advertised), [0b10])
        XCTAssertEqual(SpiceRecordWire.capabilityWords(SpiceRecordWire.advertised), [0b10])
    }

    /// A capability's number is a bit index rather than a value, and the shared
    /// helper has to place a high one in the right word. 33 is bit 1 of word 1.
    func testACapabilityNumberIsABitPositionAcrossWords() {
        XCTAssertEqual(SpiceWire.capabilityWords([]), [])
        XCTAssertEqual(SpiceWire.capabilityWords([0]), [0b1])
        XCTAssertEqual(SpiceWire.capabilityWords([1, 3]), [0b1010])
        XCTAssertEqual(SpiceWire.capabilityWords([33]), [0, 0b10])
        XCTAssertEqual(SpiceWire.capabilityWords([0, 33]), [0b1, 0b10])
    }

    // MARK: - L'état

    private func started(channels: Int = 2) -> SpicePlayback {
        var playback = SpicePlayback()
        playback.start(SpicePlaybackWire.Start(
            channels: UInt32(channels), format: .s16, frequency: 48_000, time: 0
        ))
        return playback
    }

    /// **The mode starts at `raw`**, because a server that never sends `MODE`
    /// is sending PCM. Treating "no mode yet" as unknown would drop the opening
    /// of every such stream — and the opening is the part a user notices.
    func testTheCodecIsPCMUntilAModeMessageSaysOtherwise() {
        XCTAssertEqual(SpicePlayback().mode, .raw)
    }

    /// **Signed sixteen-bit little-endian, interleaved by channel.**
    ///
    /// Reading it the other way round gives samples that are still in range and
    /// still move smoothly, so the failure is loud noise rather than silence —
    /// which is exactly why the byte order needs a test that would notice.
    /// `0x0102` and `0x0201` are different numbers; `0x0101` would not be.
    func testSamplesAreLittleEndianAndInterleaved() throws {
        let playback = started(channels: 2)
        let frames = try XCTUnwrap(playback.frames(from: SpicePlaybackWire.Packet(
            time: 5, data: [0x02, 0x01, 0x04, 0x03, 0xFF, 0xFF, 0x00, 0x80]
        )))
        XCTAssertEqual(frames.samples, [0x0102, 0x0304, -1, -32_768])
        XCTAssertEqual(frames.channels, 2)
        XCTAssertEqual(frames.frameCount, 2, "quatre échantillons sur deux canaux")
        XCTAssertEqual(frames.frequency, 48_000)
        XCTAssertEqual(frames.time, 5)
    }

    /// A packet that does not fill a whole frame plays nothing rather than a
    /// partial one — half a stereo frame would shift every channel after it.
    func testAPacketWithNoWholeFramePlaysNothing() {
        let playback = started(channels: 2)
        XCTAssertNil(playback.frames(from: SpicePlaybackWire.Packet(time: 0, data: [1, 2, 3])))
        XCTAssertNil(playback.frames(from: SpicePlaybackWire.Packet(time: 0, data: [])))
    }

    /// Samples arriving before a `START` have no shape to be read as.
    func testDataBeforeAStartPlaysNothing() {
        let playback = SpicePlayback()
        XCTAssertNil(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [1, 2, 3, 4]
        )))
    }

    /// A codec with no decoder plays nothing rather than being read as PCM —
    /// Opus bytes played as samples are noise, and loud.
    func testACodecWithNoDecoderPlaysNothingRatherThanNoise() {
        var playback = started()
        playback.setMode(.opus)
        XCTAssertNil(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [1, 2, 3, 4]
        )))
        playback.setMode(.raw)
        XCTAssertNotNil(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [1, 2, 3, 4]
        )))
    }

    /// **Muting drops the packet rather than zeroing it**, which is what the
    /// reference does and also what stops a muted session spending a phone's
    /// battery on silence.
    func testMutingDropsThePacketRatherThanZeroingIt() {
        var playback = started()
        playback.setMuted(true)
        XCTAssertNil(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [1, 2, 3, 4]
        )))
        playback.setMuted(false)
        XCTAssertNotNil(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [1, 2, 3, 4]
        )))
    }

    /// **`STOP` forgets the stream and keeps the codec.**
    ///
    /// A server that stops and restarts does not resend `MODE`, so resetting it
    /// here would make everything after the restart undecodable — and the
    /// symptom would be a stream that works once and is silent ever after.
    func testStoppingForgetsTheStreamButNotTheCodec() {
        var playback = started()
        playback.setMode(.opus)
        playback.stop()

        XCTAssertNil(playback.stream)
        XCTAssertEqual(playback.mode, .opus, "le codec survit à un arrêt")
    }

    /// The volume and the latency are remembered as the server sent them,
    /// without being applied to the samples: SPICE's volume is the *guest's*
    /// mixer setting, and applying it here would attenuate twice.
    func testVolumeAndLatencyAreRememberedRatherThanApplied() throws {
        var playback = started()
        playback.setVolume([0, 0])
        playback.setLatency(90)

        XCTAssertEqual(playback.volume, [0, 0])
        XCTAssertEqual(playback.latencyMilliseconds, 90)
        let frames = try XCTUnwrap(playback.frames(from: SpicePlaybackWire.Packet(
            time: 0, data: [0xFF, 0x7F, 0xFF, 0x7F]
        )))
        XCTAssertEqual(
            frames.samples, [32_767, 32_767],
            "un volume nul ne doit pas atténuer les échantillons ici"
        )
    }
}
