import Foundation
import WisqNet

/// The main channel, kept running, with the guest's agent on it.
///
/// Two things were missing and the second hides the first. Nothing read the
/// main channel after the handshake, so the server's pings went unanswered on a
/// socket whose receive buffer filled quietly; and the clipboard, which lives
/// on that channel rather than on inputs, had nowhere to arrive. This reads it
/// and does both.
///
/// An actor rather than a `struct` over a `ByteStream`, which the display
/// channel next door is. The difference is that this one is written from two
/// places: the pump reads the guest's clipboard, and the UI offers the phone's
/// whenever somebody copies. Swift 6 will not let actor state cross an `await`
/// as `inout`, and it is right — so the state lives here, where one owner
/// mutates it between suspension points instead of two copying it back and
/// forth. It still drives against a scripted stream in a test with no socket.
///
/// **The clipboard is by demand, in both directions**, which is the shape that
/// surprises people who expect a copy to send the text:
///
///   * the guest copies → it sends `GRAB` naming the kinds it has → this sends
///     `REQUEST` → the guest sends `CLIPBOARD` with the bytes;
///   * the phone copies → this sends `GRAB` → the guest sends `REQUEST` → this
///     sends `CLIPBOARD`.
///
/// So the text the user copied has to be *kept* until the guest asks for it,
/// which may be never. That is what `offered` is, and it is why a copy
/// on the phone appears to do nothing until something in the guest pastes.
actor SpiceAgentChannel {
    private let stream: ByteStream

    /// Whether an agent is running in the guest. Without one there is no
    /// clipboard at all, and messages sent anyway go nowhere.
    private(set) var connected: Bool

    /// **The guest's** capabilities, not this client's.
    ///
    /// They decide the layout of every clipboard message in both directions:
    /// what wisq writes has to match what the guest reads. A client that used
    /// its own here would be right only when the two happened to agree.
    private(set) var capabilities: [UInt32] = []

    private(set) var tokens: SpiceAgentTransport.Tokens
    private var reassembler = SpiceAgentTransport.Reassembler()

    /// `AGENT_DATA` payloads waiting for a token.
    ///
    /// Queued rather than dropped: running out of tokens is ordinary
    /// back-pressure, not an error, and a clipboard that silently loses the
    /// paste that arrived at a busy moment is worse than one that is slow.
    private(set) var waiting: [[UInt8]] = []

    /// Whether a drain is already in progress.
    ///
    /// One at a time, and what that still buys is the **tokens**.
    ///
    /// This comment used to say the reason was the serial, and it described
    /// that hazard correctly. It was also describing it in the one place that
    /// was guarded: `write` had three other callers, and a `pong` from the
    /// pump crossing a drain reproduced the duplicate this flag was meant to
    /// prevent. The serial is now stamped inside `write`, before any
    /// suspension, so every caller is covered and this flag no longer carries
    /// that job.
    ///
    /// What is left is real: `tokens.spend()` decides how much may go out, and
    /// two loops spending from the same budget would each believe they had
    /// room the other has taken.
    ///
    /// A second drainer returns rather than waiting: the first one re-checks
    /// the queue every time round, so the work it left is picked up anyway.
    private var draining = false

    /// What the phone has copied and the guest has not yet asked for.
    private(set) var offered: String?

    /// Counts grabs so the guest can tell a current one from a stale one.
    private var grabSerial: UInt32 = 0

    /// This client's message counter for the main channel. A server that
    /// acknowledges by serial is entitled to a sequence with no holes.
    private var serial: UInt64

    /// Stamped messages waiting for the socket, and whether a drainer is
    /// running. Separate from `waiting` above, which holds *agent* messages
    /// before they are wrapped: this one holds finished channel messages, and
    /// its job is the serial rather than the tokens.
    private var outgoing: [Data] = []
    private var sending = false

    /// Bytes held part-way through an incoming message. Zero between messages,
    /// and worth asserting on in a test.
    var buffered: Int { reassembler.buffered }

    init(
        stream: ByteStream, connected: Bool = false,
        tokens: UInt32 = 0, serial: UInt64 = 1
    ) {
        self.stream = stream
        self.connected = connected
        self.tokens = SpiceAgentTransport.Tokens(available: tokens)
        self.serial = serial
    }

    /// What a run of the pump produced.
    struct Progress: Equatable {
        /// Text the guest put on its clipboard, in arrival order.
        var clipboard: [String] = []
        /// The agent appeared or went away during this run. Reported rather
        /// than inferred from `connected`, because a caller that only
        /// looked at the flag would miss an agent that restarted between two
        /// pumps.
        var agentAppeared = false
        var agentVanished = false
        /// Messages this does not handle, by type. Counted rather than logged,
        /// so a test can assert on how much of the protocol is ignored.
        var ignored: [UInt16: Int] = [:]
        var nextSerial: UInt64 = 0
    }

    /// A cap on one main-channel message. Tens of bytes is the norm here and
    /// an agent payload is capped at 2048, so a megabyte is a server to stop
    /// talking to rather than accommodate.
    static let maximumMessageBytes = 1 << 20

    /// Granted to the server for what it sends *this way*.
    ///
    /// Unlimited, which is what every real client does: the incoming direction
    /// is already bounded by `SpiceAgentTransport.maximumMessageBytes`, so a
    /// second budget on top of it would only add a way to deadlock.
    static let tokensGrantedToServer = UInt32.max

    // MARK: - Starting the agent

    /// Tells the server to start the agent and announces what wisq can do.
    ///
    /// The order is the protocol's: `AGENT_START` first, because the
    /// announcement is an agent message and there is no agent to receive one
    /// until the server has been asked to connect it.
    func start() async throws {
        try await write(
            SpiceWire.ClientMessage.agentStart,
            payload: Data(SpiceWire.u32(Self.tokensGrantedToServer))
        )

        // `request: true` asks the guest to announce back. Without it, an agent
        // that announced before this client attached never announces again, and
        // every clipboard message afterwards is read with the wrong layout.
        enqueue(SpiceAgent.message(
            .announceCapabilities,
            body: SpiceAgent.announcementBody(SpiceAgent.Announcement(
                request: true,
                capabilities: SpiceAgent.capabilityWords(SpiceAgent.clientCapabilities)
            ))
        ))
        try await flush()
    }

    // MARK: - Reading

    /// Reads up to `limit` messages. One by default, like the display channel:
    /// a batch reports only once it is full, and a clipboard that arrives when
    /// the batch fills is a clipboard that arrives never on a quiet desktop.
    func pump(limit: Int = 1) async throws -> Progress {
        var progress = Progress()

        for _ in 0..<limit {
            let header = try SpiceWire.decodeDataHeader(
                try await stream.read(exactly: SpiceWire.dataHeaderBytes)
            )
            guard header.size <= Self.maximumMessageBytes else { throw SpiceError.invalidData }
            let payload = header.size == 0
                ? Data() : try await stream.read(exactly: Int(header.size))

            switch header.type {
            case SpiceWire.Message.ping:
                // Answered rather than counted as ignored: a server that pings
                // and hears nothing concludes the client is gone.
                try await write(SpiceWire.ClientMessage.pong, payload: payload)

            case SpiceWire.Message.setAck:
                let ack = try SpiceWire.decodeSetAck(payload)
                try await write(
                    SpiceWire.ClientMessage.ackSync,
                    payload: Data(SpiceWire.u32(ack.generation))
                )

            case SpiceWire.Message.mainAgentConnected:
                progress.agentAppeared = true
                try await agentAppeared(tokens: nil)

            case SpiceWire.Message.mainAgentConnectedTokens:
                progress.agentAppeared = true
                var reader = SpiceWire.Reader(payload)
                try await agentAppeared(tokens: try reader.u32())

            case SpiceWire.Message.mainAgentDisconnected:
                progress.agentVanished = true
                connected = false
                capabilities = []
                // The half-received message will never be completed, and the
                // queued ones are addressed to an agent that is gone.
                reassembler.reset()
                waiting.removeAll()

            case SpiceWire.Message.mainAgentToken:
                var reader = SpiceWire.Reader(payload)
                tokens.grant(try reader.u32())
                try await flush()

            case SpiceWire.Message.mainAgentData:
                for (agentHeader, body) in try reassembler.accept([UInt8](payload)) {
                    try await handle(agentHeader, body: body, progress: &progress)
                }

            case SpiceWire.Message.disconnecting:
                throw SpiceError.refused(.error)

            default:
                progress.ignored[header.type, default: 0] += 1
            }
        }
        progress.nextSerial = serial
        return progress
    }

    // MARK: - Writing

    /// The phone copied something: tell the guest it is on offer.
    ///
    /// The text is kept rather than sent. `GRAB` says only *what kinds* exist;
    /// the bytes go out when the guest asks, which is the whole of "by demand".
    func offer(_ text: String) async throws {
        offered = text
        guard connected else { return }

        grabSerial &+= 1
        enqueue(SpiceAgent.message(.clipboardGrab, body: SpiceAgent.grabBody(
            [.utf8Text], serial: grabSerial, capabilities: capabilities
        )))
        try await flush()
    }

    // MARK: - One agent message

    private func handle(
        _ header: SpiceAgent.Header, body: [UInt8], progress: inout Progress
    ) async throws {
        switch header.type {
        case .announceCapabilities:
            let announcement = try SpiceAgent.announcement(body)
            capabilities = announcement.capabilities
            guard announcement.request else { return }
            // Answered without the flag set. Answering with it would ask the
            // guest to announce back, which asks this to answer again.
            enqueue(SpiceAgent.message(
                .announceCapabilities,
                body: SpiceAgent.announcementBody(SpiceAgent.Announcement(
                    request: false,
                    capabilities: SpiceAgent.capabilityWords(SpiceAgent.clientCapabilities)
                ))
            ))
            try await flush()

        case .clipboardGrab:
            let grab = try SpiceAgent.grab(body, capabilities: capabilities)
            // Only text. A guest offering an image and nothing else is not an
            // error and not something a phone's pasteboard gets from here yet;
            // asking for a kind that was not offered is.
            guard grab.kinds.contains(.utf8Text) else { return }
            enqueue(SpiceAgent.message(.clipboardRequest, body: SpiceAgent.requestBody(
                .utf8Text, selection: grab.selection, capabilities: capabilities
            )))
            try await flush()

        case .clipboard:
            let clipboard = try SpiceAgent.clipboard(body, capabilities: capabilities)
            if let text = clipboard.text { progress.clipboard.append(text) }

        case .clipboardRequest:
            let kind = try SpiceAgent.request(body, capabilities: capabilities)
            // A request for what was never offered, or for a kind this cannot
            // produce, is answered with `none` rather than ignored: a guest
            // waiting on a reply that never comes hangs its own paste.
            let text = kind == .utf8Text ? offered : nil
            enqueue(SpiceAgent.message(.clipboard, body: SpiceAgent.clipboardBody(
                text == nil ? .none : .utf8Text,
                data: text.map { Array($0.utf8) } ?? [],
                capabilities: capabilities
            )))
            try await flush()

        case .clipboardRelease:
            // The guest withdrew its offer. Nothing to undo here: what the
            // phone already pasted is the phone's now.
            break

        default:
            progress.ignored[UInt16(truncatingIfNeeded: header.type.rawValue), default: 0] += 1
        }
    }

    // MARK: - The queue

    private func agentAppeared(tokens granted: UInt32?) async throws {
        connected = true
        capabilities = []
        reassembler.reset()
        if let granted { tokens = SpiceAgentTransport.Tokens(available: granted) }
        try await start()
        // Whatever was copied before the agent existed is offered now. Without
        // this a copy made while the guest was still booting is lost with no
        // sign of it.
        if let offered { try await offer(offered) }
    }

    /// Splits a message into `AGENT_DATA` payloads and queues them.
    ///
    /// Never partly: the pieces of one message go on the queue together, so a
    /// message can be delayed by a shortage of tokens but never interleaved
    /// with another one's bytes — which the far end would reassemble into
    /// nonsense, since nothing in the stream marks where a message begins.
    private func enqueue(_ message: [UInt8]) {
        waiting += SpiceAgentTransport.pieces(of: message)
    }

    /// Sends what tokens allow, keeping the rest.
    private func flush() async throws {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        while !waiting.isEmpty, tokens.spend() {
            let piece = waiting.removeFirst()
            try await write(SpiceWire.ClientMessage.agentData, payload: Data(piece))
        }
    }

    /// Stamps a message and puts it on the outbox, then drains.
    ///
    /// The stamping and the increment happen together, synchronously, before
    /// any suspension — which is what makes the number unique. `draining`
    /// below guarded only one of this method's four callers, and that was
    /// enough to hide the hole: a `pong` answered by the pump while a
    /// clipboard drain was mid-write took the number the drain was already
    /// using. Measured, with both writes parked at once: **`[1, 1]`**.
    ///
    /// Finding it needed a stronger probe than the first one written. Released
    /// after a single parked write, the two paths ran one after the other and
    /// reported a tidy `[1, 2]` — an answer that looks like data and is only
    /// the instrument's shape. Waiting for *both* writes to be parked is what
    /// makes the test able to see the defect at all.
    private func write(_ type: UInt16, payload: Data) async throws {
        outgoing.append(SpiceWire.message(type, serial: serial, payload: payload))
        serial += 1
        try await drainOutgoing()
    }

    /// Writes stamped messages in order, one drainer at a time.
    private func drainOutgoing() async throws {
        guard !sending else { return }
        sending = true
        defer { sending = false }

        while !outgoing.isEmpty {
            let next = outgoing.removeFirst()
            do {
                try await stream.write(next)
            } catch {
                outgoing.removeAll()
                throw error
            }
        }
    }
}
