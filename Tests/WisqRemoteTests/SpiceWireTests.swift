import XCTest
@testable import WisqRemote

/// The SPICE framing, checked without a server.
///
/// Every rule here is one a real server enforces silently: get the endianness
/// backwards, the caps offset wrong, or the packed layout off by a byte, and
/// the connection is refused with no explanation of which byte was wrong. So
/// the bytes are asserted directly, against the layout the protocol specifies,
/// rather than against whatever this code happens to produce.
final class SpiceWireTests: XCTestCase {
    // MARK: - Numbers

    /// Little-endian, which is the one thing most likely to be wrong in a file
    /// sitting next to a big-endian protocol.
    func testNumbersGoOutLittleEndianUnlikeTheRFBCodeNextDoor() {
        XCTAssertEqual(SpiceWire.u16(0x1234), [0x34, 0x12])
        XCTAssertEqual(SpiceWire.u32(0x1234_5678), [0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(
            SpiceWire.u64(0x0102_0304_0506_0708),
            [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        )
    }

    func testNumbersComeBackInTheOrderTheyWentOut() throws {
        var reader = SpiceWire.Reader(
            Data(SpiceWire.u16(0xBEEF) + SpiceWire.u32(0xDEAD_BEEF)
                + SpiceWire.u64(0x0BAD_C0FF_EE00_1234))
        )
        XCTAssertEqual(try reader.u16(), 0xBEEF)
        XCTAssertEqual(try reader.u32(), 0xDEAD_BEEF)
        XCTAssertEqual(try reader.u64(), 0x0BAD_C0FF_EE00_1234)
        XCTAssertEqual(reader.remaining, 0)
    }

    /// A reader that runs off its end has to throw, not read whatever follows.
    func testReadingPastTheEndIsRefusedAtEveryWidth() {
        for width in 1...8 {
            var reader = SpiceWire.Reader(Data(repeating: 0, count: width - 1))
            XCTAssertThrowsError(try reader.bytes(width), "largeur \(width)")
        }
        var reader = SpiceWire.Reader(Data([1, 2, 3]))
        XCTAssertThrowsError(try reader.u32())
    }

    // MARK: - Link

    /// The first sixteen bytes a server ever sees. Asserted literally: this is
    /// the handshake, and a server that dislikes it says only "invalid data".
    func testTheLinkRequestOpensWithTheMagicAndTheVersion() {
        let request = SpiceWire.linkRequest(connectionID: 0, channel: .main)
        XCTAssertEqual(Array(request.prefix(4)), Array("REDQ".utf8))
        XCTAssertEqual(Array(request[4..<8]), [2, 0, 0, 0], "majeure 2, petit-boutiste")
        XCTAssertEqual(Array(request[8..<12]), [2, 0, 0, 0], "mineure 2")
        XCTAssertEqual(
            Array(request[12..<16]), [18, 0, 0, 0],
            "la taille annoncée exclut l'en-tête et vaut 18 sans capacités"
        )
        XCTAssertEqual(request.count, 16 + 18)
    }

    func testTheLinkRequestNamesItsChannel() {
        for channel in [SpiceWire.Channel.main, .display, .inputs, .cursor] {
            let request = SpiceWire.linkRequest(connectionID: 7, channel: channel, channelID: 3)
            XCTAssertEqual(Array(request[16..<20]), [7, 0, 0, 0], "identifiant de connexion")
            XCTAssertEqual(request[20], channel.rawValue)
            XCTAssertEqual(request[21], 3)
        }
    }

    /// The capability offset is counted from the start of the link message, not
    /// of the packet. Sixteen bytes of header is exactly the mistake this pins.
    func testCapabilitiesAreCountedAndPlacedWhereTheProtocolSaysTheyAre() {
        let request = SpiceWire.linkRequest(
            connectionID: 0, channel: .main, commonCaps: [0xAA], channelCaps: [0xBB, 0xCC]
        )
        XCTAssertEqual(Array(request[22..<26]), [1, 0, 0, 0], "une capacité commune")
        XCTAssertEqual(Array(request[26..<30]), [2, 0, 0, 0], "deux capacités de canal")
        XCTAssertEqual(
            Array(request[30..<34]), [18, 0, 0, 0],
            "décalage compté depuis le début du message, pas du paquet"
        )
        XCTAssertEqual(Array(request[34..<38]), [0xAA, 0, 0, 0])
        XCTAssertEqual(Array(request[38..<42]), [0xBB, 0, 0, 0])
        XCTAssertEqual(Array(request[42..<46]), [0xCC, 0, 0, 0])
        XCTAssertEqual(Array(request[12..<16]), [18 + 12, 0, 0, 0], "taille annoncée")
    }

    private func linkReplyHeader(size: UInt32 = 178) -> Data {
        Data(Array("REDQ".utf8) + SpiceWire.u32(2) + SpiceWire.u32(2) + SpiceWire.u32(size))
    }

    func testAServerThatIsNotSpiceIsRefusedOnItsFirstFourBytes() {
        let notSpice = Data(Array("RFB ".utf8) + SpiceWire.u32(2) + SpiceWire.u32(2)
            + SpiceWire.u32(178))
        XCTAssertThrowsError(try SpiceWire.decodeLinkHeader(notSpice)) { error in
            XCTAssertEqual(error as? SpiceError, .notSpice)
        }
    }

    /// A future major version is refused rather than guessed at: the layouts
    /// below it are not promised to hold.
    func testADifferentMajorVersionIsRefusedRatherThanAttempted() {
        let future = Data(Array("REDQ".utf8) + SpiceWire.u32(3) + SpiceWire.u32(0)
            + SpiceWire.u32(178))
        XCTAssertThrowsError(try SpiceWire.decodeLinkHeader(future)) { error in
            XCTAssertEqual(error as? SpiceError, .versionMismatch(major: 3, minor: 0))
        }
    }

    /// A size field is an allocation instruction. One that is absurd in either
    /// direction is refused before it becomes one.
    func testAnAbsurdLinkSizeIsRefusedBeforeItBecomesAnAllocation() {
        for size in [UInt32(0), 177, 4097, .max] {
            XCTAssertThrowsError(
                try SpiceWire.decodeLinkHeader(linkReplyHeader(size: size)), "taille \(size)"
            )
        }
        XCTAssertEqual(try SpiceWire.decodeLinkHeader(linkReplyHeader(size: 178)), 178)
        XCTAssertEqual(try SpiceWire.decodeLinkHeader(linkReplyHeader(size: 4096)), 4096)
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
        return Data(body)
    }

    func testTheLinkReplyYieldsItsKeyAndCapabilities() throws {
        let reply = try SpiceWire.decodeLinkReply(
            linkReply(commonCaps: [0x11], channelCaps: [0x22, 0x33])
        )
        XCTAssertEqual(reply.error, .ok)
        XCTAssertEqual(reply.publicKey.count, 162, "la clé est un champ de largeur fixe")
        XCTAssertEqual(reply.publicKey.first, 0)
        XCTAssertEqual(reply.commonCaps, [0x11])
        XCTAssertEqual(reply.channelCaps, [0x22, 0x33])
    }

    /// Each refusal means something different to the person holding the phone.
    /// Flattening them to "failed" throws that away.
    func testEveryRefusalKeepsItsOwnMeaning() throws {
        let expected: [UInt32: SpiceWire.LinkError] = [
            1: .error, 2: .invalidMagic, 3: .invalidData, 4: .versionMismatch,
            5: .needSecured, 6: .needUnsecured, 7: .permissionDenied,
            8: .badConnectionID, 9: .channelNotAvailable,
        ]
        for (code, wanted) in expected {
            XCTAssertEqual(try SpiceWire.decodeLinkReply(linkReply(error: code)).error, wanted)
        }
        XCTAssertThrowsError(try SpiceWire.decodeLinkReply(linkReply(error: 99))) { error in
            XCTAssertEqual(error as? SpiceError, .invalidData)
        }
    }

    /// Every truncation of a link reply has to be refused, not partially read.
    func testEveryTruncatedLinkReplyIsRefused() {
        let whole = linkReply(commonCaps: [1], channelCaps: [2])
        for length in 0..<whole.count {
            XCTAssertThrowsError(
                try SpiceWire.decodeLinkReply(whole.prefix(length)), "tronqué à \(length)"
            )
        }
        XCTAssertNoThrow(try SpiceWire.decodeLinkReply(whole))
    }

    // MARK: - Messages

    func testTheDataHeaderIsEighteenBytesAndSurvivesARoundTrip() throws {
        let header = SpiceWire.DataHeader(serial: 0x0102_0304_0506_0708, type: 103, size: 32)
        let encoded = SpiceWire.encode(header)
        XCTAssertEqual(encoded.count, 18)
        XCTAssertEqual(Array(encoded.prefix(8)), [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Array(encoded[8..<10]), [103, 0])
        XCTAssertEqual(try SpiceWire.decodeDataHeader(encoded), header)
    }

    func testAMessageAnnouncesItsOwnPayloadLength() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let message = SpiceWire.message(SpiceWire.ClientMessage.pong, serial: 9, payload: payload)
        let header = try SpiceWire.decodeDataHeader(message)
        XCTAssertEqual(header.type, 3)
        XCTAssertEqual(header.serial, 9)
        XCTAssertEqual(header.size, 5)
        XCTAssertEqual(message.count, 18 + 5)
    }

    func testMainInitIsReadFieldForField() throws {
        var body: [UInt8] = []
        for value in [UInt32(42), 2, 3, 1, 1, 10, 999, 4096] { body += SpiceWire.u32(value) }
        let initialise = try SpiceWire.decodeMainInit(Data(body))
        XCTAssertEqual(initialise.sessionID, 42)
        XCTAssertEqual(initialise.displayChannelsHint, 2)
        XCTAssertEqual(initialise.supportedMouseModes, 3)
        XCTAssertEqual(initialise.currentMouseMode, 1)
        XCTAssertTrue(initialise.agentConnected)
        XCTAssertEqual(initialise.agentTokens, 10)
        XCTAssertEqual(initialise.multiMediaTime, 999)
        XCTAssertEqual(initialise.ramHint, 4096)
    }

    func testTheChannelListIsRead() throws {
        let body = Data(SpiceWire.u32(3) + [2, 0, 3, 0, 4, 1])
        XCTAssertEqual(
            try SpiceWire.decodeChannelsList(body),
            [
                SpiceWire.ChannelID(type: 2, id: 0),
                SpiceWire.ChannelID(type: 3, id: 0),
                SpiceWire.ChannelID(type: 4, id: 1),
            ]
        )
    }

    /// A count is the server's word; the payload is what arrived.
    func testAChannelListThatPromisesMoreThanItCarriesIsRefused() {
        let lying = Data(SpiceWire.u32(9) + [2, 0, 3, 0])
        XCTAssertThrowsError(try SpiceWire.decodeChannelsList(lying)) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }

    /// A server claiming four billion channels is refused promptly, without
    /// an array ever being sized from its number.
    ///
    /// The decoder appends rather than mapping over `0..<count`, so nothing is
    /// reserved from a number the server chose. That is a property of the
    /// shape, not of a bound — on Linux the reservation would be virtual and
    /// cost nothing, so this assertion could not tell the two apart. It is here
    /// to notice if the loop ever turns back into a `map`.
    func testAnAbsurdChannelCountIsRefusedWithoutSizingAnArrayFromIt() {
        let absurd = Data(SpiceWire.u32(.max) + [2, 0])
        let started = Date()
        XCTAssertThrowsError(try SpiceWire.decodeChannelsList(absurd)) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1,
            "le refus doit venir du compteur, pas d'une tentative d'allocation"
        )
    }

    /// A pong has to echo the ping exactly, or the server's round-trip figure
    /// is nonsense and it may decide the client is gone.
    func testAPongEchoesThePingExactly() throws {
        let body = Data(SpiceWire.u32(77) + SpiceWire.u64(0x0011_2233_4455_6677))
        let ping = try SpiceWire.decodePing(body)
        XCTAssertEqual(ping.id, 77)
        XCTAssertEqual(ping.timestamp, 0x0011_2233_4455_6677)
        XCTAssertEqual(SpiceWire.encodePong(ping), body)
    }

    func testSetAckIsRead() throws {
        let ack = try SpiceWire.decodeSetAck(Data(SpiceWire.u32(5) + SpiceWire.u32(20)))
        XCTAssertEqual(ack, SpiceWire.SetAck(generation: 5, window: 20))
    }

    /// A notice carries text meant for a person, so it is decoded rather than
    /// counted and dropped.
    func testANoticeKeepsItsText() throws {
        let text = Array("disque plein".utf8)
        var body = SpiceWire.u64(1234)
        body += SpiceWire.u32(2)
        body += SpiceWire.u32(0)
        body += SpiceWire.u32(0)
        body += SpiceWire.u32(UInt32(text.count))
        body += text
        let notice = try SpiceWire.decodeNotify(Data(body))
        XCTAssertEqual(notice.severity, 2)
        XCTAssertEqual(notice.text, "disque plein")
    }

    func testATruncatedNoticeIsRefused() {
        var body = SpiceWire.u64(1234)
        body += SpiceWire.u32(2) + SpiceWire.u32(0) + SpiceWire.u32(0)
        body += SpiceWire.u32(50)
        body += Array("court".utf8)
        XCTAssertThrowsError(try SpiceWire.decodeNotify(Data(body))) { error in
            XCTAssertEqual(error as? SpiceError, .truncated)
        }
    }
}
