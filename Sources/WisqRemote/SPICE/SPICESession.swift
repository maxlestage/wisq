import Foundation
import WisqCore
import WisqNet

/// SPICE, connected.
///
/// The pieces were all here and none of them was reachable from the app: the
/// link, the main channel, the display channel, the surfaces, the LZ decoder.
/// This is the actor that opens the sockets and joins them, and it is the first
/// point at which `SessionFactory` can hand the UI a SPICE session that shows
/// something rather than one that reports the protocol unsupported.
///
/// The shape that makes SPICE different from RFB next door: **one TCP
/// connection per channel.** The main channel is opened first because it is the
/// only one that knows the session identifier, and every channel after it must
/// present that identifier as its connection ID or the server treats it as a
/// separate, unrelated client. So the stream provider is called more than once,
/// and the order is not an implementation detail.
public actor SPICESession: RemoteSession {
    /// One call per channel, unlike the VNC backend's single connection.
    public typealias StreamProvider =
        @Sendable (SessionConfiguration) async throws -> any ByteStream

    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let framebuffer: Framebuffer

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration
    private let makeStream: StreamProvider
    private let encryptTicket: SpiceTicketEncryptor

    private var main: (any ByteStream)?
    private var display: (any ByteStream)?
    private var inputs: (any ByteStream)?
    private var cursor: (any ByteStream)?
    private var pump: Task<Void, Never>?
    private var cursorPump: Task<Void, Never>?
    private var playback: (any ByteStream)?
    private var playbackPump: Task<Void, Never>?
    private var record: (any ByteStream)?
    private var recordPump: Task<Void, Never>?
    private var recording = SpiceRecord()
    private var recordSerial: UInt64 = 1
    private var mainPump: Task<Void, Never>?

    /// The main channel's agent, which owns its own state.
    ///
    /// The opposite of the display channel's surfaces, and for a reason: the
    /// clipboard is written from `send(_:)` as well as read from the pump, so
    /// it cannot live inside the loop. An actor of its own is what lets both
    /// reach it without either copying state back over the other's.
    private var agent: SpiceAgentChannel?
    /// Serial for the inputs channel, counted apart from the display's.
    ///
    /// Each channel is its own connection with its own message sequence, so one
    /// shared counter would give both of them a sequence full of holes — and a
    /// server that acknowledges by serial would be right to complain about it.
    private var inputSerial: UInt64 = 1

    public init(
        configuration: SessionConfiguration,
        framebuffer: Framebuffer? = nil,
        streamProvider: StreamProvider? = nil,
        encryptTicket: SpiceTicketEncryptor? = nil
    ) {
        self.configuration = configuration
        self.framebuffer = framebuffer ?? Framebuffer(width: 0, height: 0)
        self.makeStream = streamProvider ?? SPICESession.defaultStreamProvider
        self.encryptTicket = encryptTicket ?? SpiceTicket.platform
        var escapee: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escapee = $0 }
        self.continuation = escapee
    }

    public func start() async {
        continuation.yield(.connecting)
        do {
            try await connect()
        } catch {
            finish(with: error)
        }
    }

    public func stop() async {
        pump?.cancel()
        cursorPump?.cancel()
        playbackPump?.cancel()
        recordPump?.cancel()
        mainPump?.cancel()
        pump = nil
        cursorPump = nil
        playbackPump = nil
        recordPump = nil
        mainPump = nil
        agent = nil
        await main?.close()
        await display?.close()
        await inputs?.close()
        await cursor?.close()
        await playback?.close()
        await record?.close()
        main = nil
        display = nil
        inputs = nil
        cursor = nil
        playback = nil
        record = nil
        continuation.yield(.disconnected(nil))
        continuation.finish()
    }

    /// Sends one input event on the inputs channel.
    ///
    /// Silently does nothing before the channel is up, which is deliberate: a
    /// tap that lands during the handshake has nowhere to go, and queueing it
    /// would replay it into a desktop that has since drawn something else under
    /// the finger.
    ///
    /// One event is not always one message — a wheel notch is a press and a
    /// release, because SPICE has no way to say "scrolled" and sending only the
    /// press leaves the guest believing a button is held.
    public func send(_ event: InputEvent) async {
        // The clipboard is the guest's, so it goes to the program running
        // inside the guest rather than to the virtual hardware — a different
        // channel entirely from every other event here.
        if case .clipboard(let text) = event {
            await offerClipboard(text)
            return
        }
        guard let inputs else { return }
        for message in SpiceInputs.messages(for: event) {
            do {
                try await inputs.write(SpiceWire.message(
                    message.type, serial: inputSerial, payload: message.payload
                ))
                inputSerial += 1
            } catch {
                // A failed write means the connection is gone; the pump on the
                // display channel will notice and end the session. Reporting it
                // here as well would disconnect twice for one cause.
                return
            }
        }
    }

    /// SPICE resizes through the agent in the guest rather than through the
    /// display channel, so there is nothing honest to do here yet. Saying so
    /// beats a body that looks like it works.
    public func setPreferredSize(width: Int, height: Int) async {}

    // MARK: - Bringing it up

    private func connect() async throws {
        let password = configuration.password ?? ""

        // The main channel first, because it is the only one that learns the
        // session identifier every other channel has to present.
        let mainStream = try await makeStream(configuration)
        main = mainStream
        continuation.yield(.authenticating)
        _ = try await SpiceLink(stream: mainStream, encryptTicket: encryptTicket)
            .open(
                channel: .main, password: password,
                channelCaps: SpiceWire.mainCapabilityWords
            )

        let session = try await SpiceMainChannel(stream: mainStream).bringUp()
        guard session.channels.contains(where: { $0.type == SpiceWire.Channel.display.rawValue })
        else {
            throw SpiceError.noChannelList
        }

        // A second connection, presenting the session identifier as its
        // connection ID. Without it the server sees an unrelated client and
        // gives it a display of its own, which is a black screen that looks
        // like a bug in the decoder.
        let displayStream = try await makeStream(configuration)
        display = displayStream
        let link = try await SpiceLink(stream: displayStream, encryptTicket: encryptTicket)
            .open(
                channel: .display,
                connectionID: session.initialisation.sessionID,
                password: password,
                // `lz4Compression` is not a request; it is permission. The
                // server checks it before it will send an LZ4 image at all
                // (`dcc_compress_image` falls through to plain LZ without it),
                // and what it sends is decided separately by its own
                // configuration or by the preference message below. So this
                // matters exactly where the preference does not reach: a
                // server without `preferredCompression`, and the images that
                // go out before ours arrives.
                // **`sizedStream` is not optional politeness — without it the
                // server silently drops frames.** `dcc-send.cpp` computes
                // whether a frame's source area differs from the stream's
                // geometry and, if it does and the client has not advertised
                // `SPICE_DISPLAY_CAP_SIZED_STREAM`, `return FALSE`s out of
                // sending it at all. A region that needs a resize therefore
                // just stops updating. wisq handles `STREAM_DATA_SIZED`, so it
                // has to say so.
                //
                // **`multiCodec` is deliberately absent, and that absence is
                // load-bearing.** `dcc_create_video_encoder` skips every
                // non-MJPEG codec for a client without it — "Old clients only
                // support MJPEG" is the comment — and MJPEG is the only codec
                // wisq decodes. Adding it on the theory that more capability is
                // better would let the server pick VP8 or H.264 and hand this
                // client a frozen rectangle where the motion is.
                //
                // `streamReport` is absent for the same kind of reason: wisq
                // ignores `STREAM_ACTIVATE_REPORT`, so claiming it would promise
                // a bitrate conversation this client never holds.
                channelCaps: SpiceDisplayClient.capabilityWords(
                    [.sizedStream, .preferredCompression, .lz4Compression]
                )
            )

        let channel = SpiceDisplayChannel(stream: displayStream)
        let serial = try await channel.announce(serverCapabilities: link.channelCaps)

        // A third connection, for input, and only if the server offered the
        // channel. Best effort on purpose: a session that shows the screen but
        // takes no keystrokes is worth having, and one that refuses to start
        // because the inputs channel would not open is not.
        if session.channels.contains(where: { $0.type == SpiceWire.Channel.inputs.rawValue }) {
            do {
                let inputStream = try await makeStream(configuration)
                _ = try await SpiceLink(stream: inputStream, encryptTicket: encryptTicket)
                    .open(
                        channel: .inputs,
                        connectionID: session.initialisation.sessionID,
                        password: password
                    )
                inputs = inputStream
            } catch {
                inputs = nil
            }
        }

        pump = Task { [weak self] in
            await self?.run(channel, from: serial)
        }

        // The main channel, kept running. Nothing read it after the handshake,
        // so the server's pings went unanswered into a socket buffer that
        // filled quietly — and it is where the clipboard arrives.
        //
        // The serial continues from where `bringUp` left off: it is one
        // sequence on one connection, and restarting at 1 would hand a server
        // that acknowledges by serial a sequence that goes backwards.
        let agentChannel = SpiceAgentChannel(
            stream: mainStream,
            connected: session.initialisation.agentConnected,
            tokens: session.initialisation.agentTokens,
            serial: session.nextSerial
        )
        agent = agentChannel
        if session.initialisation.agentConnected {
            try? await agentChannel.start()
        }
        mainPump = Task { [weak self] in
            await self?.followMain(agentChannel)
        }

        // The pointer gets a connection of its own so it keeps moving while the
        // display channel is sending a screenful of pixels. On a phone that is
        // the difference between a cursor that follows the finger and one that
        // lags a repaint. Best effort, like input.
        if session.channels.contains(where: { $0.type == SpiceWire.Channel.cursor.rawValue }) {
            do {
                let cursorStream = try await makeStream(configuration)
                _ = try await SpiceLink(stream: cursorStream, encryptTicket: encryptTicket)
                    .open(
                        channel: .cursor,
                        connectionID: session.initialisation.sessionID,
                        password: password
                    )
                cursor = cursorStream
                cursorPump = Task { [weak self] in
                    await self?.followCursor(on: cursorStream)
                }
            } catch {
                cursor = nil
            }
        }

        // Sound, on a connection of its own for the same reason the pointer has
        // one: audio that waits behind a screenful of pixels arrives late, and
        // late audio is worse than none. Best effort — a session with no sound
        // is a session, and a server may not offer the channel at all.
        if session.channels.contains(where: { $0.type == SpiceWire.Channel.playback.rawValue }) {
            do {
                let playbackStream = try await makeStream(configuration)
                _ = try await SpiceLink(stream: playbackStream, encryptTicket: encryptTicket)
                    .open(
                        channel: .playback,
                        connectionID: session.initialisation.sessionID,
                        password: password,
                        channelCaps: SpicePlaybackWire.capabilityWords(
                            SpicePlaybackWire.advertised
                        )
                    )
                playback = playbackStream
                playbackPump = Task { [weak self] in
                    await self?.followPlayback(on: playbackStream)
                }
            } catch {
                playback = nil
            }
        }

        // The microphone, if the guest wants one. Its own connection again:
        // captured samples are on a deadline, and a queue shared with pixels is
        // not a deadline anyone can keep.
        if session.channels.contains(where: { $0.type == SpiceWire.Channel.record.rawValue }) {
            do {
                let recordStream = try await makeStream(configuration)
                _ = try await SpiceLink(stream: recordStream, encryptTicket: encryptTicket)
                    .open(
                        channel: .record,
                        connectionID: session.initialisation.sessionID,
                        password: password,
                        channelCaps: SpiceRecordWire.capabilityWords(
                            SpiceRecordWire.advertised
                        )
                    )
                record = recordStream
                recordPump = Task { [weak self] in
                    await self?.followRecord(on: recordStream)
                }
            } catch {
                record = nil
            }
        }
    }

    /// Reads the record channel: what the guest wants captured, and whether it
    /// currently wants anything at all.
    private func followRecord(on stream: any ByteStream) async {
        var serial: UInt64 = 1
        while !Task.isCancelled {
            do {
                let header = try SpiceWire.decodeDataHeader(
                    try await stream.read(exactly: SpiceWire.dataHeaderBytes)
                )
                guard header.size <= 1 << 22 else { return }
                let payload = header.size == 0
                    ? Data() : try await stream.read(exactly: Int(header.size))

                switch header.type {
                case SpiceWire.Message.ping:
                    try await stream.write(SpiceWire.message(
                        SpiceWire.ClientMessage.pong, serial: serial, payload: payload
                    ))
                    serial += 1
                case SpiceRecordWire.ServerMessage.start.rawValue:
                    recording.start(try SpiceRecordWire.start([UInt8](payload)))
                case SpiceRecordWire.ServerMessage.stop.rawValue:
                    recording.stop()
                case SpiceRecordWire.ServerMessage.mute.rawValue:
                    recording.setMuted(try SpiceRecordWire.mute([UInt8](payload)))
                case SpiceRecordWire.ServerMessage.volume.rawValue:
                    recording.setVolume(try SpiceRecordWire.volume([UInt8](payload)))
                default:
                    continue
                }
            } catch {
                return
            }
        }
    }

    /// Hands captured samples to the guest.
    ///
    /// Called by whatever is holding the microphone — on Apple that is
    /// AVAudioEngine, which is why this takes samples rather than opening a
    /// device itself. Everything that decides *whether* to send, and what has to
    /// go in front of the samples, is here where a test can drive it.
    ///
    /// **The codec is announced before the first packet of every stream**, and
    /// `START_MARK` says where the samples begin. A server that never hears the
    /// mode reads PCM as whatever it assumed last.
    ///
    /// Silence is not sent while muted: zeroed samples would keep the guest's
    /// recorder running and its file growing, which is the opposite of what
    /// muting a microphone asks for.
    /// Whether the guest has asked for a microphone and has not muted it.
    ///
    /// Not `public`: the app has no use for it, and it exists so a test can wait
    /// for `RECORD_START` to have been read rather than guess at how long that
    /// takes. Guessing is what made an earlier test pass alone and fail in a
    /// suite.
    var isCapturingMicrophone: Bool { recording.isCapturing }

    public func sendMicrophone(samples: [Int16], time: UInt32) async {
        guard let record, recording.isCapturing, !samples.isEmpty else { return }
        do {
            if !recording.hasAnnouncedMode {
                try await write(
                    SpiceRecordWire.ClientMessage.mode.rawValue,
                    SpiceRecordWire.modeMessage(time: time), to: record
                )
                try await write(
                    SpiceRecordWire.ClientMessage.startMark.rawValue,
                    SpiceRecordWire.startMarkMessage(time: time), to: record
                )
                recording.announcedMode()
            }
            try await write(
                SpiceRecordWire.ClientMessage.data.rawValue,
                SpiceRecordWire.dataMessage(time: time, samples: samples), to: record
            )
        } catch {
            // A microphone that cannot reach the guest is a microphone that does
            // not work, not a session that has ended. The display channel is
            // what decides whether the session is alive.
            self.record = nil
        }
    }

    private func write(_ type: UInt16, _ payload: Data, to stream: any ByteStream) async throws {
        try await stream.write(
            SpiceWire.message(type, serial: recordSerial, payload: payload)
        )
        recordSerial += 1
    }

    /// Reads the playback channel and hands frames to whoever is listening.
    ///
    /// Failures here end this task and nothing else, like the cursor's: losing
    /// sound is losing sound, and tearing down a working screen for it would be
    /// the wrong trade.
    private func followPlayback(on stream: any ByteStream) async {
        var state = SpicePlayback()
        var serial: UInt64 = 1
        while !Task.isCancelled {
            do {
                let header = try SpiceWire.decodeDataHeader(
                    try await stream.read(exactly: SpiceWire.dataHeaderBytes)
                )
                guard header.size <= 1 << 22 else { return }
                let payload = header.size == 0
                    ? Data() : try await stream.read(exactly: Int(header.size))

                switch header.type {
                case SpiceWire.Message.ping:
                    try await stream.write(SpiceWire.message(
                        SpiceWire.ClientMessage.pong, serial: serial, payload: payload
                    ))
                    serial += 1
                case SpicePlaybackWire.Message.start.rawValue:
                    state.start(try SpicePlaybackWire.start([UInt8](payload)))
                case SpicePlaybackWire.Message.stop.rawValue:
                    state.stop()
                case SpicePlaybackWire.Message.mode.rawValue:
                    // A mode change carries its own first packet, so the samples
                    // in it are played rather than dropped.
                    let change = try SpicePlaybackWire.modeChange([UInt8](payload))
                    state.setMode(change.mode)
                    publish(state.frames(from: SpicePlaybackWire.Packet(
                        time: change.time, data: change.data
                    )))
                case SpicePlaybackWire.Message.data.rawValue:
                    publish(state.frames(from: try SpicePlaybackWire.packet([UInt8](payload))))
                case SpicePlaybackWire.Message.mute.rawValue:
                    state.setMuted(try SpicePlaybackWire.mute([UInt8](payload)))
                case SpicePlaybackWire.Message.volume.rawValue:
                    state.setVolume(try SpicePlaybackWire.volume([UInt8](payload)).levels)
                case SpicePlaybackWire.Message.latency.rawValue:
                    state.setLatency(try SpicePlaybackWire.latency([UInt8](payload)))
                default:
                    continue
                }
            } catch {
                return
            }
        }
    }

    /// Only frames with something in them reach the UI. A packet that decoded to
    /// nothing — muted, a codec with no decoder, no whole frame — is silence,
    /// and silence is not an event worth waking a renderer for.
    private func publish(_ frames: SpicePlayback.Frames?) {
        guard let frames, !frames.samples.isEmpty else { return }
        continuation.yield(.audio(AudioFrames(
            samples: frames.samples, channels: frames.channels,
            frequency: frames.frequency, time: frames.time
        )))
    }

    /// Reads the main channel for as long as the session lasts.
    ///
    /// Failures here end this task and nothing else, like the cursor's. Losing
    /// the clipboard is losing the clipboard; the display channel is what
    /// decides whether the session is still alive, and tearing it down because
    /// the agent stopped would throw away a working screen.
    private func followMain(_ agent: SpiceAgentChannel) async {
        while !Task.isCancelled {
            do {
                for text in try await agent.pump().clipboard {
                    continuation.yield(.clipboard(text))
                }
            } catch {
                return
            }
        }
    }

    /// The phone copied something. Held for the guest to ask for.
    private func offerClipboard(_ text: String) async {
        try? await agent?.offer(text)
    }

    /// Reads the cursor channel and reports what the pointer looks like.
    ///
    /// Failures here end this task and nothing else. Losing the cursor is
    /// losing the cursor; the display channel is what decides whether the
    /// session is still alive, and tearing it down because the pointer stopped
    /// would throw away a working screen.
    private func followCursor(on stream: any ByteStream) async {
        var serial: UInt64 = 1
        while !Task.isCancelled {
            do {
                let header = try SpiceWire.decodeDataHeader(
                    try await stream.read(exactly: SpiceWire.dataHeaderBytes)
                )
                guard header.size <= 1 << 22 else { return }
                let payload = header.size == 0
                    ? Data() : try await stream.read(exactly: Int(header.size))

                switch header.type {
                case SpiceWire.Message.ping:
                    try await stream.write(SpiceWire.message(
                        SpiceWire.ClientMessage.pong, serial: serial, payload: payload
                    ))
                    serial += 1
                case SpiceCursorWire.Message.initialise.rawValue:
                    publish(try SpiceCursorWire.initialise([UInt8](payload)))
                case SpiceCursorWire.Message.set.rawValue:
                    publish(try SpiceCursorWire.set([UInt8](payload)))
                case SpiceCursorWire.Message.hide.rawValue:
                    continuation.yield(.cursor(RemoteCursor(
                        width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: []
                    )))
                default:
                    // `MOVE` and the trail and cache messages are read and
                    // dropped: the pointer's position on screen is the phone's
                    // to decide, since the finger is what moved it.
                    continue
                }
            } catch {
                return
            }
        }
    }

    /// Only an actual image reaches the UI.
    ///
    /// A cursor named from a cache this client does not keep is not an empty
    /// cursor: forwarding one would read as "hide the pointer", which is the
    /// opposite of what the server asked for.
    private func publish(_ update: SpiceCursorWire.Update) {
        guard update.visible else {
            continuation.yield(.cursor(RemoteCursor(
                width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: []
            )))
            return
        }
        guard let cursor = update.cursor else { return }
        continuation.yield(.cursor(cursor))
    }

    /// Reads the display channel until it stops or the task is cancelled.
    ///
    /// The surfaces live here rather than on the actor, and Swift 6 is right to
    /// insist: actor state cannot be passed `inout` across an `await`, because
    /// between the two halves of that call anything else on the actor could
    /// have run and changed it. The pump owns them for as long as it runs,
    /// which is also the honest lifetime — a fresh connection starts with a
    /// blank screen, not with the last one's surfaces.
    private func run(_ channel: SpiceDisplayChannel, from serial: UInt64) async {
        var announced = false
        var surfaces = SpiceSurfaces()
        // What this connection remembers about images: the GLZ window and the
        // pixmap cache, for the same reason and with the same lifetime as the
        // surfaces. A GLZ stream may refer to images decoded earlier on this
        // socket, and a cached image is one the server believes *this*
        // connection kept — neither survives a reconnect, and the server
        // agrees: it clears its own mirror when the client reconnects.
        var caches = SpiceDisplayCaches()
        var streams = SpiceStreams()
        var serial = serial
        do {
            while !Task.isCancelled {
                let progress = try await channel.pump(into: &surfaces, caches: &caches, streams: &streams, serial: serial)
                serial = progress.nextSerial

                // The first surface to appear is the desktop, and its size is
                // what the UI needs before it can lay anything out.
                if !announced, let primary = surfaces.surfaces[0] {
                    announced = true
                    framebuffer.resize(width: primary.width, height: primary.height)
                    continuation.yield(.ready(
                        desktopName: configuration.host,
                        width: primary.width, height: primary.height
                    ))
                }
                publish(progress, from: surfaces)
            }
        } catch {
            finish(with: error)
        }
    }

    /// Copies what changed into the framebuffer and tells the renderer where.
    ///
    /// Only the regions that were drawn, rather than the whole surface: a
    /// renderer handed the whole screen on every fill redraws a phone's display
    /// for a blinking cursor.
    private func publish(_ progress: SpiceDisplayChannel.Progress, from surfaces: SpiceSurfaces) {
        guard let primary = surfaces.surfaces[0] else { return }
        var changed: [Rect] = []

        for update in progress.updates where update.surfaceID == 0 {
            for region in update.regions {
                let rect = Rect(
                    x: Int(region.left), y: Int(region.top),
                    width: Int(region.width), height: Int(region.height)
                )
                guard rect.width > 0, rect.height > 0 else { continue }

                // The surface holds whole rows; the framebuffer wants just this
                // rectangle, packed.
                var patch = [UInt8]()
                patch.reserveCapacity(rect.width * rect.height * 4)
                for row in 0..<rect.height {
                    let start = ((rect.y + row) * primary.width + rect.x) * 4
                    patch.append(contentsOf: primary.pixels[start..<(start + rect.width * 4)])
                }
                framebuffer.write(rect: rect, bgra: patch)
                changed.append(rect)
            }
        }
        if !changed.isEmpty { continuation.yield(.framebufferChanged(changed)) }
    }

    private func finish(with error: Error) {
        let wisq = error as? WisqError
            ?? .connectionFailed(String(describing: error))
        continuation.yield(.disconnected(wisq))
        continuation.finish()
    }

    private static let defaultStreamProvider: StreamProvider = { configuration in
        #if canImport(Network)
        let stream = try NetworkByteStream(
            host: configuration.host,
            port: configuration.port,
            security: configuration.security
        )
        try await stream.open()
        return stream
        #else
        throw WisqError.notImplemented("transport réseau indisponible sur cette plateforme")
        #endif
    }
}
