import Foundation

/// The wire half of sending a file to the guest, over the agent that already
/// carries the clipboard.
///
/// The flow is spice-gtk's (`channel-main.c`): the client sends
/// `FILE_XFER_START` naming the file, the agent answers with a
/// `FILE_XFER_STATUS` — `canSendData` to proceed, anything else to refuse —
/// the client sends the bytes in `FILE_XFER_DATA` messages, and the agent
/// closes with a final status. The client also *sends* a status: `cancelled`
/// or `error`, when the transfer dies on this side.
///
/// **The start payload is a GKeyFile document, and its bytes are pinned by
/// GLib, not by this file's author.** `scripts/spice-file-xfer-fixtures/`
/// links GLib and prints `g_key_file_to_data`'s exact output for names that
/// exercise every escape; `SpiceFileTransferTests` holds this serialiser to
/// those bytes. What GLib actually does is narrower than one would guess:
/// `\` `\n` `\r` are escaped anywhere, the *leading* run of blanks is escaped
/// (` ` → `\s`, tab → `\t`), and a tab in the middle or a space at the end
/// travels raw. And the terminating NUL is part of the payload — the
/// reference queues `data_len + 1` bytes.
enum SpiceFileTransfer {
    /// One transfer's identifier. Never zero: the reference treats a task id
    /// of zero as "no task" (`g_return_if_fail(task_id != 0)`).
    typealias TransferID = UInt32

    /// `VDAgentFileXferStatusMessage.result`, both directions.
    enum Status: UInt32, Equatable, Sendable {
        case canSendData = 0
        case cancelled = 1
        case error = 2
        case success = 3
        case notEnoughSpace = 4
        case sessionLocked = 5
        case agentNotConnected = 6
        case disabled = 7
    }

    /// A final status, decoded with whatever detail the agent attached.
    ///
    /// The detail is only present when the client announced
    /// `fileXferDetailedErrors` *and* the message is long enough to carry it —
    /// the reference checks the size rather than trusting the capability, and
    /// so does this. An unknown result value is kept as a number rather than
    /// refused: statuses are an enumeration built to grow, and a transfer
    /// should fail with "statut 9" rather than kill the pump.
    struct StatusMessage: Equatable, Sendable {
        var id: TransferID
        var result: UInt32
        /// For `notEnoughSpace`, the guest's free bytes.
        var diskFreeSpace: UInt64?

        var status: Status? { Status(rawValue: result) }
    }

    /// How a transfer fails on this side, each with words a person can act
    /// on. The refusal texts follow the reference client's, because they name
    /// causes that are real and distinct — a locked session and a full disk
    /// call for different next moves.
    enum Failure: Error, Equatable {
        /// A transfer is already running; this client sends one at a time.
        case busy
        /// No agent in the guest — nobody there to receive a file.
        case noAgent
        /// The guest announced `fileXferDisabled`: every transfer will be
        /// refused, so none is started.
        case disabledByGuest
        /// The agent ended the transfer with something other than success.
        case refused(Status, diskFreeSpace: UInt64?)
        /// A result value this client does not know. The transfer fails with
        /// the number; the session stays up.
        case unknownStatus(UInt32)
        /// This side could not read the file it was sending — the disk
        /// refused, or the file shrank under the transfer. The agent is told
        /// `error`, as the reference does for any local failure that is not
        /// a cancellation.
        case unreadable(String)

        var message: String {
            switch self {
            case .busy:
                return "un transfert est déjà en cours"
            case .noAgent:
                return "aucun agent ne tourne dans l'invité pour recevoir le fichier"
            case .disabledByGuest:
                return "le transfert de fichiers est désactivé dans l'invité"
            case .refused(.cancelled, _):
                return "l'agent a annulé le transfert"
            case .refused(.error, _):
                return "l'agent a signalé une erreur pendant le transfert"
            case .refused(.notEnoughSpace, .some(let free)):
                return "pas assez d'espace libre dans l'invité (\(free) octets libres)"
            case .refused(.notEnoughSpace, .none):
                return "pas assez d'espace libre dans l'invité"
            case .refused(.sessionLocked, _):
                return "la session de l'invité est verrouillée — déverrouillez-la et réessayez"
            case .refused(.agentNotConnected, _):
                return "l'agent de session n'est pas connecté dans l'invité"
            case .refused(.disabled, _):
                return "le transfert de fichiers est désactivé dans l'invité"
            case .refused(let status, _):
                return "l'agent a refusé le transfert (statut \(status.rawValue))"
            case .unknownStatus(let raw):
                return "l'agent a répondu un statut inconnu (\(raw))"
            case .unreadable(let detail):
                return "le fichier n'a pas pu être lu : \(detail)"
            }
        }
    }

    // MARK: - Where the bytes come from

    /// A file's bytes, a chunk at a time, for the channel to stream.
    ///
    /// The channel never holds more than one chunk of the file: it asks for
    /// the next 64 KiB when the tokens have drained the last, which is what
    /// lets a phone send a file larger than the memory it can spare. The
    /// size is fixed at the start — it is what `FILE_XFER_START` announces,
    /// and the agent waits for exactly that many bytes — so a file that
    /// changes length underneath is a failure, not a surprise for the guest.
    struct Source: Sendable {
        /// The length announced to the agent.
        let size: UInt64
        /// Bytes `[offset, offset + count)`. Fewer than `count` only at the
        /// end of the file; throws when the disk refuses.
        let read: @Sendable (_ offset: UInt64, _ count: Int) throws -> [UInt8]
        /// Called once the transfer is over, however it ended. Idempotent.
        let close: @Sendable () -> Void

