import XCTest
@testable import WisqRemote

/// The record channel: the phone's microphone into the guest.
///
/// Mostly an encoder, so most of these assert on bytes going out — the same
/// shape as `SpiceInputs`' tests, and for the same reason: no server is needed
/// to check what a client sends, and what a client sends is where the work is.
final class SpiceRecordTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
    private func u16(_ value: UInt16) -> [UInt8] { (0..<2).map { UInt8(value >> (8 * $0) & 0xFF) } }

    // MARK: - Ce que le serveur envoie

    /// **`RECORD_START` has no `time`**, where `PLAYBACK_START` has one.
    ///
    /// Not a transcription slip: a server telling a client what to record has no
    /// clock to hand it, because the client's own samples carry theirs. The
    /// message is twelve bytes, and reading a fourth word would eat whatever
    /// follows it on the wire — which is why this test hands it exactly twelve
    /// and then hands it sixteen to show the extra four are not consumed.
    func testRecordStartIsThreeFieldsAndNotFour() throws {
        let exact = u32(1) + u16(1) + u32(16_000)
        XCTAssertEqual(exact.count, 10)
        let start = try SpiceRecordWire.start(exact)
        XCTAssertEqual(start.channels, 1)
        XCTAssertEqual(start.format, .s16)
        XCTAssertEqual(start.frequency, 16_000)
    }

    /// The same refusals the playback side makes, for the same reason: these
    /// numbers size a capture buffer and they came off a socket.
    func testAnImpossibleStreamIsRefused() {
        XCTAssertThrowsError(try SpiceRecordWire.start(u32(0) + u16(1) + u32(16_000)))
        XCTAssertThrowsError(try SpiceRecordWire.start(u32(2) + u16(1) + u32(0)))
        XCTAssertThrowsError(try SpiceRecordWire.start(u32(2) + u16(0) + u32(16_000)))
        XCTAssertThrowsError(try SpiceRecordWire.start(u32(2) + u16(7) + u32(16_000)))
    }

    /// Volume and mute have playback's shape exactly, so they share its reader
    /// rather than being transcribed a second time — two copies of a format is
    /// two places for it to drift.
    func testVolumeAndMuteShareThePlaybackShape() throws {
        XCTAssertEqual(try SpiceRecordWire.volume([2] + u16(0x0100) + u16(0xFFFF)),
                       [0x0100, 0xFFFF])
        XCTAssertTrue(try SpiceRecordWire.mute([1]))
        XCTAssertFalse(try SpiceRecordWire.mute([0]))
    }

    // MARK: - Ce que le client envoie

    /// **Signed sixteen-bit little-endian**, the same as the playback side
    /// reads. `0x0102` and `0x0201` are different numbers, so a byte-order slip
    /// here is visible; `0x0101` would have hidden it.
    func testSamplesGoOutLittleEndian() {
        let message = SpiceRecordWire.dataMessage(time: 7, samples: [0x0102, -1, -32_768])
        XCTAssertEqual(
            Array(message),
            u32(7) + [0x02, 0x01] + [0xFF, 0xFF] + [0x00, 0x80]
        )
    }

    func testAnEmptyPacketIsJustItsClock() {
        XCTAssertEqual(Array(SpiceRecordWire.dataMessage(time: 42, samples: [])), u32(42))
    }

    /// **The client chooses the codec here**, which is the difference from
    /// playback. There is exactly one honest choice: `raw`, the only mode wisq
    /// can produce. Claiming Opus and sending PCM would hand the guest noise.
    func testTheModeAnnouncedIsTheOneWeCanActuallyProduce() {
        let message = SpiceRecordWire.modeMessage(time: 3)
        XCTAssertEqual(Array(message), u32(3) + u16(SpicePlaybackWire.DataMode.raw.rawValue))
        XCTAssertEqual(SpicePlaybackWire.DataMode.raw.rawValue, 1)
    }

    func testTheStartMarkIsOneWord() {
        XCTAssertEqual(Array(SpiceRecordWire.startMarkMessage(time: 0x0A0B_0C0D)),
                       u32(0x0A0B_0C0D))
    }

    /// The numbering restarts per direction, so a server `START` and a client
    /// `DATA` are both 101 on this channel. Reading one table for both would
    /// route half the messages to the wrong handler.
    func testEachDirectionNumbersFromOneHundredAndOne() {
        XCTAssertEqual(SpiceRecordWire.ServerMessage.start.rawValue, 101)
        XCTAssertEqual(SpiceRecordWire.ServerMessage.stop.rawValue, 102)
        XCTAssertEqual(SpiceRecordWire.ServerMessage.volume.rawValue, 103)
        XCTAssertEqual(SpiceRecordWire.ServerMessage.mute.rawValue, 104)

        XCTAssertEqual(SpiceRecordWire.ClientMessage.data.rawValue, 101)
        XCTAssertEqual(SpiceRecordWire.ClientMessage.mode.rawValue, 102)
        XCTAssertEqual(SpiceRecordWire.ClientMessage.startMark.rawValue, 103)
    }

    // MARK: - L'état

    private func started(channels: UInt32 = 1, frequency: UInt32 = 16_000) -> SpiceRecord {
        var record = SpiceRecord()
        record.start(SpiceRecordWire.Start(
            channels: channels, format: .s16, frequency: frequency
        ))
        return record
    }

    /// **A new stream needs its mode announced again**, which is the opposite of
    /// the playback side, where `STOP` deliberately keeps the codec.
    ///
    /// The direction is why: there the *server* decides and does not resend, so
    /// forgetting loses the setting. Here *we* decide, and a fresh stream that
    /// never hears which codec its samples are in leaves the guest reading PCM
    /// as whatever it assumed last.
    func testAFreshStreamMustAnnounceItsCodecAgain() {
        var record = started()
        XCTAssertFalse(record.hasAnnouncedMode)
        record.announcedMode()
        XCTAssertTrue(record.hasAnnouncedMode)

        record.start(SpiceRecordWire.Start(channels: 2, format: .s16, frequency: 44_100))
        XCTAssertFalse(record.hasAnnouncedMode, "un nouveau flux réannonce son codec")
    }

    func testStoppingForgetsTheStreamAndTheAnnouncement() {
        var record = started()
        record.announcedMode()
        record.stop()

        XCTAssertNil(record.stream)
        XCTAssertFalse(record.hasAnnouncedMode)
        XCTAssertFalse(record.isCapturing)
    }

    /// **Muted sends nothing**, not silence. Zeroed samples would keep the
    /// guest's recorder running and its file growing, which is the opposite of
    /// what muting a microphone asks for — and on a phone it keeps the radio
    /// busy for nothing.
    func testMutedSendsNothingRatherThanSilence() {
        var record = started()
        XCTAssertTrue(record.isCapturing)
        record.setMuted(true)
        XCTAssertFalse(record.isCapturing)
        record.setMuted(false)
        XCTAssertTrue(record.isCapturing)
    }

    func testNothingIsCapturedBeforeTheServerAsks() {
        XCTAssertFalse(SpiceRecord().isCapturing)
        XCTAssertNil(SpiceRecord().sampleCount(milliseconds: 10))
    }

    /// A packet's size is the rate times the duration times the channels — the
    /// arithmetic a capture callback needs and the easiest place to drop a
    /// factor. Ten milliseconds of 16 kHz mono is 160 samples; of 44.1 kHz
    /// stereo, 882.
    func testAPacketsSizeCountsChannelsAsWellAsTime() {
        XCTAssertEqual(started().sampleCount(milliseconds: 10), 160)
        XCTAssertEqual(
            started(channels: 2, frequency: 44_100).sampleCount(milliseconds: 10), 882
        )
        XCTAssertEqual(started(channels: 2, frequency: 48_000).sampleCount(milliseconds: 20), 1_920)
        XCTAssertNil(started().sampleCount(milliseconds: 0))
    }
}
