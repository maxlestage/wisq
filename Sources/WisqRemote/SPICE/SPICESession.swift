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
    private var pump: Task<Void, Never>?

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
        pump = nil
        await main?.close()
        await display?.close()
        main = nil
        display = nil
        continuation.yield(.disconnected(nil))
        continuation.finish()
    }

    /// Not wired yet. The inputs channel is encoded and tested
    /// (`SpiceInputs`), and it needs a third connection of its own; sending on
    /// the display channel would be sending keystrokes down the wrong socket.
    public func send(_ event: InputEvent) async {}

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

        pump = Task { [weak self] in
            await self?.run(channel, from: serial)
        }
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
