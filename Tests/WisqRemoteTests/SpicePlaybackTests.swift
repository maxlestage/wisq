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
