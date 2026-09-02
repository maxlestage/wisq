import Foundation
import WisqCore
import WisqNet
import XCTest
@testable import WisqRemote

/// The conduct of one file on its way to the guest, driven against a scripted
/// server: start, wait to be told `canSendData`, stream chunks, and end on
/// the status the agent sends — or on this side's own abort.
///
/// Every await on an outcome is bounded by `within`, on purpose: the failure
/// mode these tests exist to catch is a conduct that waits forever, and a
/// test that waits forever with it proves nothing to anyone watching CI.
final class SpiceFileTransferChannelTests: XCTestCase {
    private func serverMessage(_ type: UInt16, _ payload: [UInt8] = []) -> Data {
        SpiceWire.message(type, serial: 1, payload: Data(payload))
    }

    private func agentData(_ type: SpiceAgent.Message, body: [UInt8]) -> Data {
        serverMessage(
            SpiceWire.Message.mainAgentData, SpiceAgent.message(type, body: body)
        )
    }

    private func status(id: SpiceFileTransfer.TransferID, _ result: SpiceFileTransfer.Status) -> Data {
        agentData(.fileXferStatus, body: SpiceFileTransfer.statusBody(id: id, result: result))
    }

    /// The agent messages the client has sent so far, reassembled from its
    /// `AGENT_DATA` pieces.
    private func sentAgentMessages(
        _ stream: MemoryByteStream
    ) async throws -> [(SpiceAgent.Header, [UInt8])] {
        try await agentMessagesOnTheWire(stream)
    }

    /// Runs `operation` but fails rather than hangs if it outlasts `seconds`.
    private func within<T: Sendable>(
        _ seconds: Double = 5, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw WisqError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Awaits the transfer's outcome, but never forever: `Task.value` cannot
    /// be interrupted from outside, so a watchdog cancels the *transfer* —
    /// through the same cancellation path the app would use — and a conduct
    /// that lost its caller shows up as a wrong error rather than a hung
    /// suite. (The first version of this helper raced `Task.value` in a task
    /// group; the group then waited for the un-cancellable await anyway, and
    /// a sabotaged conduct hung the whole run instead of failing one test.)
    private func outcome(of task: Task<Void, Error>, within seconds: Double = 5) async throws {
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        defer { watchdog.cancel() }
        try await task.value
    }

    /// Waits until the client has put a message of `type` on the wire.
    private func waitForSent(
        _ type: SpiceAgent.Message, on stream: MemoryByteStream
    ) async throws {
        _ = try await within(5) {
            while try await !agentMessagesOnTheWire(stream)
                .contains(where: { $0.0.type == type }) {
                try await Task.sleep(for: .milliseconds(1))
            }
            return true
        }
    }

    /// Starts a transfer and returns once its `FILE_XFER_START` is on the
    /// wire, so the test can script the agent's answers without racing it.
    private func startTransfer(
        _ channel: SpiceAgentChannel, on stream: MemoryByteStream,
        name: String = "notes.txt", contents: Data
    ) async throws -> Task<Void, Error> {
        let task = Task { try await channel.sendFile(name: name, contents: contents) }
        try await waitForSent(.fileXferStart, on: stream)
        return task
    }

    // MARK: - The happy path

    /// The detailed-errors capability is asked for on the wire, not just held
    /// in a list: the agent only attaches the free-space number to clients
    /// that announced it, and a list that never reaches `open` is the defect
    /// the audio channels had.
    func testTheAnnouncementAsksForDetailedTransferErrors() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        try await channel.start()

        let messages = try await sentAgentMessages(server)
        let announcement = try SpiceAgent.announcement(messages[0].1)
        XCTAssertTrue(
            SpiceAgent.supports(.fileXferDetailedErrors, in: announcement.capabilities),
            "sans l'annonce, l'agent n'envoie jamais le détail d'espace libre"
        )
    }

