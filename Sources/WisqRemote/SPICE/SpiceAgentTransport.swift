import Foundation

/// How agent messages get across the main channel.
///
/// The layering here is the thing to get right, and the obvious reading of the
/// protocol headers gets it wrong. `vd_agent.h` defines a `VDIChunkHeader` —
/// port and size — sitting in front of every `VDAgentMessage`, so a client
/// written from the headers alone puts one on the wire and is refused, or
/// worse, ignored. **That header belongs to the virtio serial pipe between the
/// SPICE server and the agent inside the guest.** It never crosses the network.
/// Between client and server there are two layers, not three:
///
///     SPICE_MSGC_MAIN_AGENT_DATA   the channel's envelope, ≤ 2048 bytes
///       VDAgentMessage             protocol + type + opaque + size
///
/// What survives from the pipe's framing is the consequence: **one agent
/// message can arrive across several `AGENT_DATA` messages**, split at
/// arbitrary points including inside the header, because the server forwards
/// whatever the pipe handed it. A reader that treats each `AGENT_DATA` as a
/// whole message works for short text and silently truncates long text — the
/// failure that only shows up when someone copies a real document.
///
/// Tokens are the other half. The server grants a number of them and each
/// `AGENT_DATA` message spends one; a client that spends what it has not got
/// is flooding, and one that stops sending because it thinks it has none is
/// silently mute. Neither is loud when it goes wrong.
enum SpiceAgentTransport {
    /// `VD_AGENT_MAX_DATA_SIZE`. The most one `AGENT_DATA` message may carry,
    /// header included, and not this client's choice: it is the size of the
    /// buffer at the far end of the pipe.
    static let maximumDataBytes = 2048

    /// A cap on what one agent message may claim, before anything is kept.
    ///
    /// The clipboard is the reason there is a limit at all: a guest offering a
    /// hundred megabytes of "text" would otherwise be a hundred megabytes held
    /// on a phone. Chosen to be larger than any plausible paste and smaller
    /// than anything that matters.
    static let maximumMessageBytes = 4 << 20

    enum Failure: Error, Equatable {
        /// The reassembled message is bigger than this client will hold.
        case tooLarge(UInt32)
    }

    /// Collects `AGENT_DATA` payloads until an agent message is whole.
    ///
    /// Stateful because the split is: the header says how many bytes the
    /// message has, and they arrive across as many `AGENT_DATA` messages as the
    /// guest's pipe felt like using. Keeping that state here rather than in the
    /// session is what lets it be tested by handing it byte slices in every
    /// arrangement.
    struct Reassembler {
        private var pending: [UInt8] = []

        /// How many bytes are held part-way through a message. Zero between
        /// messages, and worth asserting on: a reassembler that never empties
        /// is one leaking bytes per message.
        var buffered: Int { pending.count }

        /// Feeds one `AGENT_DATA` payload, returning any agent messages it
        /// completed. A list rather than an optional because a single payload
        /// may carry the tail of one message and the whole of the next.
        mutating func accept(_ bytes: [UInt8]) throws -> [(SpiceAgent.Header, [UInt8])] {
            pending += bytes
            var finished: [(SpiceAgent.Header, [UInt8])] = []

            // The header is 4 + 4 + 8 + 4 bytes; nothing can be decided with
            // fewer, and looking at a partial one would read a size out of
            // whatever follows.
            let headerBytes = 20
            while pending.count >= headerBytes {
                var reader = try SpiceWire.Reader(pending, from: 0)
                let header = try SpiceAgent.header(from: &reader)
                guard header.size <= UInt32(maximumMessageBytes) else {
                    throw Failure.tooLarge(header.size)
                }
                let total = headerBytes + Int(header.size)
                guard pending.count >= total else { break }

                finished.append((header, Array(pending[headerBytes..<total])))
                pending.removeFirst(total)
            }
            return finished
        }

        /// Throws away a part-finished message.
        ///
        /// Used when the agent goes away: its half-sent message will never be
        /// completed, and holding the fragment would make the *next* agent's
        /// first message start in the middle of the last one's.
        mutating func reset() { pending.removeAll() }
    }

    /// Splits an agent message into `AGENT_DATA` payloads.
    ///
    /// No framing is added — the pieces are consecutive slices of the same
    /// bytes, and the receiver puts them back together by the size in the
    /// header rather than by any marker in the stream. An empty message is
    /// still one payload: a zero-byte message type (`CLIPBOARD_RELEASE` with no
    /// selection) is a message, and sending nothing at all says nothing at all.
    static func pieces(
        of message: [UInt8], maximum: Int = maximumDataBytes
    ) -> [[UInt8]] {
        precondition(maximum > 0, "un morceau de taille nulle ne finirait jamais le message")
        guard !message.isEmpty else { return [[]] }
        var out: [[UInt8]] = []
        var index = 0
        while index < message.count {
            let end = min(index + maximum, message.count)
            out.append(Array(message[index..<end]))
            index = end
        }
        return out
    }

    // MARK: - Tokens

    /// The server's flow control for agent messages.
    ///
    /// Each `AGENT_DATA` message spends a token; the server grants more as it
    /// drains them. Spending what you do not have is how a client gets
    /// disconnected for flooding, and never spending is how it silently stops
    /// being heard.
    struct Tokens: Equatable, Sendable {
        private(set) var available: UInt32

        init(available: UInt32 = 0) { self.available = available }

        /// Takes one for a payload about to be sent, or reports there are none.
        mutating func spend() -> Bool {
            guard available > 0 else { return false }
            available -= 1
            return true
        }

        /// The server granting more.
        ///
        /// Saturating rather than wrapping: a server announcing four billion
        /// tokens is either broken or hostile, and an overflow here would hand
        /// it an unlimited budget by making the count small again.
        mutating func grant(_ count: UInt32) {
            available = available.addingReportingOverflow(count).overflow
                ? UInt32.max
                : available + count
        }
    }
}
