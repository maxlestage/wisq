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

    // MARK: - Streaming from a source

    /// A source that records what the channel asks of it: which reads, in
    /// which order, and whether it was closed. The bytes are a pattern of
    /// the offset, so a chunk read from the wrong place shows up in the
    /// reassembled file.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var reads: [(offset: UInt64, count: Int)] = []
        private(set) var closes = 0
        let size: UInt64
        /// When set, a read at this offset throws instead of answering.
        var failAt: UInt64?
        /// When set, every read answers at most this many bytes.
        var shortBy: Int?

        init(size: UInt64) { self.size = size }

        static func pattern(_ offset: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: offset + UInt64($0)) }
        }

        var source: SpiceFileTransfer.Source {
            SpiceFileTransfer.Source(size: size, read: { offset, count in
                self.lock.lock()
                defer { self.lock.unlock() }
                self.reads.append((offset, count))
                if let failAt = self.failAt, offset == failAt {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let available = Int(min(UInt64(count), self.size - min(offset, self.size)))
                let delivered = self.shortBy.map { min($0, available) } ?? available
                return Self.pattern(offset, delivered)
            }, close: {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.closes += 1
            })
        }

        var readOffsets: [UInt64] { lock.lock(); defer { lock.unlock() }; return reads.map(\.offset) }
        var closed: Int { lock.lock(); defer { lock.unlock() }; return closes }
    }

    private func dataBodies(on stream: MemoryByteStream) async throws -> [[UInt8]] {
        try await sentAgentMessages(stream).filter { $0.0.type == .fileXferData }.map(\.1)
    }

    private func statusBodies(on stream: MemoryByteStream) async throws -> [[UInt8]] {
        try await sentAgentMessages(stream).filter { $0.0.type == .fileXferStatus }.map(\.1)
    }

    /// The file is read one chunk at a time, each chunk asked for only once
    /// the tokens have drained the previous one — which is what keeps a film
    /// out of the phone's memory. Three chunks, and the tokens are granted
    /// so that at every step the source has been asked for exactly one more
    /// chunk than the wire carries.
    func testTheFileIsReadAChunkAtATimeAsTokensDrainIt() async throws {
        let server = MemoryByteStream()
        // One token: the START goes out and nothing else can.
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1)
        let recorder = Recorder(size: 65_536 * 2 + 5)
        let task = Task { try await channel.sendFile(name: "film.mov", source: recorder.source) }
        try await waitForSent(.fileXferStart, on: server)
        XCTAssertEqual(recorder.readOffsets, [], "rien n'est lu avant canSendData")

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()
        XCTAssertEqual(recorder.readOffsets, [0], "un seul morceau est lu quand les jetons manquent")
        let sentBeforeTokens = try await dataBodies(on: server)
        XCTAssertEqual(sentBeforeTokens.count, 0)

        // A 64 KiB chunk plus its 12-byte body header is 33 pieces of 2048.
        await server.feed(serverMessage(SpiceWire.Message.mainAgentToken, SpiceWire.u32(33)))
        _ = try await channel.pump()
        XCTAssertEqual(recorder.readOffsets, [0, 65_536], "le morceau suivant est lu quand le précédent est parti")
        let sentAfterOneChunk = try await dataBodies(on: server)
        XCTAssertEqual(sentAfterOneChunk.count, 1)

        await server.feed(serverMessage(SpiceWire.Message.mainAgentToken, SpiceWire.u32(100)))
        _ = try await channel.pump()
        XCTAssertEqual(recorder.readOffsets, [0, 65_536, 131_072])
        let bodies = try await dataBodies(on: server)
        XCTAssertEqual(bodies.map { $0.count - 12 }, [65_536, 65_536, 5])
        XCTAssertEqual(
            bodies.flatMap { $0.dropFirst(12) }, Recorder.pattern(0, 65_536 * 2 + 5),
            "les morceaux, remis bout à bout, sont le fichier"
        )

        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)
        XCTAssertEqual(recorder.closed, 1, "la source est fermée une fois le verdict rendu")
    }

    /// A read the disk refuses ends the transfer from this side: the caller
    /// gets the cause, and the agent — still waiting for the rest of the
    /// file — is told `error`, which is what the reference sends for every
    /// local failure that is not a cancellation.
    func testAReadTheDiskRefusesFailsTheCallerAndTellsTheAgent() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1_000)
        let recorder = Recorder(size: 65_536 + 1)
        recorder.failAt = 65_536
        let task = Task { try await channel.sendFile(name: "x", source: recorder.source) }
        try await waitForSent(.fileXferStart, on: server)

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()

        do {
            try await outcome(of: task)
            XCTFail("un fichier illisible ne peut pas être envoyé en entier")
        } catch let failure as SpiceFileTransfer.Failure {
            guard case .unreadable(let detail) = failure else {
                return XCTFail("échec inattendu : \(failure)")
            }
            XCTAssertTrue(failure.message.contains("n'a pas pu être lu"), failure.message)
            XCTAssertFalse(detail.isEmpty)
        }
        let data = try await dataBodies(on: server)
        XCTAssertEqual(data.count, 1, "le premier morceau était parti")
        let statuses = try await statusBodies(on: server)
        XCTAssertEqual(
            statuses,
            [SpiceFileTransfer.statusBody(id: 1, result: .error)],
            "l'agent apprend que le fichier ne viendra pas, par `error` et non `cancelled`"
        )
        XCTAssertEqual(recorder.closed, 1)
    }

    /// The size announced in START is what the agent waits for. A file that
    /// has fewer bytes than that by the time they are read is failed here,
    /// not sent short — a short file would leave the agent holding a
    /// half-written file open until the session ends.
    func testAFileThatShrankUnderTheTransferIsFailedNotSentShort() async throws {
        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1_000)
        let recorder = Recorder(size: 100)
        recorder.shortBy = 40
        let task = Task { try await channel.sendFile(name: "x", source: recorder.source) }
        try await waitForSent(.fileXferStart, on: server)

        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()

        do {
            try await outcome(of: task)
            XCTFail("un fichier qui a rétréci ne peut pas être envoyé tel qu'annoncé")
        } catch let failure as SpiceFileTransfer.Failure {
            XCTAssertEqual(
                failure,
                .unreadable("le fichier a rétréci pendant l'envoi (40 octets sur 100 annoncés)")
            )
        }
        let data = try await dataBodies(on: server)
        XCTAssertEqual(data.count, 0, "aucun octet court ne part")
        let statuses = try await statusBodies(on: server)
        XCTAssertEqual(statuses, [SpiceFileTransfer.statusBody(id: 1, result: .error)])
        XCTAssertEqual(recorder.closed, 1)
    }

    /// The source is closed exactly once whichever way the transfer ends —
    /// on the phone it holds an open file and a security scope, and either
    /// left behind is a leak per file sent.
    func testTheSourceIsClosedHoweverTheTransferEnds() async throws {
        // Refused by the agent before any byte.
        do {
            let server = MemoryByteStream()
            let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
            let recorder = Recorder(size: 1)
            let task = Task { try await channel.sendFile(name: "x", source: recorder.source) }
            try await waitForSent(.fileXferStart, on: server)
            await server.feed(status(id: 1, .notEnoughSpace))
            _ = try await channel.pump()
            _ = try? await outcome(of: task)
            XCTAssertEqual(recorder.closed, 1, "fermée après un refus")
        }
        // Aborted from this side.
        do {
            let server = MemoryByteStream()
            let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
            let recorder = Recorder(size: 1)
            let task = Task { try await channel.sendFile(name: "x", source: recorder.source) }
            try await waitForSent(.fileXferStart, on: server)
            await channel.abortFileTransfer()
            _ = try? await outcome(of: task)
            XCTAssertEqual(recorder.closed, 1, "fermée après une annulation")
        }
        // Refused before starting: busy, and no agent.
        do {
            let server = MemoryByteStream()
            let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 100)
            let first = Recorder(size: 1)
            let task = Task { try await channel.sendFile(name: "x", source: first.source) }
            try await waitForSent(.fileXferStart, on: server)
            let second = Recorder(size: 1)
            _ = try? await channel.sendFile(name: "y", source: second.source)
            XCTAssertEqual(second.closed, 1, "un envoi refusé pour occupation ferme sa source")
            XCTAssertEqual(first.closed, 0, "et pas celle de l'envoi en cours")
            await server.feed(status(id: 1, .success))
            _ = try await channel.pump()
            try await outcome(of: task)
            XCTAssertEqual(first.closed, 1)

            let idle = Recorder(size: 1)
            _ = try? await SpiceAgentChannel(stream: MemoryByteStream(), connected: false)
                .sendFile(name: "z", source: idle.source)
            XCTAssertEqual(idle.closed, 1, "sans agent, la source est quand même fermée")
        }
    }

    /// A real file on disk, through `Source.file`: its size is read from the
    /// file system, its bytes travel exactly, and the handle is closed once
    /// — closing again is harmless, reading after it is refused.
    func testAFileOnDiskTravelsByteForByte() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-file-xfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.bin")
        let contents = Recorder.pattern(7, 70_000)
        try Data(contents).write(to: url)

        let source = try SpiceFileTransfer.Source.file(at: url)
        XCTAssertEqual(source.size, 70_000, "la taille annoncée est celle du fichier")

        let server = MemoryByteStream()
        let channel = SpiceAgentChannel(stream: server, connected: true, tokens: 1_000_000)
        let task = Task { try await channel.sendFile(name: "photo.bin", source: source) }
        try await waitForSent(.fileXferStart, on: server)
        await server.feed(status(id: 1, .canSendData))
        _ = try await channel.pump()
        let bodies = try await dataBodies(on: server)
        XCTAssertEqual(bodies.map { $0.count - 12 }, [65_536, 70_000 - 65_536])
        XCTAssertEqual(bodies.flatMap { $0.dropFirst(12) }, contents)
        await server.feed(status(id: 1, .success))
        _ = try await channel.pump()
        try await outcome(of: task)

        // The channel closed it; closing again is harmless, reading is not.
        source.close()
        XCTAssertThrowsError(try source.read(0, 1), "une source fermée ne lit plus")

        // The empty file on disk owes the agent its one empty DATA too.
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        let emptySource = try SpiceFileTransfer.Source.file(at: empty)
        XCTAssertEqual(emptySource.size, 0)
        emptySource.close()

        XCTAssertThrowsError(
            try SpiceFileTransfer.Source.file(at: directory.appendingPathComponent("absent")),
            "un fichier absent échoue à l'ouverture, avant tout octet sur le fil"
        )
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