    func testAFileTravelsAsStartThenChunksThenWaitsForTheVerdict() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("hello".utf8))

        // Nothing but the start moves before the agent says go.
        var messages = try await sentAgentMessages(server)
        XCTAssertEqual(messages.map(\.0.type), [.fileXferStart])
        XCTAssertEqual(
            messages[0].1,
            SpiceFileTransfer.startBody(id: 1, name: "notes.txt", size: 5)
        )

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()

        messages = try await sentAgentMessages(server)
        XCTAssertEqual(messages.map(\.0.type), [.fileXferStart, .fileXferData])
        XCTAssertEqual(
            messages[1].1,
            SpiceFileTransfer.dataBody(id: 1, chunk: [UInt8]("hello".utf8)[...])
        )

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }

    func testALargeFileIsChunkedAtTheReferencesSize() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1_000_000)
        // 65 536 is written out rather than read from the constant under
        // test: a probe that derives its input from the code it measures
        // cannot see that code change. (A doubled chunk size passed the
        // first version of this test.)
        let contents = Data((0..<(65_536 + 1000)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        let task = try await startTransfer(channel, on: server, contents: contents)

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()

        let data = try await sentAgentMessages(server).filter { $0.0.type == .fileXferData }
        XCTAssertEqual(data.count, 2, "64 Kio puis le reste — la taille de lecture de la référence")
        XCTAssertEqual(
            data.map { $0.1.count - 12 }, [65_536, 1000],
            "chaque corps : id (4) + compte (8) + les octets de sa tranche"
        )

        // Each data body: id, a 64-bit count, then that many bytes — and the
        // bytes, reassembled, are the file.
        var carried: [UInt8] = []
        for (_, body) in data {
            var reader = try SpiceWire.Reader(body, from: 0)
            XCTAssertEqual(try reader.u32(), 1)
            let count = try reader.u64()
            let bytes = try reader.bytes(Int(count))
            XCTAssertEqual(reader.remaining, 0)
            XCTAssertNotEqual(count, 0, "jamais un DATA vide en fin de fichier non vide — fdo#97227")
            carried += bytes
        }
        XCTAssertEqual(carried, [UInt8](contents))

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }

    /// A zero-byte file still owes the agent exactly one data message —
    /// without it the guest holds an empty file open forever (rhbz#1135099).
    func testAZeroByteFileSendsExactlyOneEmptyData() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data())

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()

        let data = try await sentAgentMessages(server).filter { $0.0.type == .fileXferData }
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data[0].1, SpiceFileTransfer.dataBody(id: 1, chunk: [][...]))

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }

    // MARK: - Refusals and failures

    func testARefusalBeforeAnyByteFailsWithItsCause() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        await server.feed(agentData(.fileXferStatus, body:
            SpiceFileTransfer.statusBody(id: 1, result: .notEnoughSpace)
                + SpiceWire.u64(3_200_000)
        ))
        _ = try await channel.pump()

        do {
            try await outcome(of: task)
            XCTFail("un refus de l'agent doit faire échouer l'envoi")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(failure, .refused(.notEnoughSpace, diskFreeSpace: 3_200_000))
            XCTAssertTrue(failure.message.contains("3200000"), failure.message)
        }
        let data = try await sentAgentMessages(server).filter { $0.0.type == .fileXferData }
        XCTAssertTrue(data.isEmpty, "aucun octet ne part sans canSendData")
    }

    /// A guest that announced `fileXferDisabled` has refused every transfer in
    /// advance; nothing is put on the wire at all.
    func testAGuestThatDisabledTransfersIsRefusedBeforeStarting() async throws {
        let server = MemoryByteStream(inbound: agentData(
            .announceCapabilities,
            body: SpiceAgent.announcementBody(SpiceAgent.Announcement(
                request: false,
                capabilities: SpiceAgent.capabilityWords([.clipboardByDemand, .fileXferDisabled])
            ))
        ))
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        _ = try await channel.pump()

        do {
            // Bounded: sabotaged, this refusal becomes a wait for a verdict
            // that never comes, and the test must fail rather than hang.
            try await within { try await channel.sendFile(name: "x", contents: Data("x".utf8)) }
            XCTFail("un invité qui a désactivé le transfert doit refuser d'avance")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(failure, .disabledByGuest)
        }
        let messages = try await sentAgentMessages(server)
        XCTAssertFalse(messages.contains { $0.0.type == .fileXferStart })
    }

    func testNoAgentMeansNoTransfer() async throws {
        let channel = SpiceAgentChannel(stream: MemoryByteStream(), connected: false)
        do {
            try await within { try await channel.sendFile(name: "x", contents: Data("x".utf8)) }
            XCTFail("sans agent, personne ne peut recevoir le fichier")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(failure, .noAgent)
        }
    }

    func testASecondTransferWhileOneRunsIsRefused() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        do {
            try await channel.sendFile(name: "y", contents: Data("y".utf8))
            XCTFail("un seul transfert à la fois")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(failure, .busy)
        }

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }

    func testTheAgentVanishingFailsTheTransferInFlight() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        await server.feed(serverMessage(SpiceWire.Message.mainAgentDisconnected))
        _ = try await channel.pump()

        do {
            try await outcome(of: task)
            XCTFail("un agent disparu ne recevra jamais la fin du fichier")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(failure, .noAgent)
        }
    }

    /// Aborting from this side fails the caller *and* tells the agent, which
    /// still believes a file is coming and would hold its half-open handle.
    func testAbortTellsTheAgentAndFailsTheCaller() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        await channel.abortFileTransfer()

        do {
            try await outcome(of: task)
            XCTFail("un envoi annulé doit échouer chez l'appelant")
        } catch is CancellationError {}

        let statuses = try await sentAgentMessages(server).filter { $0.0.type == .fileXferStatus }
        XCTAssertEqual(
            statuses.map(\.1),
            [SpiceFileTransfer.statusBody(id: 1, result: .cancelled)],
            "l'agent doit apprendre que le fichier ne viendra pas"
        )
    }

    /// A status naming an id this side is not running — a transfer already
    /// torn down, or somebody's confusion — is counted, not acted on.
    func testAStatusForAnotherIdIsCountedAndTheTransferKeepsWaiting() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        await server.feed(status(id: 99, .success))
        let progress = try await channel.pump()
        XCTAssertEqual(
            progress.ignored[UInt16(SpiceAgent.Message.fileXferStatus.rawValue)], 1
        )

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }

    /// File bytes wait on tokens like everything else on this channel: with
    /// one token, the start goes out and the chunk stays queued until the
    /// server grants more.
    func testTokensGateTheFileBytesToo() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1)
        let task = try await startTransfer(channel, on: server, contents: Data("x".utf8))

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()
        var data = try await sentAgentMessages(server).filter { $0.0.type == .fileXferData }
        XCTAssertTrue(data.isEmpty, "le jeton unique est parti avec le START")

        await server.feed(serverMessage(SpiceWire.Message.mainAgentToken, SpiceWire.u32(10)))
        _ = try await channel.pump()
        data = try await sentAgentMessages(server).filter { $0.0.type == .fileXferData }
        XCTAssertEqual(data.count, 1, "la relance des jetons doit relancer le fichier")

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
    }
}

/// Free-standing so a `@Sendable` poll can call it without capturing the
/// test case: everything the client wrote, reassembled into agent messages.
private func agentMessagesOnTheWire(
    _ stream: MemoryByteStream
) async throws -> [(SpiceAgent.Header, [UInt8])] {
    var reassembler = SpiceAgentTransport.Reassembler()
    var out: [(SpiceAgent.Header, [UInt8])] = []
    var reader = SpiceWire.Reader(await stream.written)
    while reader.remaining >= SpiceWire.dataHeaderBytes {
        let header = try SpiceWire.decodeDataHeader(
            Data(try reader.bytes(SpiceWire.dataHeaderBytes))
        )
        let payload = try reader.bytes(Int(header.size))
        if header.type == SpiceWire.ClientMessage.agentData {
            out += try reassembler.accept(payload)
        }
    }
    return out
}
