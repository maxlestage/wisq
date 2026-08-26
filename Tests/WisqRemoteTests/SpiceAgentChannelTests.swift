import Foundation
import WisqNet
import XCTest
@testable import WisqRemote

/// The main channel kept running, and the clipboard on it.
///
/// Driven against a scripted server with no socket, so the orderings below are
/// asserted rather than hoped for: what the client sends first, what it sends
/// only after the guest announced, and what it holds back for want of a token.
final class SpiceAgentChannelTests: XCTestCase {
    private func u32(_ value: UInt32) -> [UInt8] { SpiceWire.u32(value) }

    private func serverMessage(_ type: UInt16, _ payload: [UInt8] = []) -> Data {
        SpiceWire.message(type, serial: 1, payload: Data(payload))
    }

    /// One agent message, wrapped as the server wraps it: no chunk header, just
    /// the `VDAgentMessage` bytes in an `AGENT_DATA`.
    private func agentData(_ type: SpiceAgent.Message, body: [UInt8]) -> Data {
        serverMessage(
            SpiceWire.Message.mainAgentData, SpiceAgent.message(type, body: body)
        )
    }

    /// The guest announcing what it can do. The layout of everything after this
    /// depends on it, which is why so many tests start here.
    private func guestAnnouncement(
        _ capabilities: [SpiceAgent.Capability] = [.clipboardByDemand, .clipboardSelection],
        request: Bool = false
    ) -> Data {
        agentData(.announceCapabilities, body: SpiceAgent.announcementBody(
            SpiceAgent.Announcement(
                request: request, capabilities: SpiceAgent.capabilityWords(capabilities)
            )
        ))
    }

    /// The serial stamped on each message the client sent.
    private func serialsSent(_ written: Data) -> [UInt64] {
        var reader = SpiceWire.Reader(written)
        var out: [UInt64] = []
        while reader.remaining >= SpiceWire.dataHeaderBytes,
              let header = try? SpiceWire.decodeDataHeader(
                  Data(try reader.bytes(SpiceWire.dataHeaderBytes))
              ),
              (try? reader.bytes(Int(header.size))) != nil {
            out.append(header.serial)
        }
        return out
    }

    /// Everything the client sent, split back into messages.
    private func sent(_ stream: MemoryByteStream) async throws -> [(UInt16, [UInt8])] {
        var reader = SpiceWire.Reader(await stream.written)
        var out: [(UInt16, [UInt8])] = []
        while reader.remaining >= SpiceWire.dataHeaderBytes {
            let header = try SpiceWire.decodeDataHeader(
                Data(try reader.bytes(SpiceWire.dataHeaderBytes))
            )
            out.append((header.type, try reader.bytes(Int(header.size))))
        }
        return out
    }

    /// The agent messages inside what the client sent, reassembled — which is
    /// the only honest way to read them, since one can span several
    /// `AGENT_DATA` messages.
    private func sentAgentMessages(
        _ stream: MemoryByteStream
    ) async throws -> [(SpiceAgent.Header, [UInt8])] {
        var reassembler = SpiceAgentTransport.Reassembler()
        var out: [(SpiceAgent.Header, [UInt8])] = []
        for (type, payload) in try await sent(stream)
        where type == SpiceWire.ClientMessage.agentData {
            out += try reassembler.accept(payload)
        }
        return out
    }

    private func channel(
        _ stream: MemoryByteStream, tokens: UInt32 = 100, connected: Bool = true
    ) -> SpiceAgentChannel {
        SpiceAgentChannel(stream: stream, connected: connected, tokens: tokens)
    }

    // MARK: - Starting

    /// `AGENT_START` before the announcement, and that order is the protocol's:
    /// the announcement is an agent message, and there is no agent to receive
    /// one until the server has been asked to connect it.
    func testAgentStartIsSentBeforeTheCapabilityAnnouncement() async throws {
        let server = MemoryByteStream()
        let channel = channel(server)

        try await channel.start()

        let messages = try await sent(server)
        XCTAssertEqual(messages.map(\.0), [
            SpiceWire.ClientMessage.agentStart, SpiceWire.ClientMessage.agentData
        ])
        XCTAssertEqual(
            messages[0].1, u32(.max),
            "les jetons accordés au serveur : illimités, comme tout vrai client"
        )
    }

