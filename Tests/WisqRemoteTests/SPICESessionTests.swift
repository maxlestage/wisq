import Foundation
import WisqCore
import WisqNet
import XCTest
@testable import WisqRemote

/// The whole SPICE session, against a scripted two-socket server.
///
/// The point of these is the *shape* rather than the bytes, and the shape is
/// what makes SPICE different from RFB next door: **one TCP connection per
/// channel**, the main one first because it is the only one that learns the
/// session identifier, and every channel after it presenting that identifier.
/// Get that wrong and the server hands the second connection a display of its
/// own — a black screen that looks exactly like a broken decoder.
final class SPICESessionTests: XCTestCase {
    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
    private func u16(_ v: UInt16) -> [UInt8] { (0..<2).map { UInt8(v >> (8 * $0) & 0xFF) } }
    private func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }

    /// A ticket encryptor that encrypts nothing: the real one is `Security` and
    /// this test is about ordering, not cryptography.
    private let ticket: SpiceTicketEncryptor = { _, _ in Data(repeating: 0xAB, count: 128) }

    private func linkReply(channelCaps: [UInt32] = []) -> Data {
        var body = SpiceWire.u32(0)
        body += (0..<162).map { UInt8($0 % 256) }
        body += SpiceWire.u32(0)
        body += SpiceWire.u32(UInt32(channelCaps.count))
        body += SpiceWire.u32(178)
        for capability in channelCaps { body += SpiceWire.u32(capability) }
        let header = Array("REDQ".utf8) + SpiceWire.u32(2) + SpiceWire.u32(2)
            + SpiceWire.u32(UInt32(body.count))
        return Data(header + body)
    }

    /// `MAIN_INIT`, carrying the session identifier every later channel needs.
    private func mainInit(sessionID: UInt32) -> Data {
        var body = u32(sessionID)          // session id
        body += u32(1)                     // display channels hint
        body += u32(0) + u32(0)            // mouse modes
        body += u32(0)                     // agent connected
        body += u32(0)                     // agent tokens
        body += u32(0)                     // multimedia time
        body += u32(0)                     // ram hint
        return SpiceWire.message(SpiceWire.Message.mainInit, serial: 1, payload: Data(body))
    }

    private func channelsList(
        withInputs: Bool = false, withCursor: Bool = false,
        withPlayback: Bool = false, withRecord: Bool = false
    ) -> Data {
        var count: UInt32 = 1
        if withInputs { count += 1 }
        if withCursor { count += 1 }
        if withPlayback { count += 1 }
        if withRecord { count += 1 }
        var body = u32(count)
        body += [SpiceWire.Channel.display.rawValue, 0]
        if withInputs { body += [SpiceWire.Channel.inputs.rawValue, 0] }
        if withCursor { body += [SpiceWire.Channel.cursor.rawValue, 0] }
        if withPlayback { body += [SpiceWire.Channel.playback.rawValue, 0] }
        if withRecord { body += [SpiceWire.Channel.record.rawValue, 0] }
        return SpiceWire.message(
            SpiceWire.Message.mainChannelsList, serial: 2, payload: Data(body)
        )
    }

    private func surfaceCreate(_ width: UInt32, _ height: UInt32) -> Data {
        SpiceWire.message(
            SpiceDisplayWire.Message.surfaceCreate.rawValue, serial: 1,
            payload: Data(u32(0) + u32(width) + u32(height) + u32(32) + u32(0))
        )
    }

    private func fill(_ top: Int32, _ left: Int32, _ bottom: Int32, _ right: Int32,
                      colour: UInt32) -> Data {
        var body = u32(0)
        body += i32(top) + i32(left) + i32(bottom) + i32(right)
        body += [0]
        body += [1] + u32(colour)
        body += [0, 0]
        body += [0] + i32(0) + i32(0) + u32(0)
        return SpiceWire.message(
            SpiceDisplayWire.Message.drawFill.rawValue, serial: 2, payload: Data(body)
        )
    }

    /// Hands out one scripted stream per call, in order, and remembers them.
    ///
    /// An actor rather than a lock, because the provider is `async` and Swift 6
    /// refuses `NSLock` there — rightly: a lock held across a suspension is a
    /// deadlock waiting for the right interleaving.
    /// A stream that says what it was given and then simply waits.
    ///
    /// **This exists to remove a race, not to slow a test down.** The display
    /// pump ends the session when its socket runs out, and that closes the event
    /// stream — so a channel still working when the display socket empties has
    /// its events written into a closed continuation and lost. A padded
    /// `MemoryByteStream` only makes that unlikely; under load it still happened,
    /// and the test passed alone while failing in the suite, which is the worst
    /// kind of green.
    ///
    /// Waiting rather than erroring is what a real socket does when the server
    /// has nothing to say. The wait is cancellation-aware, so `stop()` still
    /// ends it.
    private actor EndlessByteStream: ByteStream {
        private var inbound: Data
        private(set) var written = Data()

        init(inbound: Data) { self.inbound = inbound }

        func read(exactly count: Int) async throws -> Data {
            guard count > 0 else { return Data() }
            while inbound.count < count {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let chunk = inbound.prefix(count)
            inbound.removeFirst(count)
            return Data(chunk)
        }

        func write(_ data: Data) async throws { written.append(data) }
        func close() {}
        func drainWritten() -> Data {
            let data = written
            written = Data()
            return data
        }
    }

    private actor Sockets {
        private var queued: [any ByteStream]
        private(set) var handedOut: [any ByteStream] = []

        // `any ByteStream` rather than `MemoryByteStream`, so that a test which
        // needs a socket that waits instead of ending can use one. Only the
        // count is read back from here; a test that wants to inspect bytes holds
        // its own socket.
        init(_ streams: [any ByteStream]) { queued = streams }

        func next() throws -> any ByteStream {
            guard !queued.isEmpty else { throw WisqError.connectionClosed }
            let stream = queued.removeFirst()
            handedOut.append(stream)
            return stream
        }

        var count: Int { handedOut.count }

        nonisolated var provider: SPICESession.StreamProvider {
            { [self] _ in try await next() }
        }
    }

    /// Waits until the session has read `RECORD_START`, rather than assuming it
    /// has. The record channel is linked *after* `.ready` is yielded, so
    /// draining the socket at `.ready` drains nothing.
    private func waitForMicrophone(_ session: SPICESession) async -> Bool {
        for _ in 0..<2_000 {
            if await session.isCapturingMicrophone { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func waitFor(
        _ session: SPICESession, until match: @escaping @Sendable (SessionEvent) -> Bool
    ) async -> SessionEvent? {
        for await event in session.events where match(event) { return event }
        return nil
    }

    // MARK: - The shape

    /// The display channel tells the server it can read LZ4.
    ///
    /// This is permission rather than a request: `dcc_compress_image` checks
    /// `SPICE_DISPLAY_CAP_LZ4_COMPRESSION` and falls through to plain LZ
    /// without it, whatever the server was configured to prefer. Which is why
    /// The channel capabilities a link request actually carried.
    ///
    /// Reading them off the socket rather than off the array they were built
    /// from: a capability is a *bit position*, so a list that reads correctly
    /// can still set the wrong bit, and a set of words computed correctly can
    /// still never be passed to `open`.
    private func advertisedCaps(on socket: MemoryByteStream) async throws -> [UInt32] {
        var reader = SpiceWire.Reader(await socket.written)
        _ = try reader.bytes(SpiceWire.headerBytes)
        _ = try reader.u32()                        // connection ID
        _ = try reader.bytes(2)                     // channel, channel ID
        let commonCount = Int(try reader.u32())
        let channelCount = Int(try reader.u32())
        _ = try reader.u32()                        // where the words start
        for _ in 0..<commonCount { _ = try reader.u32() }
        var caps: [UInt32] = []
        for _ in 0..<channelCount { caps.append(try reader.u32()) }
        return caps
    }

    /// **The main link advertises the agent's token message, and nothing about
    /// migration.**
    ///
    /// `MainChannel::push_agent_connected` picks message 115 (with a token
    /// count) over 107 (empty) by this capability, and a token count is the only
    /// thing that makes the agent writable — `reds_reset_vdp` says a client
    /// learns one "once when the main channel is initialized and once upon
    /// agent's connection with `SPICE_MSG_MAIN_AGENT_CONNECTED_TOKENS`", and
    /// there is no third occasion.
    ///
    /// The migration bits stay clear, and that matters here rather than being a
    /// detail: this capability sits among them and reads like one.
    /// `migrate_connect` uses it only to set `try_seamless`, then still requires
    /// `SEAMLESS_MIGRATE` — bit 3 — before doing anything seamless. So asking
    /// for the token message cannot drag migration in with it, which is what had
    /// to be established before adding the bit.
    func testTheMainLinkAdvertisesTheAgentTokenMessageAndNoMigration() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + mainInit(sessionID: 7) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let sockets = Sockets([mainSocket, displaySocket])
        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: "x"),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        let caps = try await advertisedCaps(on: mainSocket)
        let word = try XCTUnwrap(caps.first, "le lien principal n'annonçait rien")

        func advertises(_ capability: SpiceWire.MainCapability) -> Bool {
            word >> UInt32(capability.rawValue) & 1 == 1
        }
        XCTAssertTrue(
            advertises(.agentConnectedTokens),
            "sans elle le serveur envoie 107, qui ne porte aucun compte de jetons"
        )
        XCTAssertFalse(advertises(.seamlessMigrate), "wisq ne migre pas")
        XCTAssertFalse(advertises(.semiSeamlessMigrate))
        XCTAssertFalse(advertises(.nameAndUUID))
    }

    /// The main channel's own numbering, written out — it is a fourth set of
    /// capability numbers in this protocol, and the one whose middle entry does
    /// not mean what its neighbours suggest.
    func testTheMainCapabilityNumbersAreTheProtocolsOwn() {
        XCTAssertEqual(SpiceWire.MainCapability.semiSeamlessMigrate.rawValue, 0)
        XCTAssertEqual(SpiceWire.MainCapability.nameAndUUID.rawValue, 1)
        XCTAssertEqual(SpiceWire.MainCapability.agentConnectedTokens.rawValue, 2)
        XCTAssertEqual(SpiceWire.MainCapability.seamlessMigrate.rawValue, 3)
        XCTAssertEqual(SpiceWire.mainCapabilityWords, [0b100])
    }

    /// **The audio links advertise volume, and no codec.**
    ///
    /// Asserted on the socket rather than on the constant, because the failure
    /// this guards against is not a wrong list — it is a correct list that
    /// never reaches `open`, which is what both audio channels had.
    ///
    /// Volume, because `snd_send_volume` and `snd_send_mute` open with
    /// `if (!rcc->test_remote_cap(cap)) return false` and send nothing without
    /// it. No codec, because `snd_desired_audio_mode` hands raw PCM to a client
    /// that claims none and Opus to one that claims Opus — and wisq decodes
    /// only the former, so the capability nobody advertises is the one keeping
    /// the sound audible.
    func testTheAudioLinksAdvertiseVolumeAndNoCodec() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + mainInit(sessionID: 7)
                + channelsList(withPlayback: true, withRecord: true)
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let playbackSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let recordSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let sockets = Sockets([mainSocket, displaySocket, playbackSocket, recordSocket])
        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: "x"),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        // `XCTUnwrap` rather than an assertion and then a subscript: a client
        // that advertises nothing gives an empty array, and indexing it would
        // crash the whole runner instead of failing one test — which hides
        // every other result in the suite. Found by sabotage, doing exactly
        // that.
        let playback = try await advertisedCaps(on: playbackSocket)
        let playbackWord = try XCTUnwrap(
            playback.first, "le lien lecture n'annonçait rien du tout"
        )
        XCTAssertEqual(
            playbackWord >> UInt32(SpicePlaybackWire.Capability.volume.rawValue) & 1, 1,
            "sans VOLUME le serveur n'envoie ni volume ni sourdine"
        )
        XCTAssertEqual(
            playbackWord >> UInt32(SpicePlaybackWire.Capability.opus.rawValue) & 1, 0,
            "annoncer Opus rendrait l'audio muet"
        )

        let record = try await advertisedCaps(on: recordSocket)
        let recordWord = try XCTUnwrap(
            record.first, "le lien enregistrement n'annonçait rien du tout"
        )
        XCTAssertEqual(
            recordWord >> UInt32(SpiceRecordWire.Capability.volume.rawValue) & 1, 1
        )
        XCTAssertEqual(
            recordWord >> UInt32(SpiceRecordWire.Capability.opus.rawValue) & 1, 0,
            "wisq n'encode que du PCM"
        )
    }

    /// it is worth asserting on the wire rather than trusting the array
    /// literal — the capability is a *bit position*, so a list that reads
    /// correctly can still set the wrong bit.
    func testTheDisplayLinkAdvertisesLZ4AndPreferredCompression() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + mainInit(sessionID: 7) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply(channelCaps: SpiceDisplayClient.capabilityWords(
                [.preferredCompression]
            )) + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let sockets = Sockets([mainSocket, displaySocket])
        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: "x"),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        var reader = SpiceWire.Reader(await displaySocket.written)
        _ = try reader.bytes(SpiceWire.headerBytes)
        _ = try reader.u32()                        // connection ID
        _ = try reader.bytes(2)                     // channel, channel ID
        let commonCount = Int(try reader.u32())
        let channelCount = Int(try reader.u32())
        _ = try reader.u32()                        // where the words start
        for _ in 0..<commonCount { _ = try reader.u32() }
        var channelCaps: [UInt32] = []
        for _ in 0..<channelCount { channelCaps.append(try reader.u32()) }

        XCTAssertTrue(
            SpiceDisplayClient.supports(.lz4Compression, in: channelCaps),
            "sans cette capacité le serveur n'enverra jamais de LZ4"
        )
        XCTAssertTrue(SpiceDisplayClient.supports(.preferredCompression, in: channelCaps))

        // **Sized frames are dropped by the server without this.**
        // `dcc-send.cpp` works out whether a frame's source area differs from
        // its stream's geometry and, when it does and the client has not
        // advertised `SPICE_DISPLAY_CAP_SIZED_STREAM`, `return FALSE`s rather
        // than sending it — so a region needing a resize simply stops updating.
        //
        // This line used to assert the opposite, with a reason that was true
        // when it was written: wisq did not handle `STREAM_DATA_SIZED` then.
        // It does now, and an advertised capability is a statement about this
        // client rather than a wish list — which cuts both ways.
        XCTAssertTrue(
            SpiceDisplayClient.supports(.sizedStream, in: channelCaps),
            "sans cette capacité le serveur laisse tomber les images redimensionnées"
        )

        // And nothing wisq cannot honour.
        XCTAssertFalse(SpiceDisplayClient.supports(.glScanout, in: channelCaps))

        // **This absence is load-bearing.** `dcc_create_video_encoder` skips
        // every non-MJPEG codec for a client without `MULTI_CODEC` — "Old
        // clients only support MJPEG" is the reference's own comment — and
        // MJPEG is the only codec wisq decodes. Advertising it on the theory
        // that more capability is better would let the server choose VP8 or
        // H.264 and hand this client a frozen rectangle where the motion is.
        XCTAssertFalse(
            SpiceDisplayClient.supports(.multiCodec, in: channelCaps),
            "annoncer multiCodec laisserait le serveur choisir un codec non décodé"
        )
        // Same shape: wisq ignores `STREAM_ACTIVATE_REPORT`, so claiming the
        // capability would promise a conversation it never holds.
        XCTAssertFalse(SpiceDisplayClient.supports(.streamReport, in: channelCaps))
        XCTAssertFalse(SpiceDisplayClient.supports(.composite, in: channelCaps))

        await session.stop()
    }

    /// Two sockets, and the second presents the first's session identifier.
    ///
    /// The identifier is read straight back out of the display channel's link
    /// message, because a client that opens a second connection without it is
    /// not a second channel — it is a second client.
    func testTheDisplayChannelPresentsTheSessionIdentifierFromTheMainChannel() async throws {
        let sessionID: UInt32 = 0xDEAD_BEEF
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: sessionID) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply(channelCaps: SpiceDisplayClient.capabilityWords(
                [.preferredCompression]
            )) + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8) + fill(0, 0, 4, 4, colour: 0x00FF_0000)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: "x"),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        let opened = await sockets.count
        XCTAssertEqual(opened, 2, "un socket par canal")

        // The display link message begins with the connection ID.
        var reader = SpiceWire.Reader(await displaySocket.written)
        _ = try reader.bytes(SpiceWire.headerBytes)
        XCTAssertEqual(try reader.u32(), sessionID, "l'identifiant de session est présenté")
        XCTAssertEqual(try reader.u8(), SpiceWire.Channel.display.rawValue)

        await session.stop()
    }

    /// The first surface is the desktop, and its size is what the UI lays out
    /// against. A session that never says `ready` leaves a blank view.
    func testTheFirstSurfaceBecomesTheDesktopSize() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + surfaceCreate(64, 48) + fill(0, 0, 10, 10, colour: 0x00FF_0000)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "écran", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let ready = await waitFor(session) {
            if case .ready = $0 { return true } else { return false }
        }
        guard case let .ready(name, width, height) = ready else {
            return XCTFail("la session n'a jamais annoncé être prête")
        }
        XCTAssertEqual(width, 64)
        XCTAssertEqual(height, 48)
        XCTAssertEqual(name, "écran")
        XCTAssertEqual(session.framebuffer.size.width, 64)

        await session.stop()
    }

    /// The pixels drawn reach the framebuffer, and only the regions drawn are
    /// reported — a renderer handed the whole screen for a blinking cursor
    /// redraws a phone's display for nothing.
    func testOnlyTheRegionsDrawnAreReportedAndTheirPixelsAreThere() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + surfaceCreate(16, 16) + fill(2, 2, 6, 6, colour: 0x00FF_0000)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let changed = await waitFor(session) {
            if case .framebufferChanged = $0 { return true } else { return false }
        }
        guard case let .framebufferChanged(rects) = changed else {
            return XCTFail("aucune région n'a été signalée")
        }
        XCTAssertEqual(rects, [Rect(x: 2, y: 2, width: 4, height: 4)])

        let snapshot = session.framebuffer.snapshot()
        let at = (2 * 16 + 2) * 4
        XCTAssertEqual(Array(snapshot.pixels[at..<(at + 4)]), [0, 0, 0xFF, 0], "le rouge peint")
        XCTAssertEqual(Array(snapshot.pixels[0..<4]), [0, 0, 0, 0], "hors région, intact")

        await session.stop()
    }

    /// **The GLZ window lives as long as the connection**, which is what makes
    /// GLZ decodable at all: image 1 refers back to image 0.
    ///
    /// `run()` pumps one message at a time, so two GLZ images are two pump
    /// calls. A window rebuilt between them leaves the second image undrawn —
    /// and this test exists because that mistake is invisible everywhere else:
    /// every codec test still passes, and the screen is simply missing an
    /// update.
    func testTheGLZWindowSurvivesAcrossTheConnection() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        var inbound = linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(16, 16)
        for fixture in SpiceGLZFixtures.sequence.prefix(2) {
            inbound += glzCopy(fixture)
        }
        let sockets = Sockets([mainSocket, MemoryByteStream(inbound: inbound)])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) {
            if case .framebufferChanged = $0 { return true } else { return false }
        }

        // Pixel 48 — row 3, column 0 — and not the top-left one, which is the
        // trap this test fell into first: both images decode to zero there and
        // so does an untouched framebuffer, so asserting on it is a test that
        // passes while checking nothing. Pixel 48 is inside image 1's noise
        // band: it differs from image 0 *and* from zero.
        let first = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[0].decoded)
        let second = SpiceGLZFixtures.bytes(SpiceGLZFixtures.sequence[1].decoded)
        let at = 48 * 4
        XCTAssertNotEqual(
            Array(second[at..<(at + 3)]), Array(first[at..<(at + 3)]),
            "le gabarit doit distinguer les deux images à ce pixel"
        )
        XCTAssertNotEqual(
            Array(second[at..<(at + 3)]), [0, 0, 0],
            "et le distinguer d'un framebuffer intact"
        )

        var painted = false
        for _ in 0..<50 where !painted {
            let snapshot = session.framebuffer.snapshot()
            painted = Array(snapshot.pixels[at..<(at + 3)]) == Array(second[at..<(at + 3)])
            if !painted { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(
            painted,
            "l'image 1 renvoie à l'image 0 : sans fenêtre conservée, elle n'est jamais dessinée"
        )

        await session.stop()
    }

    private func glzCopy(_ fixture: SpiceGLZFixtures.Case) -> Data {
        let payload = SpiceGLZFixtures.bytes(fixture.stream)
        var body = u32(0)
        body += i32(0) + i32(0) + i32(12) + i32(16)      // box: top, left, bottom, right
        body += [0]
        let imageOffset = UInt32(body.count + 4 + 16 + 2 + 1 + 13)
        body += u32(imageOffset)
        body += i32(0) + i32(0) + i32(12) + i32(16)      // src_area
        body += [0, 0] + [0]
        body += [0] + i32(0) + i32(0) + u32(0)
        body += u32(UInt32(fixture.id)) + u32(0)
        body += [UInt8(SpiceDisplayWire.ImageType.glzRGB.rawValue), 0]
        body += u32(16) + u32(12)
        body += u32(UInt32(payload.count)) + payload
        return SpiceWire.message(
            SpiceDisplayWire.Message.drawCopy.rawValue, serial: 2, payload: Data(body)
        )
    }

    /// A server offering no display channel is a session that cannot show
    /// anything, and it says so rather than waiting.
    func testAServerWithNoDisplayChannelFailsRatherThanHanging() async throws {
        var body = u32(1)
        body += [SpiceWire.Channel.inputs.rawValue, 0]
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + mainInit(sessionID: 1)
                + SpiceWire.message(
                    SpiceWire.Message.mainChannelsList, serial: 2, payload: Data(body)
                )
        )
        let sockets = Sockets([mainSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let ended = await waitFor(session) {
            if case .disconnected = $0 { return true } else { return false }
        }
        guard case let .disconnected(error) = ended else {
            return XCTFail("la session devait se terminer")
        }
        XCTAssertNotNil(error)
        let opened = await sockets.count
        XCTAssertEqual(opened, 1, "aucun second socket n'a été ouvert")
    }

    /// The factory hands the app a SPICE session now, where it used to throw.
    func testTheFactoryBuildsASpiceSessionRatherThanRefusing() throws {
        let machine = Machine(name: "m", host: "h", port: 5900, proto: .spice)
        let session = try SessionFactory.makeSession(
            machine: machine, credentials: EphemeralCredentialStore()
        )
        XCTAssertTrue(session is ReconnectingSession)
    }
    // MARK: - Input

    /// Input goes down a third connection of its own, presenting the same
    /// session identifier. Sending keystrokes on the display socket would be a
    /// protocol error dressed up as a shortcut.
    /// **The microphone reaches the guest through the real path.**
    ///
    /// The encoder is exercised by the session rather than called directly, so
    /// that "nothing calls it" cannot be true of it. What is missing here is
    /// only the platform's microphone: everything between the samples and the
    /// socket is checked.
    ///
    /// Three messages go out for the first packet — the codec, the start mark,
    /// then the samples — and one for every packet after it.
    func testTheMicrophoneReachesTheGuestThroughTheSession() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 4) + channelsList(withRecord: true)
        )
        let displaySocket = EndlessByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        // Le serveur demande du mono 16 kHz.
        let start = SpiceWire.message(
            SpiceRecordWire.ServerMessage.start.rawValue, serial: 1,
            payload: Data(u32(1) + [1, 0] + u32(16_000))
        )
        let recordSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + start
        )
        let sockets = Sockets([mainSocket, displaySocket, recordSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        let asked = await waitForMicrophone(session)
        XCTAssertTrue(asked, "le serveur n'a jamais demandé le micro")
        _ = await recordSocket.drainWritten()          // le message de lien

        await session.sendMicrophone(samples: [0x0102, -1], time: 5)
        let first = await recordSocket.drainWritten()
        var reader = SpiceWire.Reader(first)

        var header = try SpiceWire.decodeDataHeader(
            Data(try reader.bytes(SpiceWire.dataHeaderBytes))
        )
        XCTAssertEqual(header.type, SpiceRecordWire.ClientMessage.mode.rawValue,
                       "le codec s'annonce avant les échantillons")
        XCTAssertEqual(try reader.bytes(Int(header.size)), u32(5) + u16(1),
                       "le mode annoncé est raw")

        header = try SpiceWire.decodeDataHeader(
            Data(try reader.bytes(SpiceWire.dataHeaderBytes))
        )
        XCTAssertEqual(header.type, SpiceRecordWire.ClientMessage.startMark.rawValue)
        XCTAssertEqual(try reader.bytes(Int(header.size)), u32(5))

        header = try SpiceWire.decodeDataHeader(
            Data(try reader.bytes(SpiceWire.dataHeaderBytes))
        )
        XCTAssertEqual(header.type, SpiceRecordWire.ClientMessage.data.rawValue)
        XCTAssertEqual(try reader.bytes(Int(header.size)),
                       u32(5) + [0x02, 0x01] + [0xFF, 0xFF],
                       "petit-boutiste, comme la lecture les lit")

        // Le second paquet ne réannonce rien.
        await session.sendMicrophone(samples: [7], time: 15)
        let second = await recordSocket.drainWritten()
        var again = SpiceWire.Reader(second)
        header = try SpiceWire.decodeDataHeader(
            Data(try again.bytes(SpiceWire.dataHeaderBytes))
        )
        XCTAssertEqual(header.type, SpiceRecordWire.ClientMessage.data.rawValue)
        XCTAssertEqual(second.count, SpiceWire.dataHeaderBytes + 6,
                       "un seul message pour un paquet suivant")

        await session.stop()
    }

    /// **Nothing goes out before the guest asks for it.**
    ///
    /// A client that starts sending samples at a server that never requested a
    /// microphone is a client sending a room's audio somewhere nobody asked it
    /// to. The channel exists, the stream does not.
    func testNoSamplesGoOutBeforeTheGuestAsksForThem() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 4) + channelsList(withRecord: true)
        )
        let displaySocket = EndlessByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        // Pas de RECORD_START : le serveur ne demande rien.
        let recordSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let sockets = Sockets([mainSocket, displaySocket, recordSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }
        // Le canal est lié même sans flux : ce qui doit rester vide, c'est ce
        // qui suit le message de lien.
        _ = await recordSocket.drainWritten()

        await session.sendMicrophone(samples: [1, 2, 3], time: 0)
        let written = await recordSocket.written
        XCTAssertTrue(written.isEmpty, "rien ne sort tant que le serveur n'a pas demandé")

        await session.stop()
    }

    /// **Sound reaches the UI from the wire.**
    ///
    /// A decoder nothing calls is a decoder that does not exist — `lzPalette`
    /// showed that once and two later draws had the same gap survive a
    /// sabotage. So the channel is not merely opened here: a `START` and a
    /// `DATA` go down the socket, and the samples come back out of the session's
    /// event stream.
    func testSoundGoesFromThePlaybackSocketToTheEventStream() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 9) + channelsList(withPlayback: true)
        )
        // Le faux serveur d'affichage attend au lieu de finir : quand sa socket
        // s'épuise, la pompe display termine la session et ferme le flux
        // d'événements, et une trame audio produite après disparaît.
        let displaySocket = EndlessByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        // Deux canaux, S16, 48 kHz, puis une trame stéréo : 0x0102 et 0x0304.
        let start = SpiceWire.message(
            SpicePlaybackWire.Message.start.rawValue, serial: 1,
            payload: Data(u32(2) + [1, 0] + u32(48_000) + u32(0))
        )
        let data = SpiceWire.message(
            SpicePlaybackWire.Message.data.rawValue, serial: 2,
            payload: Data(u32(11) + [0x02, 0x01, 0x04, 0x03])
        )
        let playbackSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + start + data
        )
        let sockets = Sockets([mainSocket, displaySocket, playbackSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        // Une seule itération du flux : `AsyncStream` n'en supporte qu'une, et
        // un second `for await` sur le même flux ne rend rien. C'est ce qui a
        // fait échouer la première version de ce test alors que le canal
        // fonctionnait — la panne était dans le test.
        let heard = await waitFor(session) {
            if case .audio = $0 { return true } else { return false }
        }
        guard case let .audio(frames)? = heard else {
            XCTFail("aucune trame audio n'est sortie de la session")
            await session.stop()
            return
        }
        XCTAssertEqual(frames.samples, [0x0102, 0x0304])
        XCTAssertEqual(frames.channels, 2)
        XCTAssertEqual(frames.frequency, 48_000)
        XCTAssertEqual(frames.time, 11, "l'horloge du serveur est conservée")

        var reader = SpiceWire.Reader(await playbackSocket.written)
        _ = try reader.bytes(SpiceWire.headerBytes)
        XCTAssertEqual(try reader.u32(), 9)
        XCTAssertEqual(try reader.u8(), SpiceWire.Channel.playback.rawValue)

        await session.stop()
    }

    /// A server with no playback channel opens no socket for it, and the
    /// session is a session all the same.
    func testAServerWithNoSoundOpensNoSocketForIt() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        let opened = await sockets.count
        XCTAssertEqual(opened, 2, "aucune connexion ouverte pour un canal non offert")

        await session.stop()
    }

    func testInputOpensAThirdConnectionAndPresentsTheSessionIdentifier() async throws {
        let sessionID: UInt32 = 0x1234
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: sessionID) + channelsList(withInputs: true)
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let inputSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let sockets = Sockets([mainSocket, displaySocket, inputSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        let opened = await sockets.count
        XCTAssertEqual(opened, 3, "un socket par canal, entrées comprises")

        var reader = SpiceWire.Reader(await inputSocket.written)
        _ = try reader.bytes(SpiceWire.headerBytes)
        XCTAssertEqual(try reader.u32(), sessionID)
        XCTAssertEqual(try reader.u8(), SpiceWire.Channel.inputs.rawValue)

        await session.stop()
    }

    /// A key press reaches the inputs socket and nothing else.
    func testAKeyPressGoesDownTheInputsSocketAndNotTheDisplayOne() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList(withInputs: true)
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let inputSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let sockets = Sockets([mainSocket, displaySocket, inputSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }

        let beforeDisplay = await displaySocket.written.count
        _ = await inputSocket.drainWritten()          // the link message
        await session.send(.key(keysym: 0x0061, down: true))   // "a"

        let sent = await inputSocket.written
        XCTAssertFalse(sent.isEmpty, "la frappe doit partir")
        let header = try SpiceWire.decodeDataHeader(sent)
        XCTAssertEqual(header.type, SpiceInputs.ClientMessage.keyDown)

        let afterDisplay = await displaySocket.written.count
        XCTAssertEqual(afterDisplay, beforeDisplay, "rien n'est parti sur le socket display")

        await session.stop()
    }

    /// A server offering no inputs channel still gives a usable session: the
    /// screen is worth having without the keyboard, and refusing to start would
    /// trade something for nothing.
    func testAServerWithNoInputsChannelStillShowsTheScreen() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(32, 24)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let ready = await waitFor(session) {
            if case .ready = $0 { return true } else { return false }
        }
        guard case let .ready(_, width, _) = ready else {
            return XCTFail("la session devait être prête sans canal d'entrées")
        }
        XCTAssertEqual(width, 32)

        // And sending input is a no-op rather than a crash or a stray write.
        await session.send(.key(keysym: 0x0061, down: true))
        let opened = await sockets.count
        XCTAssertEqual(opened, 2)

        await session.stop()
    }

    /// The inputs channel keeps its own serial. One shared counter across two
    /// connections gives each of them a sequence full of holes.
    func testTheInputsChannelCountsItsOwnSerials() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList(withInputs: true)
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        )
        let inputSocket = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        let sockets = Sockets([mainSocket, displaySocket, inputSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()
        _ = await waitFor(session) { if case .ready = $0 { return true } else { return false } }
        _ = await inputSocket.drainWritten()

        await session.send(.key(keysym: 0x0061, down: true))
        await session.send(.key(keysym: 0x0061, down: false))

        var reader = SpiceWire.Reader(await inputSocket.written)
        let first = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))
        _ = try reader.bytes(Int(first.size))
        let second = try SpiceWire.decodeDataHeader(Data(try reader.bytes(18)))

        XCTAssertEqual(first.serial, 1, "la suite du canal d'entrées part de 1")
        XCTAssertEqual(second.serial, 2, "et n'a pas de trou")
        XCTAssertEqual(first.type, SpiceInputs.ClientMessage.keyDown)
        XCTAssertEqual(second.type, SpiceInputs.ClientMessage.keyUp)

        await session.stop()
    }
    // MARK: - The pointer

    /// A cursor image on its own connection reaches the UI.
    ///
    /// Its own socket so the pointer keeps moving while the display channel is
    /// sending a screenful of pixels — on a phone that is a cursor that follows
    /// the finger rather than one that lags a repaint.
    func testACursorImageArrivesOnItsOwnConnection() async throws {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u64v(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * $0) & 0xFF) } }

        var cursorBody = u16(10) + u16(20)          // position
        cursorBody += [1]                            // visible
        cursorBody += u16(0)                         // flags: none set
        cursorBody += u64v(1)                        // unique
        cursorBody += [0]                            // ALPHA
        cursorBody += u16(2) + u16(2)                // 2x2
        cursorBody += u16(1) + u16(1)                // hotspot
        cursorBody += (0..<16).map { UInt8($0) }     // pixels

        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 9) + channelsList(withCursor: true)
        )
        // The display socket is given a long tail of pings. Without it, its
        // pump runs the stream dry, the session ends, and the event stream
        // closes before the cursor task has read its one message — the cursor
        // would lose a race it does not lose against a real socket, which
        // blocks rather than reporting the end of the world.
        var displayInbound = linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        for serial in 0..<200 {
            displayInbound += SpiceWire.message(
                SpiceWire.Message.ping, serial: UInt64(serial), payload: Data([0])
            )
        }
        let displaySocket = MemoryByteStream(inbound: displayInbound)
        let cursorSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + SpiceWire.message(
                    SpiceCursorWire.Message.set.rawValue, serial: 1, payload: Data(cursorBody)
                )
        )
        let sockets = Sockets([mainSocket, displaySocket, cursorSocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let seen = await waitFor(session) {
            if case .cursor = $0 { return true } else { return false }
        }
        guard case let .cursor(pointer) = seen else {
            return XCTFail("aucun curseur n'est arrivé")
        }
        XCTAssertEqual(pointer.width, 2)
        XCTAssertEqual(pointer.hotspotX, 1)
        XCTAssertEqual(pointer.bgra.count, 16)

        let opened = await sockets.count
        XCTAssertEqual(opened, 3, "display, curseur, et le principal")

        await session.stop()
    }

    /// A server offering no cursor channel still gives a working session. The
    /// system pointer is a perfectly good fallback; a black screen is not.
    func testAServerWithNoCursorChannelStillShowsTheScreen() async throws {
        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList()
        )
        let displaySocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(20, 10)
        )
        let sockets = Sockets([mainSocket, displaySocket])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let ready = await waitFor(session) {
            if case .ready = $0 { return true } else { return false }
        }
        guard case let .ready(_, width, _) = ready else {
            return XCTFail("la session devait être prête sans canal curseur")
        }
        XCTAssertEqual(width, 20)
        await session.stop()
    }
    /// A cursor the server names from a cache this client does not keep must
    /// not reach the UI as an empty one.
    ///
    /// An empty cursor means "hide the pointer", which is the opposite of what
    /// the server asked for. This test exists because a sabotage found it
    /// missing: forwarding the absence as an empty cursor passed everything.
    func testACursorNamedFromACacheIsNotForwardedAsAnEmptyOne() async throws {
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u64v(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (8 * $0) & 0xFF) } }

        var cached = u16(5) + u16(5)                       // position
        cached += [1]                                       // visible
        cached += u16(1 << 2)                               // FROM_CACHE
        cached += u64v(77) + [0] + u16(2) + u16(2) + u16(0) + u16(0)

        // A real cursor after it, so the test can tell "nothing yet" from
        // "nothing ever": the first must be skipped and the second must arrive.
        var real = u16(6) + u16(6) + [1]
        real += u16(0) + u64v(1) + [0] + u16(2) + u16(2) + u16(1) + u16(1)
        real += (0..<16).map { UInt8($0) }

        let mainSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + mainInit(sessionID: 1) + channelsList(withCursor: true)
        )
        var displayInbound = linkReply() + Data(SpiceWire.u32(0)) + surfaceCreate(8, 8)
        for serial in 0..<200 {
            displayInbound += SpiceWire.message(
                SpiceWire.Message.ping, serial: UInt64(serial), payload: Data([0])
            )
        }
        let cursorSocket = MemoryByteStream(
            inbound: linkReply() + Data(SpiceWire.u32(0))
                + SpiceWire.message(
                    SpiceCursorWire.Message.set.rawValue, serial: 1, payload: Data(cached)
                )
                + SpiceWire.message(
                    SpiceCursorWire.Message.set.rawValue, serial: 2, payload: Data(real)
                )
        )
        let sockets = Sockets([
            mainSocket, MemoryByteStream(inbound: displayInbound), cursorSocket,
        ])

        let session = SPICESession(
            configuration: SessionConfiguration(host: "h", port: 5900, password: ""),
            streamProvider: sockets.provider,
            encryptTicket: ticket
        )
        await session.start()

        let seen = await waitFor(session) {
            if case .cursor = $0 { return true } else { return false }
        }
        guard case let .cursor(pointer) = seen else {
            return XCTFail("le vrai curseur devait arriver")
        }
        // The first event to arrive must be the real cursor, not an empty one
        // standing in for the cached message.
        XCTAssertEqual(pointer.width, 2)
        XCTAssertFalse(pointer.isEmpty, "le message « depuis le cache » ne doit rien émettre")

        await session.stop()
    }
}
