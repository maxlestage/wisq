import XCTest
@testable import WisqRemote

/// The guest agent's clipboard messages.
///
/// The reason this file is worth its length: **these structures do not have one
/// layout.** Two optional prefixes appear or vanish with the capabilities the
/// two ends agreed, so one message type has four possible shapes. A client that
/// assumes one works against the server it was written against and misreads
/// every clipboard message from the next.
final class SpiceAgentTests: XCTestCase {
    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }

    private var withSelection: [UInt32] {
        SpiceAgent.capabilityWords([.clipboard, .clipboardByDemand, .clipboardSelection])
    }
    private var withoutSelection: [UInt32] {
        SpiceAgent.capabilityWords([.clipboard, .clipboardByDemand])
    }
    private var withSelectionAndSerial: [UInt32] {
        SpiceAgent.capabilityWords([.clipboardSelection, .clipboardGrabSerial])
    }

    // MARK: - The prefix that is four bytes, not one

    /// One byte of selection and three reserved, padded to a word. Read as a
    /// single byte, every field after it shifts by three — and the payload
    /// still decodes into *something*, which is why this needs pinning.
    func testTheSelectionPrefixIsFourBytesRatherThanOne() throws {
        XCTAssertEqual(SpiceAgent.selectionPrefixBytes(withSelection), 4)
        XCTAssertEqual(SpiceAgent.selectionPrefixBytes(withoutSelection), 0)

        let body = [UInt8(1), 0, 0, 0] + u32(SpiceAgent.Kind.utf8Text.rawValue)
            + Array("bonjour".utf8)
        let clipboard = try SpiceAgent.clipboard(body, capabilities: withSelection)
        XCTAssertEqual(clipboard.selection, .primary)
        XCTAssertEqual(clipboard.kind, .utf8Text)
        XCTAssertEqual(clipboard.text, "bonjour")
    }

    /// Without the capability there is no prefix at all, and the type is the
    /// very first field.
    func testWithoutTheCapabilityThereIsNoPrefixAtAll() throws {
        let body = u32(SpiceAgent.Kind.utf8Text.rawValue) + Array("salut".utf8)
        let clipboard = try SpiceAgent.clipboard(body, capabilities: withoutSelection)
        XCTAssertEqual(clipboard.kind, .utf8Text)
        XCTAssertEqual(clipboard.text, "salut")
        XCTAssertEqual(clipboard.selection, .clipboard, "la seule qu'un téléphone connaisse")
    }

    /// The same bytes read under the two agreements give different answers.
    /// That is the whole hazard in one assertion.
    func testTheSameBytesMeanDifferentThingsUnderTheTwoAgreements() throws {
        let body = [UInt8(0), 0, 0, 0] + u32(SpiceAgent.Kind.utf8Text.rawValue)
            + Array("texte".utf8)

        let right = try SpiceAgent.clipboard(body, capabilities: withSelection)
        let wrong = try SpiceAgent.clipboard(body, capabilities: withoutSelection)

        XCTAssertEqual(right.text, "texte")
        XCTAssertNotEqual(wrong.kind, .utf8Text, "lu sans le préfixe, le type est le mauvais champ")
        XCTAssertNotEqual(wrong.text, "texte")
    }

    /// What goes out matches what comes back, under either agreement.
    func testWhatIsWrittenIsWhatIsRead() throws {
        for caps in [withSelection, withoutSelection] {
            let body = SpiceAgent.clipboardBody(
                .utf8Text, data: Array("aller-retour".utf8),
                selection: .clipboard, capabilities: caps
            )
            let back = try SpiceAgent.clipboard(body, capabilities: caps)
            XCTAssertEqual(back.text, "aller-retour")
        }
    }

    // MARK: - Grab, with its own extra prefix

    /// The grab message carries a serial too, under a *different* capability.
    /// So it alone has four shapes rather than two.
    func testTheGrabMessageHasItsOwnOptionalSerial() throws {
        let kinds = u32(SpiceAgent.Kind.utf8Text.rawValue) + u32(SpiceAgent.Kind.imagePNG.rawValue)

        let withBoth = try SpiceAgent.grab(
            [UInt8(0), 0, 0, 0] + u32(42) + kinds, capabilities: withSelectionAndSerial
        )
        XCTAssertEqual(withBoth.serial, 42)
        XCTAssertEqual(withBoth.kinds, [.utf8Text, .imagePNG])

        let selectionOnly = try SpiceAgent.grab(
            [UInt8(0), 0, 0, 0] + kinds, capabilities: withSelection
        )
        XCTAssertNil(selectionOnly.serial)
        XCTAssertEqual(selectionOnly.kinds, [.utf8Text, .imagePNG])

        let neither = try SpiceAgent.grab(kinds, capabilities: withoutSelection)
        XCTAssertNil(neither.serial)
        XCTAssertEqual(neither.kinds, [.utf8Text, .imagePNG])
    }

    /// The list of offered kinds is bounded by the message's own length, not by
    /// a count inside it, so nothing is ever sized from a number a guest chose.
    func testTheOfferedKindsAreBoundedByTheMessageRatherThanByACount() throws {
        let grab = try SpiceAgent.grab(
            u32(1) + u32(2) + [0xFF, 0xFF], capabilities: withoutSelection
        )
        XCTAssertEqual(grab.kinds, [.utf8Text, .imagePNG], "les deux octets en trop sont ignorés")
    }

    /// A kind this client cannot render is still carried. The data is the
    /// guest's clipboard; a client that cannot show it should say so rather
    /// than drop the connection.
    func testAnUnknownKindIsCarriedRatherThanRefused() throws {
        let body = u32(999) + [1, 2, 3]
        let clipboard = try SpiceAgent.clipboard(body, capabilities: withoutSelection)
        XCTAssertEqual(clipboard.kind, .none)
        XCTAssertEqual(clipboard.data, [1, 2, 3])
        XCTAssertNil(clipboard.text, "et ne prétend pas être du texte")
    }

    // MARK: - Text

    /// Some agents put the terminating NUL in the payload. It is not part of
    /// the text, and pasting it leaves an invisible character at the end of
    /// every paste.
    func testATrailingNulIsNotPartOfTheText() throws {
        let body = u32(SpiceAgent.Kind.utf8Text.rawValue) + Array("fin".utf8) + [0]
        XCTAssertEqual(try SpiceAgent.clipboard(body, capabilities: withoutSelection).text, "fin")
    }

    /// Bytes that are not UTF-8 yield nothing rather than replacement
    /// characters. Pasting `\u{FFFD}\u{FFFD}\u{FFFD}` into a document is worse
    /// than pasting nothing.
    func testTextThatIsNotUTF8YieldsNothingRatherThanReplacementCharacters() throws {
        let body = u32(SpiceAgent.Kind.utf8Text.rawValue) + [0xFF, 0xFE, 0xFD]
        let clipboard = try SpiceAgent.clipboard(body, capabilities: withoutSelection)
        XCTAssertEqual(clipboard.kind, .utf8Text)
        XCTAssertNil(clipboard.text)
        XCTAssertEqual(clipboard.data, [0xFF, 0xFE, 0xFD], "les octets restent disponibles")
    }

    // MARK: - The envelope

    func testTheMessageEnvelopeIsProtocolTypeOpaqueSize() throws {
        let body: [UInt8] = [1, 2, 3, 4, 5]
        let message = SpiceAgent.message(.clipboard, body: body)
        XCTAssertEqual(message.count, 4 + 4 + 8 + 4 + body.count)

        var reader = try SpiceWire.Reader(message, from: 0)
        let header = try SpiceAgent.header(from: &reader)
        XCTAssertEqual(header.type, .clipboard)
        XCTAssertEqual(header.size, UInt32(body.count))
        XCTAssertEqual(reader.rest(), body)
    }

    /// Anything announcing another protocol version is not one of these,
    /// whatever else it looks like.
    func testAMessageAnnouncingAnotherProtocolIsRefused() throws {
        var wrong = SpiceAgent.message(.clipboard, body: [])
        wrong[0] = 2
        var reader = try SpiceWire.Reader(wrong, from: 0)
        XCTAssertThrowsError(try SpiceAgent.header(from: &reader)) { error in
            XCTAssertEqual(error as? SpiceAgent.Failure, .notAnAgentMessage(protocolVersion: 2))
        }
    }

    func testAnUnknownMessageTypeIsNamedRatherThanGuessed() throws {
        var message = SpiceWire.u32(SpiceAgent.protocolVersion)
        message += SpiceWire.u32(4242) + SpiceWire.u64(0) + SpiceWire.u32(0)
        var reader = try SpiceWire.Reader(message, from: 0)
        XCTAssertThrowsError(try SpiceAgent.header(from: &reader)) { error in
            XCTAssertEqual(error as? SpiceAgent.Failure, .unknownMessage(4242))
        }
    }

    /// Capabilities are bit positions, the same trap as the display channel's.
    func testACapabilityIsABitPositionRatherThanAValue() {
        XCTAssertTrue(SpiceAgent.supports(.clipboardSelection, in: [0b0100_0000]))
        XCTAssertFalse(SpiceAgent.supports(.clipboardSelection, in: [6]))
        // The grab serial is bit 17, so it lives in the first word but past the
        // sixteen a careless mask would cover.
        let serial = SpiceAgent.capabilityWords([.clipboardGrabSerial])
        XCTAssertEqual(serial, [1 << 17])
        XCTAssertTrue(SpiceAgent.supports(.clipboardGrabSerial, in: serial))
        XCTAssertFalse(SpiceAgent.supports(.clipboardSelection, in: serial))
    }
}
