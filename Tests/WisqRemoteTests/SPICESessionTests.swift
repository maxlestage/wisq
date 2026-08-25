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

    private func channelsList(withInputs: Bool = false) -> Data {
        var body = u32(withInputs ? 2 : 1)
        body += [SpiceWire.Channel.display.rawValue, 0]
        if withInputs { body += [SpiceWire.Channel.inputs.rawValue, 0] }
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
    private actor Sockets {
        private var queued: [MemoryByteStream]
        private(set) var handedOut: [MemoryByteStream] = []

        init(_ streams: [MemoryByteStream]) { queued = streams }

        func next() throws -> MemoryByteStream {
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

    private func waitFor(
        _ session: SPICESession, until match: @escaping @Sendable (SessionEvent) -> Bool
    ) async -> SessionEvent? {
        for await event in session.events where match(event) { return event }
        return nil
    }

    // MARK: - The shape

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
        XCTAssertEqual(session.framebuffer.width, 64)

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
}
