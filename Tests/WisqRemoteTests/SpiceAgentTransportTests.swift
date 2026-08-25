import XCTest
@testable import WisqRemote

/// Getting agent messages across the main channel.
///
/// The thing worth testing is the **reassembly**. One agent message can arrive
/// across several `AGENT_DATA` messages, split at any point including inside
/// the header, because the server forwards whatever the guest's virtio pipe
/// handed it. A reader that treats each `AGENT_DATA` as a whole message works
/// perfectly for short text and silently truncates long text — the failure that
/// only appears when somebody copies a real document.
final class SpiceAgentTransportTests: XCTestCase {
    private func clipboardMessage(_ text: String) -> [UInt8] {
        SpiceAgent.message(
            .clipboard,
            body: SpiceAgent.clipboardBody(
                .utf8Text, data: Array(text.utf8), capabilities: []
            )
        )
    }

    // MARK: - Reassembly

    /// A message that arrives whole in one chunk.
    func testAMessageThatFitsInOneChunkComesOutWhole() throws {
        var reassembler = SpiceAgentTransport.Reassembler()
        let finished = try reassembler.accept(clipboardMessage("court"))

        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.0.type, .clipboard)
        XCTAssertEqual(
            try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, "court"
        )
        XCTAssertEqual(reassembler.buffered, 0, "rien ne doit rester en attente")
    }

    /// The one that matters. Split a message every way and it must come back
    /// identical each time — including splits that fall inside the header,
    /// where a careless reader would read a size out of the bytes after it.
    func testAMessageSplitAtEveryPossiblePointComesBackIdentical() throws {
        let text = String(repeating: "presse-papiers ", count: 40)
        let message = clipboardMessage(text)

        for cut in 1..<message.count {
            var reassembler = SpiceAgentTransport.Reassembler()
            var finished = try reassembler.accept(Array(message[0..<cut]))
            XCTAssertTrue(finished.isEmpty, "coupé à \(cut) : rien n'est fini à mi-chemin")
            finished += try reassembler.accept(Array(message[cut...]))

            XCTAssertEqual(finished.count, 1, "coupé à \(cut)")
            XCTAssertEqual(
                try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, text,
                "coupé à \(cut)"
            )
            XCTAssertEqual(reassembler.buffered, 0, "coupé à \(cut) : rien ne reste")
        }
    }

    /// A chunk can carry the tail of one message and the whole of the next, so
    /// one feed can finish two. Returning only the first would leave the second
    /// waiting for a chunk that never comes.
    func testOneChunkCanFinishMoreThanOneMessage() throws {
        let first = clipboardMessage("un")
        let second = clipboardMessage("deux")

        var reassembler = SpiceAgentTransport.Reassembler()
        // Everything but the last byte of the first message...
        var finished = try reassembler.accept(Array(first.dropLast()))
        XCTAssertTrue(finished.isEmpty)
        // ...then that byte and all of the second, in one go.
        finished += try reassembler.accept([first[first.count - 1]] + second)

        XCTAssertEqual(finished.count, 2)
        XCTAssertEqual(try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, "un")
        XCTAssertEqual(try SpiceAgent.clipboard(finished[1].1, capabilities: []).text, "deux")
        XCTAssertEqual(reassembler.buffered, 0)
    }

    /// Byte at a time is the worst case the pipe can produce, and the one where
    /// an off-by-one in the header check shows up.
    func testAMessageDeliveredOneByteAtATimeStillArrives() throws {
        let message = clipboardMessage("octet par octet")
        var reassembler = SpiceAgentTransport.Reassembler()
        var finished: [(SpiceAgent.Header, [UInt8])] = []

        for byte in message {
            finished += try reassembler.accept([byte])
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(
            try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, "octet par octet"
        )
    }

    /// A size no phone should hold is refused before the bytes are kept, not
    /// after they arrive. The number came from the guest.
    func testAnAbsurdMessageSizeIsRefusedBeforeAnythingIsHeld() throws {
        var header = SpiceWire.u32(SpiceAgent.protocolVersion)
        header += SpiceWire.u32(SpiceAgent.Message.clipboard.rawValue)
        header += SpiceWire.u64(0)
        header += SpiceWire.u32(0xFFFF_FFF0)

        var reassembler = SpiceAgentTransport.Reassembler()
        XCTAssertThrowsError(try reassembler.accept(header)) { error in
            XCTAssertEqual(
                error as? SpiceAgentTransport.Failure, .tooLarge(0xFFFF_FFF0)
            )
        }
    }

    /// When the agent goes away, a half-received message must be dropped.
    /// Keeping it would make the next agent's first message start in the middle
    /// of the last one's.
    func testResettingDropsAHalfReceivedMessage() throws {
        let message = clipboardMessage("interrompu")
        var reassembler = SpiceAgentTransport.Reassembler()
        _ = try reassembler.accept(Array(message.prefix(message.count - 3)))
        XCTAssertGreaterThan(reassembler.buffered, 0)

        reassembler.reset()
        XCTAssertEqual(reassembler.buffered, 0)

        // And a fresh message afterwards is read cleanly.
        let finished = try reassembler.accept(clipboardMessage("propre"))
        XCTAssertEqual(try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, "propre")
    }

    // MARK: - Splitting for the wire

    /// Splitting and reassembling must be a round trip at any size — including
    /// one smaller than the header, which is where a reader that peeks at a
    /// partial header reads a size out of the bytes after it.
    func testSplittingAndReassemblingIsARoundTripAtAnySize() throws {
        let text = String(repeating: "aller-retour ", count: 300)
        let message = clipboardMessage(text)

        for size in [1, 7, 19, 20, 21, 64, 2048, 4096] {
            let pieces = SpiceAgentTransport.pieces(of: message, maximum: size)
            XCTAssertEqual(
                pieces.reduce(0) { $0 + $1.count }, message.count,
                "morceaux de \(size) : aucun octet perdu ni ajouté"
            )
            XCTAssertTrue(
                pieces.allSatisfy { $0.count <= size },
                "morceaux de \(size) : aucun morceau ne dépasse"
            )

            var reassembler = SpiceAgentTransport.Reassembler()
            var finished: [(SpiceAgent.Header, [UInt8])] = []
            for piece in pieces {
                finished += try reassembler.accept(piece)
            }
            XCTAssertEqual(finished.count, 1, "morceaux de \(size)")
            XCTAssertEqual(
                try SpiceAgent.clipboard(finished[0].1, capabilities: []).text, text,
                "morceaux de \(size)"
            )
        }
    }

    /// The default is the far end's buffer, not a number chosen here.
    /// `VD_AGENT_MAX_DATA_SIZE` is 2048, and a client that sends more has its
    /// message dropped by an agent that never says why.
    func testPiecesDefaultToWhatTheGuestsPipeAccepts() {
        XCTAssertEqual(SpiceAgentTransport.maximumDataBytes, 2048)
        let pieces = SpiceAgentTransport.pieces(of: [UInt8](repeating: 7, count: 5000))
        XCTAssertEqual(pieces.map(\.count), [2048, 2048, 904])
    }

    /// A message with no body is still one payload. Sending nothing at all
    /// would say nothing at all, and `CLIPBOARD_RELEASE` without the selection
    /// capability is exactly that message.
    func testAnEmptyMessageIsStillSent() {
        XCTAssertEqual(SpiceAgentTransport.pieces(of: []), [[]])
    }

    // MARK: - Tokens

    /// Spending what you do not have is how a client gets disconnected for
    /// flooding; never spending is how it silently stops being heard.
    func testATokenIsSpentPerMessageAndRunsOut() {
        var tokens = SpiceAgentTransport.Tokens(available: 2)
        XCTAssertTrue(tokens.spend())
        XCTAssertTrue(tokens.spend())
        XCTAssertFalse(tokens.spend(), "il n'en reste plus")
        XCTAssertEqual(tokens.available, 0)

        tokens.grant(3)
        XCTAssertEqual(tokens.available, 3)
        XCTAssertTrue(tokens.spend())
    }

    /// A server announcing four billion tokens is broken or hostile. Wrapping
    /// would hand it an unlimited budget by making the count small again.
    func testAnAbsurdGrantSaturatesRatherThanWrapping() {
        var tokens = SpiceAgentTransport.Tokens(available: 10)
        tokens.grant(.max)
        XCTAssertEqual(tokens.available, .max)

        tokens.grant(.max)
        XCTAssertEqual(tokens.available, .max, "et reste saturé plutôt que de repasser à zéro")
        XCTAssertTrue(tokens.spend())
    }
}