    /// The request flag is set on the first announcement, and it is not
    /// decoration: an agent that announced before this client attached never
    /// announces again unasked, and the clipboard layout is computed from what
    /// it says. Without the flag every clipboard message afterwards is read
    /// four bytes out of place.
    func testTheFirstAnnouncementAsksTheGuestToAnnounceBack() async throws {
        let server = MemoryByteStream()
        let channel = channel(server)

        try await channel.start()

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.count, 1)
        XCTAssertEqual(agent[0].0.type, .announceCapabilities)
        XCTAssertTrue(try SpiceAgent.announcement(agent[0].1).request)
    }

    /// An agent that appears later gets the same treatment, and the token count
    /// it comes with replaces whatever was left over from the last one.
    func testAnAgentAppearingLaterIsStartedToo() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentConnectedTokens, u32(7))
        )
        let channel = channel(server, tokens: 0, connected: false)

        let progress = try await channel.pump()

        XCTAssertTrue(progress.agentAppeared)
        let connected = await channel.connected
        XCTAssertTrue(connected)
        let started = try await sent(server).map(\.0)
        XCTAssertEqual(started, [
            SpiceWire.ClientMessage.agentStart, SpiceWire.ClientMessage.agentData
        ])
        // Seven granted, one spent on the announcement.
        let available = await channel.tokens.available
        XCTAssertEqual(available, 6)
    }

    /// The bare `AGENT_CONNECTED` says nothing about tokens, so whatever budget
    /// the session already had stands. Zeroing it here would mute the client.
    func testTheBareConnectedMessageLeavesTheBudgetAlone() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentConnected)
        )
        let channel = channel(server, tokens: 3, connected: false)

        _ = try await channel.pump()

        let available = await channel.tokens.available
        XCTAssertEqual(available, 2, "trois moins l'annonce")
    }

    /// **Why the token-carrying message is worth asking for.**
    ///
    /// The bare `AGENT_CONNECTED` keeps the budget, which is the right call for
    /// that path — zeroing would mute the client outright. But *keeping* a
    /// budget of zero is its own trap, and it is not recoverable: `spend()`
    /// fails, so nothing is sent, so the server consumes nothing, so it never
    /// grants tokens back with `MAIN_AGENT_TOKEN`. The clipboard is dead for
    /// the rest of the session.
    ///
    /// That is not hypothetical after an agent restart. `RedCharDevice::reset`
    /// hands the client its whole allowance back *on the server's side* —
    /// `num_client_tokens += num_client_tokens_free` — and `reds_reset_vdp`
    /// says a client only ever learns a count "once when the main channel is
    /// initialized and once upon agent's connection with
    /// `SPICE_MSG_MAIN_AGENT_CONNECTED_TOKENS`". Message 107 carries no count,
    /// so the two sides silently disagree.
    ///
    /// wisq now advertises the capability, so it gets 115 and the real number.
    /// This test keeps the reason visible.
    func testAZeroBudgetOnTheBareMessageNeverRecovers() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentConnected)
        )
        let stalled = channel(server, tokens: 0, connected: false)

        _ = try await stalled.pump()

        let available = await stalled.tokens.available
        XCTAssertEqual(available, 0)
        // `AGENT_START` is a main-channel message and costs no token, so the
        // handshake half-completes; the capability announcement is agent *data*
        // and stays queued. That distinction is the whole failure: the guest
        // sees a client attach and then never hears what it can do, so the
        // clipboard is inert rather than obviously broken.
        let sentWithoutTokens = try await sent(server).map(\.0)
        XCTAssertEqual(sentWithoutTokens, [SpiceWire.ClientMessage.agentStart])
        XCTAssertFalse(
            sentWithoutTokens.contains(SpiceWire.ClientMessage.agentData),
            "sans jeton, aucune donnée d'agent ne part"
        )

        // Le même flux avec le message qui porte un compte : tout repart.
        let withTokens = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentConnectedTokens, u32(4))
        )
        let recovered = channel(withTokens, tokens: 0, connected: false)
        _ = try await recovered.pump()
        let sentWithTokens = try await sent(withTokens).map(\.0)
        XCTAssertEqual(sentWithTokens, [
            SpiceWire.ClientMessage.agentStart, SpiceWire.ClientMessage.agentData
        ], "le compte reçu laisse enfin partir l'annonce")
    }

    // MARK: - Keeping the channel alive

    /// Nothing read this channel after the handshake, so the server's pings
    /// went unanswered into a socket buffer that filled quietly — and a server
    /// that pings and hears nothing decides the client is gone.
    func testAPingOnTheMainChannelIsAnswered() async throws {
        var ping = u32(9)
        ping += SpiceWire.u64(1234)
        let server = MemoryByteStream(inbound: serverMessage(SpiceWire.Message.ping, ping))
        let channel = channel(server)

        _ = try await channel.pump()

        let messages = try await sent(server)
        XCTAssertEqual(messages.map(\.0), [SpiceWire.ClientMessage.pong])
        XCTAssertEqual(messages[0].1, ping, "renvoyé tel quel, le serveur chronomètre")
    }

    /// The generation has to be echoed: it is how the server tells an
    /// acknowledgement for this window from one for the last.
    func testASetAckIsAnsweredWithItsGeneration() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.setAck, u32(42) + u32(10))
        )
        let channel = channel(server)

        _ = try await channel.pump()

        let messages = try await sent(server)
        XCTAssertEqual(messages.map(\.0), [SpiceWire.ClientMessage.ackSync])
        XCTAssertEqual(messages[0].1, u32(42))
    }

    /// Messages this does not handle are counted, not fatal — and the payload
    /// is consumed either way, which is the only thing that actually matters.
    func testAnUnhandledMessageIsCountedAndTheStreamStaysInStep() async throws {
        var inbound = serverMessage(SpiceWire.Message.mainMultiMediaTime, u32(5))
        inbound += serverMessage(SpiceWire.Message.setAck, u32(1) + u32(1))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        let progress = try await channel.pump(limit: 2)

        XCTAssertEqual(progress.ignored, [SpiceWire.Message.mainMultiMediaTime: 1])
        let types = try await sent(server).map(\.0)
        XCTAssertEqual(types, [SpiceWire.ClientMessage.ackSync])
    }

    // MARK: - The guest's clipboard

    /// The whole inbound loop: the guest announces, grabs, this asks, the guest
    /// answers. The text only exists after the fourth step, which is what "by
    /// demand" means and why a client that stops at the grab shows nothing.
    func testTheGuestCopyingSomethingArrivesAsText() async throws {
        let caps = SpiceAgent.capabilityWords([.clipboardByDemand, .clipboardSelection])
        var inbound = guestAnnouncement()
        inbound += agentData(.clipboardGrab, body: SpiceAgent.grabBody(
            [.utf8Text], serial: 1, capabilities: caps
        ))
        inbound += agentData(.clipboard, body: SpiceAgent.clipboardBody(
            .utf8Text, data: Array("copié dans l'invité".utf8), capabilities: caps
        ))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        let progress = try await channel.pump(limit: 3)

        XCTAssertEqual(progress.clipboard, ["copié dans l'invité"])
        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.clipboardRequest])
        XCTAssertEqual(
            try SpiceAgent.request(agent[0].1, capabilities: caps), .utf8Text
        )
    }

    /// A guest offering only an image is not an error and not something to ask
    /// for: requesting a kind that was never offered is what an agent refuses.
    func testAGrabWithoutTextIsNotAskedFor() async throws {
        let caps = SpiceAgent.capabilityWords([.clipboardByDemand, .clipboardSelection])
        var inbound = guestAnnouncement()
        inbound += agentData(.clipboardGrab, body: SpiceAgent.grabBody(
            [.imagePNG], serial: 1, capabilities: caps
        ))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        _ = try await channel.pump(limit: 2)

        let nothing = try await sentAgentMessages(server)
        XCTAssertTrue(nothing.isEmpty)
    }

    /// The layout is the guest's to decide. Announce the selection capability
    /// and the clipboard body gains four bytes in front of the kind; read it
    /// with the wrong layout and the kind is whatever the padding was.
    func testTheClipboardIsReadWithTheLayoutTheGuestAnnounced() async throws {
        for selection in [true, false] {
            let caps = SpiceAgent.capabilityWords(
                selection ? [.clipboardByDemand, .clipboardSelection] : [.clipboardByDemand]
            )
            var inbound = guestAnnouncement(
                selection ? [.clipboardByDemand, .clipboardSelection] : [.clipboardByDemand]
            )
            inbound += agentData(.clipboard, body: SpiceAgent.clipboardBody(
                .utf8Text, data: Array("mise en page".utf8), capabilities: caps
            ))
            let server = MemoryByteStream(inbound: inbound)
            let channel = channel(server)

            let progress = try await channel.pump(limit: 2)
            XCTAssertEqual(
                progress.clipboard, ["mise en page"],
                "sélection annoncée : \(selection)"
            )
        }
    }

    /// Long text crosses several `AGENT_DATA` messages, because the server
    /// forwards what the guest's pipe handed it. Treating each as a whole
    /// message is the bug that only shows up on a real document.
    func testTextTooLongForOneMessageStillArrivesWhole() async throws {
        let caps = SpiceAgent.capabilityWords([.clipboardByDemand])
        let text = String(repeating: "un document entier. ", count: 500)
        let message = SpiceAgent.message(.clipboard, body: SpiceAgent.clipboardBody(
            .utf8Text, data: Array(text.utf8), capabilities: caps
        ))
        let pieces = SpiceAgentTransport.pieces(of: message)
        XCTAssertGreaterThan(pieces.count, 4, "sinon le test ne teste rien")

        var inbound = guestAnnouncement([.clipboardByDemand])
        for piece in pieces {
            inbound += serverMessage(SpiceWire.Message.mainAgentData, piece)
        }
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        let progress = try await channel.pump(limit: 1 + pieces.count)

        XCTAssertEqual(progress.clipboard, [text])
        let buffered = await channel.buffered
        XCTAssertEqual(buffered, 0)
    }

    /// A guest that asks to be answered is answered — once. Replying with the
    /// flag set again would ask it to announce back, which asks this to answer
    /// again.
    func testAnAnnouncementThatAsksForOneGetsAReplyThatDoesNot() async throws {
        let server = MemoryByteStream(inbound: guestAnnouncement(request: true))
        let channel = channel(server)

        _ = try await channel.pump()

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.announceCapabilities])
        XCTAssertFalse(try SpiceAgent.announcement(agent[0].1).request)
    }

    // MARK: - The phone's clipboard

    /// Copying on the phone sends a grab and nothing else. The text waits: it
    /// goes out when the guest asks for it, which may be never, and that is why
    /// a copy appears to do nothing until something in the guest pastes.
    func testCopyingOnThePhoneOffersRatherThanSends() async throws {
        let server = MemoryByteStream(inbound: guestAnnouncement())
        let channel = channel(server)
        _ = try await channel.pump()

        try await channel.offer("copié sur le téléphone")

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.clipboardGrab])
        let grab = try SpiceAgent.grab(agent[0].1, capabilities: await channel.capabilities)
        XCTAssertEqual(grab.kinds, [.utf8Text])
        let offered = await channel.offered
        XCTAssertEqual(offered, "copié sur le téléphone")
    }

    /// And when the guest does ask, it gets the text that was kept.
    func testTheGuestAskingForThePhonesClipboardGetsIt() async throws {
        let caps = SpiceAgent.capabilityWords([.clipboardByDemand, .clipboardSelection])
        var inbound = guestAnnouncement()
        inbound += agentData(.clipboardRequest, body: SpiceAgent.requestBody(
            .utf8Text, capabilities: caps
        ))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        _ = try await channel.pump()
        try await channel.offer("gardé pour l'invité")
        _ = try await channel.pump()

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.clipboardGrab, .clipboard])
        let clipboard = try SpiceAgent.clipboard(agent[1].1, capabilities: caps)
        XCTAssertEqual(clipboard.kind, .utf8Text)
        XCTAssertEqual(clipboard.text, "gardé pour l'invité")
    }

    /// A request for something never offered is answered with `none` rather
    /// than ignored: a guest waiting on a reply that never comes hangs its own
    /// paste.
    func testARequestForNothingOnOfferIsStillAnswered() async throws {
        let caps = SpiceAgent.capabilityWords([.clipboardByDemand, .clipboardSelection])
        var inbound = guestAnnouncement()
        inbound += agentData(.clipboardRequest, body: SpiceAgent.requestBody(
            .utf8Text, capabilities: caps
        ))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        _ = try await channel.pump(limit: 2)

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.clipboard])
        XCTAssertEqual(
            try SpiceAgent.clipboard(agent[0].1, capabilities: caps).kind, .none
        )
    }

    // MARK: - Tokens

    /// Out of tokens is back-pressure, not an error. The message waits rather
    /// than going out unpaid — which is how a client gets disconnected — and
    /// rather than being dropped, which loses the paste that arrived at a busy
    /// moment.
    func testAMessageWithNoTokenLeftWaitsRatherThanGoingOut() async throws {
        let server = MemoryByteStream()
        let channel = channel(server, tokens: 0)

        _ = try await channel.start()

        let onlyStart = try await sent(server).map(\.0)
        XCTAssertEqual(
            onlyStart, [SpiceWire.ClientMessage.agentStart],
            "AGENT_START ne coûte pas de jeton ; l'annonce si"
        )
        let queued = await channel.waiting.count
        XCTAssertEqual(queued, 1)
    }

    /// And a grant sends it, without being asked twice.
    func testAGrantSendsWhatWasWaiting() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentToken, u32(4))
        )
        let channel = channel(server, tokens: 0)
        try await channel.start()
        let queued = await channel.waiting.count
        XCTAssertEqual(queued, 1)

        _ = try await channel.pump()

        let waitingisEmpty = await channel.waiting.isEmpty
        XCTAssertTrue(waitingisEmpty)
        let available = await channel.tokens.available
        XCTAssertEqual(available, 3)
        let flushed = try await sentAgentMessages(server).map(\.0.type)
        XCTAssertEqual(flushed, [.announceCapabilities])
    }

    /// A message longer than one payload spends one token per payload, because
    /// that is what the server counts.
    func testEachPayloadCostsAToken() async throws {
        let server = MemoryByteStream(inbound: guestAnnouncement([.clipboardByDemand]))
        let channel = channel(server, tokens: 100)
        _ = try await channel.pump()
        let before = await channel.tokens.available

        // Big enough to need several payloads once it is asked for.
        let long = String(repeating: "z", count: 5000)
        try await channel.offer(long)
        await server.feed(serverMessage(
            SpiceWire.Message.mainAgentData,
            SpiceAgent.message(.clipboardRequest, body: SpiceAgent.requestBody(
                .utf8Text, capabilities: await channel.capabilities
            ))
        ))
        _ = try await channel.pump()

        let payloads = try await sent(server)
            .filter { $0.0 == SpiceWire.ClientMessage.agentData }
        // The grab is one payload; the clipboard reply needs several. Nothing
        // else went out — the scripted guest did not ask to be announced back
        // to, so there is no announcement in this count.
        XCTAssertGreaterThan(payloads.count, 3)
        let after = await channel.tokens.available
        XCTAssertEqual(
            Int(before) - Int(after), payloads.count,
            "un jeton par charge utile, pas par message"
        )
        XCTAssertTrue(payloads.allSatisfy { $0.1.count <= SpiceAgentTransport.maximumDataBytes })
    }

    /// Two copies in flight at once must not tread on each other.
    ///
    /// The payloads are safe by construction — the queue is FIFO and a whole
    /// message goes on it in one step — but the serial is not: it is read to
    /// build a message and incremented after the write returns. Two drains at
    /// once therefore stamp the same number on two messages, and the far end is
    /// told two different things about one serial. The reassembly is checked
    /// too, so a future change that does splice payloads is caught here rather
    /// than by a guest.
    func testTwoMessagesSentAtOnceKeepTheirOwnSerialsAndStayWhole() async throws {
        let server = MemoryByteStream(inbound: guestAnnouncement([.clipboardByDemand]))
        let channel = channel(server, tokens: 1000)
        _ = try await channel.pump()

        // Long enough that each needs several payloads, and distinguishable so
        // a splice shows up as the wrong bytes rather than the wrong length.
        let first = String(repeating: "a", count: 6000)
        let second = String(repeating: "b", count: 6000)
        async let one: Void = channel.offer(first)
        async let two: Void = channel.offer(second)
        _ = try await (one, two)

        // Ask twice; each request is answered with whatever is on offer then.
        for _ in 0..<2 {
            await server.feed(serverMessage(
                SpiceWire.Message.mainAgentData,
                SpiceAgent.message(.clipboardRequest, body: SpiceAgent.requestBody(
                    .utf8Text, capabilities: SpiceAgent.capabilityWords([.clipboardByDemand])
                ))
            ))
            _ = try await channel.pump()
        }

        // Every serial must be its own. This is where two drains at once go
        // wrong: the counter is read to build a message and incremented after
        // the write returns, so a second drain entering at that suspension
        // point stamps the number the first one is already using — and a server
        // that acknowledges by serial is being told two different things about
        // the same one.
        let serials = serialsSent(await server.written)
        XCTAssertGreaterThan(serials.count, 4)
        XCTAssertEqual(
            serials.count, Set(serials).count,
            "chaque message a son propre numéro de séquence"
        )

        // Every message must come back whole. A splice leaves the reassembler
        // reading a header out of the middle of a payload, so this throws or
        // yields garbage rather than merely differing.
        let messages = try await sentAgentMessages(server)
        XCTAssertEqual(messages.map(\.0.type), [.clipboardGrab, .clipboardGrab, .clipboard, .clipboard])
        for message in messages where message.0.type == .clipboard {
            let text = try SpiceAgent.clipboard(
                message.1, capabilities: SpiceAgent.capabilityWords([.clipboardByDemand])
            ).text
            XCTAssertEqual(text?.count, 6000)
            XCTAssertEqual(Set(text ?? "").count, 1, "un seul caractère : rien n’a été entrelacé")
        }
    }

    /// What goes out is laid out the way the *guest* said it reads, not the way
    /// this client would like. Announce no selection capability and the four
    /// bytes in front of the kind must not be written; write them anyway and
    /// the guest reads the kind out of the padding.
    func testWhatIsSentUsesTheGuestsLayoutRatherThanThisClientsOwn() async throws {
        var inbound = guestAnnouncement([.clipboardByDemand])
        inbound += agentData(.clipboardRequest, body: SpiceAgent.requestBody(
            .utf8Text, capabilities: SpiceAgent.capabilityWords([.clipboardByDemand])
        ))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server)

        _ = try await channel.pump()
        try await channel.offer("sans préfixe")
        _ = try await channel.pump()

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.clipboardGrab, .clipboard])
        // The body is the kind and then the text, with nothing in front.
        XCTAssertEqual(
            Array(agent[1].1.prefix(4)), SpiceWire.u32(SpiceAgent.Kind.utf8Text.rawValue)
        )
        // And this client does announce the capability, so a body written from
        // its own would have had the prefix.
        XCTAssertTrue(SpiceAgent.clientCapabilities.contains(.clipboardSelection))
    }

    /// A copy made before the guest's agent existed is offered once it appears.
    /// Without this it is lost with no sign of it — the user copied, nothing
    /// said otherwise, and the paste comes up empty.
    func testSomethingCopiedBeforeTheAgentExistedIsOfferedWhenItArrives() async throws {
        let server = MemoryByteStream(inbound:
            serverMessage(SpiceWire.Message.mainAgentConnectedTokens, u32(20))
        )
        let channel = channel(server, tokens: 0, connected: false)

        // Copied while there was no agent: kept, and nothing sent.
        try await channel.offer("copié trop tôt")
        let earlier = try await sentAgentMessages(server)
        XCTAssertTrue(earlier.isEmpty, "aucun agent : rien ne part")

        _ = try await channel.pump()

        let agent = try await sentAgentMessages(server)
        XCTAssertEqual(agent.map(\.0.type), [.announceCapabilities, .clipboardGrab])
    }

    /// When the agent goes away, the half-received message and the queued ones
    /// go with it. Keeping the fragment would make the next agent's first
    /// message start in the middle of the last one's.
    func testAnAgentGoingAwayDropsWhatWasInFlight() async throws {
        let message = SpiceAgent.message(.clipboard, body: SpiceAgent.clipboardBody(
            .utf8Text, data: Array(String(repeating: "x", count: 3000).utf8), capabilities: []
        ))
        let pieces = SpiceAgentTransport.pieces(of: message)

        var inbound = guestAnnouncement([.clipboardByDemand])
        inbound += serverMessage(SpiceWire.Message.mainAgentData, pieces[0])
        inbound += serverMessage(SpiceWire.Message.mainAgentDisconnected, u32(0))
        let server = MemoryByteStream(inbound: inbound)
        let channel = channel(server, tokens: 0)

        let progress = try await channel.pump(limit: 3)

        XCTAssertTrue(progress.agentVanished)
        let connected = await channel.connected
        XCTAssertFalse(connected)
        let buffered = await channel.buffered
        XCTAssertEqual(buffered, 0)
        let waitingisEmpty = await channel.waiting.isEmpty
        XCTAssertTrue(waitingisEmpty)
        let capabilitiesisEmpty = await channel.capabilities.isEmpty
        XCTAssertTrue(capabilitiesisEmpty)
    }
}