        /// A file already in memory. Nothing to close.
        static func inMemory(_ data: Data) -> Source {
            Source(size: UInt64(data.count), read: { offset, count in
                let start = Int(offset)
                let end = min(start + count, data.count)
                guard start < end else { return [] }
                return [UInt8](data[data.startIndex + start..<data.startIndex + end])
            }, close: {})
        }

        /// A file on disk, read through a handle that stays open for the
        /// transfer. The size is the file's at this moment.
        ///
        /// On Apple platforms a URL from the document picker points into
        /// somebody else's container and is readable only inside a
        /// security scope; the scope is claimed here and released by
        /// `close`, so it lives exactly as long as the reads it protects —
        /// a scope claimed by the view and released when the picker
        /// callback returns would be gone before the first chunk is read.
        static func file(at url: URL) throws -> Source {
            let handle = try ScopedHandle(url)
            return Source(
                size: handle.size,
                read: { offset, count in try handle.read(offset: offset, count: count) },
                close: { handle.close() }
            )
        }
    }

    /// The open file behind `Source.file`, with its security scope.
    ///
    /// `@unchecked` because `FileHandle` is not `Sendable`; every use of it
    /// goes through `lock`, so the claim holds whoever calls, not only the
    /// one actor that does today.
    private final class ScopedHandle: @unchecked Sendable {
        let size: UInt64
        private let url: URL
        private let handle: FileHandle
        private let scoped: Bool
        private let lock = NSLock()
        private var closed = false

        init(_ url: URL) throws {
            #if canImport(Darwin)
            let scoped = url.startAccessingSecurityScopedResource()
            #else
            let scoped = false
            #endif
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                    throw CocoaError(.fileReadUnknown)
                }
                self.handle = try FileHandle(forReadingFrom: url)
                self.size = size
            } catch {
                #if canImport(Darwin)
                if scoped { url.stopAccessingSecurityScopedResource() }
                #endif
                throw error
            }
            self.url = url
            self.scoped = scoped
        }

        func read(offset: UInt64, count: Int) throws -> [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { throw CocoaError(.fileReadUnknown) }
            try handle.seek(toOffset: offset)
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            try? handle.close()
            #if canImport(Darwin)
            if scoped { url.stopAccessingSecurityScopedResource() }
            #endif
        }
    }

    // MARK: - Bodies this client sends

    /// `VD_AGENT_FILE_XFER_START`: the id, then the GKeyFile text, then NUL.
    static func startBody(id: TransferID, name: String, size: UInt64) -> [UInt8] {
        var out = SpiceWire.u32(id)
        out += Array("[vdagent-file-xfer]\nname=".utf8)
        out += keyFileValue(name)
        out += Array("\nsize=\(size)\n".utf8)
        out.append(0)
        return out
    }

    /// `VD_AGENT_FILE_XFER_DATA`: the id, how many bytes follow, the bytes.
    ///
    /// The size is 64 bits for 32 hundred bytes at most — the field is the
    /// protocol's, sized for the file lengths a struct-reading agent expects,
    /// not for what one message carries.
    static func dataBody(id: TransferID, chunk: ArraySlice<UInt8>) -> [UInt8] {
        var out = SpiceWire.u32(id)
        out += SpiceWire.u64(UInt64(chunk.count))
        out += chunk
        return out
    }

    /// `VD_AGENT_FILE_XFER_STATUS`, client → agent: how this side ended a
    /// transfer the agent still thinks is running.
    static func statusBody(id: TransferID, result: Status) -> [UInt8] {
        SpiceWire.u32(id) + SpiceWire.u32(result.rawValue)
    }

    /// How many file bytes one `FILE_XFER_DATA` message carries:
    /// `VD_AGENT_MAX_DATA_SIZE * 32`, the reference's read size.
    static let chunkBytes = 2048 * 32

    // MARK: - The status the agent sends back

    static func statusMessage(_ body: [UInt8]) throws -> StatusMessage {
        var reader = try SpiceWire.Reader(body, from: 0)
        var message = StatusMessage(id: try reader.u32(), result: try reader.u32())
        // The size gate is the reference's: a detail is read when it fits,
        // never assumed from the capability alone.
        if message.status == .notEnoughSpace, reader.remaining >= 8 {
            message.diskFreeSpace = try reader.u64()
        }
        return message
    }

    // MARK: - GLib's value escaping, measured rather than remembered

    /// What `g_key_file_set_string` does to a value, held to GLib's own output
    /// by the fixtures. Three characters are escaped wherever they appear —
    /// backslash, newline, carriage return — and the run of blanks at the
    /// *start* is escaped character by character. A tab after the first
    /// non-blank goes through raw, as does a trailing space; escaping those
    /// too would produce a payload GLib never produces, and the agent on the
    /// other side parses with GLib.
    static func keyFileValue(_ value: String) -> [UInt8] {
        var out: [UInt8] = []
        var leading = true
        for byte in value.utf8 {
            switch byte {
            case 0x5C:
                out += [0x5C, 0x5C] // \  →  \\ — and it ends the leading run
                leading = false
            case 0x0A: out += [0x5C, 0x6E] // \n → \n — leaves the run open
            case 0x0D: out += [0x5C, 0x72] // \r → \r — leaves the run open
            case 0x20 where leading: out += [0x5C, 0x73] // leading ' ' → \s
            case 0x09 where leading: out += [0x5C, 0x74] // leading tab → \t
            default:
                out.append(byte)
                leading = false
            }
        }
        return out
    }
}
