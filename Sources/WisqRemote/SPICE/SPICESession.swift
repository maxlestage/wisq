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
        pump = nil
        cursorPump = nil
        await main?.close()
        await display?.close()
        await inputs?.close()
        await cursor?.close()
        main = nil
        display = nil
        inputs = nil
        cursor = nil
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
            .open(channel: .main, password: password)

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
                channelCaps: SpiceDisplayClient.capabilityWords([.preferredCompression])
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
        var serial = serial
        do {
            while !Task.isCancelled {
                let progress = try await channel.pump(into: &surfaces, serial: serial)
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
