import Foundation
import WisqNet
import XCTest
@testable import WisqRemote

/// The SPICE handshake and main channel, driven against a scripted server.
///
/// No socket and no RSA. The ticket encryptor is a closure precisely so this
/// can run on the runner that costs nothing: SPICE encrypts its ticket with
/// RSA, which does not exist on Linux, and calling it directly would have put
/// the whole sequence — the order, the capability negotiation, the framing,
/// every refusal — behind a platform CI does not have.
///
/// What a stub cannot check is the encryption itself, and this file does not
/// pretend otherwise. What it checks is everything around it, which is where
/// the bugs are.
final class SpiceLinkTests: XCTestCase {
    /// A ticket encryptor that encrypts nothing and records what it was asked.
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var password: String?
        private(set) var publicKey: [UInt8]?
        var refuse = false

        var encryptor: SpiceTicketEncryptor {
            { [self] password, key in
                lock.lock()
                defer { lock.unlock() }
                self.password = password
                self.publicKey = key
                if refuse { throw SpiceError.ticketUnavailable }
                return Data(repeating: 0xAB, count: 128)
            }
        }
    }

    private func linkReply(
        error: UInt32 = 0, commonCaps: [UInt32] = [], channelCaps: [UInt32] = []
    ) -> Data {
        var body = SpiceWire.u32(error)
        body += (0..<162).map { UInt8($0 % 256) }
        body += SpiceWire.u32(UInt32(commonCaps.count))
        body += SpiceWire.u32(UInt32(channelCaps.count))
        body += SpiceWire.u32(178)
        for capability in commonCaps + channelCaps { body += SpiceWire.u32(capability) }
        let header = Array("REDQ".utf8) + SpiceWire.u32(2) + SpiceWire.u32(2)
            + SpiceWire.u32(UInt32(body.count))
        return Data(header + body)
    }

    // MARK: - The link

    /// The full exchange, in the order the protocol fixes: link message, link
    /// reply, ticket, result. A server asked for a ticket before it has offered
    /// its key has nothing to decrypt with.
    func testTheLinkSendsItsMessageThenItsTicketAndReadsTheResult() async throws {
        let ticket = Ticket()
        let server = MemoryByteStream(
            inbound: linkReply(commonCaps: [1], channelCaps: [2, 3]) + Data(SpiceWire.u32(0))
        )
        let link = SpiceLink(stream: server, encryptTicket: ticket.encryptor)

        let outcome = try await link.open(channel: .main, password: "secret")
        XCTAssertEqual(outcome.commonCaps, [1])
        XCTAssertEqual(outcome.channelCaps, [2, 3])

        let written = await server.written
        XCTAssertEqual(Array(written.prefix(4)), Array("REDQ".utf8))
        XCTAssertEqual(written[20], SpiceWire.Channel.main.rawValue)
        XCTAssertEqual(
            written.count, 16 + 18 + 128,
            "message de lien puis ticket, et rien d'autre"
        )
        XCTAssertEqual(
            Array(written.suffix(128)), [UInt8](repeating: 0xAB, count: 128),
            "le ticket part après la réponse, pas avant"
        )
    }

    /// The encryptor is handed the server's own key, not a copy of something
    /// else. Getting this wrong produces a ticket no server can read.
    func testTheTicketIsBuiltFromTheKeyTheServerSent() async throws {
        let ticket = Ticket()
        let server = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(0)))
        _ = try await SpiceLink(stream: server, encryptTicket: ticket.encryptor)
            .open(channel: .main, password: "hunter2")

        XCTAssertEqual(ticket.password, "hunter2")
        XCTAssertEqual(ticket.publicKey?.count, 162)
        XCTAssertEqual(ticket.publicKey?.prefix(4).map { $0 }, [0, 1, 2, 3])
    }

    /// A refusal in the link reply stops the exchange there. Sending a ticket
    /// to a server that has already said no is noise, and the reason it gave is
    /// the thing worth keeping.
    func testARefusedLinkStopsBeforeTheTicketAndKeepsTheReason() async throws {
        for (code, expected) in [
            (UInt32(4), SpiceWire.LinkError.versionMismatch),
            (7, .permissionDenied),
            (9, .channelNotAvailable),
        ] {
            let ticket = Ticket()
            let server = MemoryByteStream(inbound: linkReply(error: code))
            do {
                _ = try await SpiceLink(stream: server, encryptTicket: ticket.encryptor)
                    .open(channel: .main, password: "x")
                XCTFail("le lien refusé doit lever")
            } catch {
                XCTAssertEqual(error as? SpiceError, .refused(expected))
            }
            XCTAssertNil(ticket.password, "aucun ticket ne doit partir après un refus")
            let written = await server.written
            XCTAssertEqual(written.count, 16 + 18, "seulement le message de lien")
        }
    }

    /// The password can be right and the ticket still refused — a wrong one is
    /// reported on the result word, after the ticket has gone.
    func testAWrongPasswordIsReportedOnTheResultWord() async throws {
        let ticket = Ticket()
        let server = MemoryByteStream(inbound: linkReply() + Data(SpiceWire.u32(7)))
        do {
            _ = try await SpiceLink(stream: server, encryptTicket: ticket.encryptor)
                .open(channel: .main, password: "faux")
            XCTFail("un mot de passe refusé doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .refused(.permissionDenied))
        }
        XCTAssertEqual(ticket.password, "faux", "le ticket est bien parti d'abord")
    }

    /// On a platform with no RSA the failure is named, not disguised as a
    /// protocol error. This is the case the Linux build is actually in.
    func testAPlatformWithoutRSASaysSoRatherThanSendingRubbish() async throws {
        let ticket = Ticket()
        ticket.refuse = true
        let server = MemoryByteStream(inbound: linkReply())
        do {
            _ = try await SpiceLink(stream: server, encryptTicket: ticket.encryptor)
                .open(channel: .main, password: "x")
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .ticketUnavailable)
        }
        let written = await server.written
        XCTAssertEqual(written.count, 16 + 18, "rien n'est envoyé à la place du ticket")
    }

    /// And the shipped encryptor is the one that says it on Linux, rather than
    /// silently returning something a server would reject.
    func testTheShippedEncryptorRefusesWhereThereIsNoRSA() throws {
        #if canImport(Security)
        throw XCTSkip("Security est disponible ici : ce cas est celui de Linux")
        #else
        XCTAssertThrowsError(
            try SpiceTicket.platform("x", (0..<162).map { UInt8($0 % 256) })
        ) { error in
            XCTAssertEqual(error as? SpiceError, .ticketUnavailable)
        }
        #endif
    }

    /// A server on the wrong protocol is refused on its first four bytes,
    /// before anything is decoded on the strength of them.
    func testAServerThatIsNotSpiceIsRefusedAtTheHandshake() async throws {
        let notSpice = Data(Array("RFB 003.008\n".utf8) + [UInt8](repeating: 0, count: 8))
        let server = MemoryByteStream(inbound: notSpice)
        do {
            _ = try await SpiceLink(stream: server, encryptTicket: Ticket().encryptor)
                .open(channel: .main, password: "x")
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .notSpice)
        }
    }

    // MARK: - The main channel

    private func message(_ type: UInt16, _ payload: [UInt8] = []) -> Data {
        SpiceWire.message(type, serial: 0, payload: Data(payload))
    }

    private var mainInitPayload: [UInt8] {
        var body: [UInt8] = []
        for value in [UInt32(42), 1, 3, 1, 1, 10, 0, 4096] { body += SpiceWire.u32(value) }
        return body
    }

    func testTheMainChannelReadsTheSessionAndItsChannels() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(
                    SpiceWire.Message.mainChannelsList,
                    SpiceWire.u32(2) + [2, 0, 3, 0]
                )
        )
        let session = try await SpiceMainChannel(stream: server).bringUp()
        XCTAssertEqual(session.initialisation.sessionID, 42)
        XCTAssertTrue(session.initialisation.agentConnected)
        XCTAssertEqual(
            session.channels,
            [SpiceWire.ChannelID(type: 2, id: 0), SpiceWire.ChannelID(type: 3, id: 0)]
        )
    }

    /// The server does not volunteer its channel list; it has to be asked. A
    /// client that never asks waits forever against a correct server.
    func testTheChannelListIsAskedForRatherThanWaitedFor() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(0))
        )
        _ = try await SpiceMainChannel(stream: server).bringUp()

        let written = await server.written
        let header = try SpiceWire.decodeDataHeader(written)
        XCTAssertEqual(header.type, SpiceWire.ClientMessage.attachChannels)
        XCTAssertEqual(header.size, 0)
        XCTAssertEqual(header.serial, 1, "les messages client sont numérotés depuis un")
    }

    /// A ping has to come back exactly, or the server's round-trip figure is
    /// nonsense and it may conclude the client is gone.
    func testAPingIsAnsweredExactlyAndInSequence() async throws {
        let ping = SpiceWire.u32(99) + SpiceWire.u64(0xDEAD_BEEF)
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(SpiceWire.Message.ping, ping)
                + message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(0))
        )
        _ = try await SpiceMainChannel(stream: server).bringUp()

        let written = await server.written
        let pong = written.dropFirst(SpiceWire.dataHeaderBytes)
        let header = try SpiceWire.decodeDataHeader(Data(pong))
        XCTAssertEqual(header.type, SpiceWire.ClientMessage.pong)
        XCTAssertEqual(header.serial, 2, "après la demande de canaux")
        XCTAssertEqual(Array(pong.dropFirst(SpiceWire.dataHeaderBytes)), ping)
    }

    /// The acknowledgement generation is echoed: it is how a server tells an
    /// acknowledgement for this window from one for the last.
    func testAnAcknowledgementWindowIsAnsweredWithItsOwnGeneration() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(SpiceWire.Message.setAck, SpiceWire.u32(7) + SpiceWire.u32(20))
                + message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(0))
        )
        _ = try await SpiceMainChannel(stream: server).bringUp()

        let written = await server.written
        let sync = Data(written.dropFirst(SpiceWire.dataHeaderBytes))
        XCTAssertEqual(
            try SpiceWire.decodeDataHeader(sync).type, SpiceWire.ClientMessage.ackSync
        )
        XCTAssertEqual(
            Array(sync.dropFirst(SpiceWire.dataHeaderBytes)), SpiceWire.u32(7)
        )
    }

    /// A notice is written for a person, so it survives the bring-up rather
    /// than being counted and dropped.
    func testANoticeIsCarriedOutRatherThanDropped() async throws {
        let text = Array("le disque est plein".utf8)
        var notice = SpiceWire.u64(1)
        notice += SpiceWire.u32(2) + SpiceWire.u32(0) + SpiceWire.u32(0)
        notice += SpiceWire.u32(UInt32(text.count)) + text

        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(SpiceWire.Message.notify, notice)
                + message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(0))
        )
        let session = try await SpiceMainChannel(stream: server).bringUp()
        XCTAssertEqual(session.notices.map(\.text), ["le disque est plein"])
    }

    /// A message this client does not know must not desynchronise the stream.
    /// Its payload is consumed even though nothing is done with it — that, and
    /// not the handling, is what keeps the next header at a header boundary.
    func testAnUnknownMessageIsSteppedOverWithoutLosingThePlace() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(9999, [1, 2, 3, 4, 5, 6, 7])
                + message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(1) + [4, 0])
        )
        let session = try await SpiceMainChannel(stream: server).bringUp()
        XCTAssertEqual(session.channels, [SpiceWire.ChannelID(type: 4, id: 0)])
    }

    /// A server that says goodbye is not waited on.
    func testAServerThatDisconnectsEndsTheBringUp() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload)
                + message(SpiceWire.Message.disconnecting)
        )
        do {
            _ = try await SpiceMainChannel(stream: server).bringUp()
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .refused(.error))
        }
    }

    /// A size field is an allocation instruction from the far end. A megabyte
    /// during bring-up is a server to stop talking to, not to accommodate.
    func testAnAbsurdMessageSizeIsRefusedRatherThanAllocated() async throws {
        let huge = SpiceWire.encode(
            SpiceWire.DataHeader(serial: 0, type: SpiceWire.Message.notify, size: 1 << 30)
        )
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainInit, mainInitPayload) + huge
        )
        do {
            _ = try await SpiceMainChannel(stream: server).bringUp()
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }

    /// Which half never arrived says something different: one means the session
    /// never started, the other that it started and stalled.
    func testRunningOutOfPatienceSaysWhichHalfNeverArrived() async throws {
        var onlyPings = Data()
        for _ in 0..<10 {
            onlyPings += message(
                SpiceWire.Message.ping, SpiceWire.u32(1) + SpiceWire.u64(1)
            )
        }
        do {
            _ = try await SpiceMainChannel(stream: MemoryByteStream(inbound: onlyPings))
                .bringUp(limit: 10)
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .noMainInit)
        }

        var thenSilence = message(SpiceWire.Message.mainInit, mainInitPayload)
        for _ in 0..<9 {
            thenSilence += message(
                SpiceWire.Message.ping, SpiceWire.u32(1) + SpiceWire.u64(1)
            )
        }
        do {
            _ = try await SpiceMainChannel(stream: MemoryByteStream(inbound: thenSilence))
                .bringUp(limit: 10)
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .noChannelList)
        }
    }

    /// A channel list before the session was initialised is out of order, and
    /// answering it would report a session that was never described.
    func testAChannelListBeforeTheSessionIsRefused() async throws {
        let server = MemoryByteStream(
            inbound: message(SpiceWire.Message.mainChannelsList, SpiceWire.u32(0))
        )
        do {
            _ = try await SpiceMainChannel(stream: server).bringUp()
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }
}
