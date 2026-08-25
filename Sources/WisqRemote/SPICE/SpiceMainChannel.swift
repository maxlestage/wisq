import Foundation
import WisqNet

/// The main channel, from the first message the server sends to the list of
/// channels it offers.
///
/// This is where a SPICE session learns what it is connected to: how many
/// displays exist, whether an agent is running in the guest, and which channels
/// can be opened next. Everything after this milestone — display, inputs,
/// cursor — is a channel named in that list.
struct SpiceMainChannel {
    let stream: ByteStream

    /// What the main channel is worth having read.
    struct Session: Equatable {
        var initialisation: SpiceWire.MainInit
        var channels: [SpiceWire.ChannelID]
        /// Notices the server sent along the way. Carried out rather than
        /// dropped: they are written for a person.
        var notices: [SpiceWire.Notify] = []
        /// The serial to use for the next message on this connection.
        ///
        /// Reported rather than left implicit because the main channel does not
        /// end here: whatever keeps reading it afterwards continues the same
        /// sequence, and one that restarted at 1 would go backwards in front of
        /// a server that acknowledges by serial.
        var nextSerial: UInt64 = 0
    }

    /// Client messages are serialised from one, and the count is ours to keep.
    /// A server that acknowledges by serial is entitled to a sequence with no
    /// gaps in it.
    private static let firstSerial: UInt64 = 1

    /// Reads until the server has sent both `MAIN_INIT` and the channel list,
    /// answering what has to be answered on the way.
    ///
    /// `limit` is not a timeout in disguise: it bounds how many messages this
    /// will consume before deciding the server is never going to get to the
    /// point. Without it a server that only ever pings keeps this running for
    /// as long as it likes.
    func bringUp(limit: Int = 64) async throws -> Session {
        var serial = Self.firstSerial
        var initialisation: SpiceWire.MainInit?
        var notices: [SpiceWire.Notify] = []
        var askedForChannels = false

        for _ in 0..<limit {
            let header = try SpiceWire.decodeDataHeader(
                try await stream.read(exactly: SpiceWire.dataHeaderBytes)
            )
            // A size is an allocation instruction from the far end. SPICE
            // messages in this phase are tens of bytes; a megabyte here is a
            // server we should stop talking to rather than accommodate.
            guard header.size <= 1 << 20 else { throw SpiceError.invalidData }
            let payload = header.size == 0
                ? Data() : try await stream.read(exactly: Int(header.size))

            switch header.type {
            case SpiceWire.Message.mainInit:
                initialisation = try SpiceWire.decodeMainInit(payload)
                // Asking for the channel list is what makes the server send
                // it; it does not volunteer one.
                try await stream.write(
                    SpiceWire.message(SpiceWire.ClientMessage.attachChannels, serial: serial)
                )
                serial += 1
                askedForChannels = true

            case SpiceWire.Message.mainChannelsList:
                guard let initialisation else { throw SpiceError.invalidData }
                return Session(
                    initialisation: initialisation,
                    channels: try SpiceWire.decodeChannelsList(payload),
                    notices: notices,
                    nextSerial: serial
                )

            case SpiceWire.Message.ping:
                // Answered exactly, because the server times the round trip and
                // may decide a client that does not answer has gone.
                let ping = try SpiceWire.decodePing(payload)
                try await stream.write(
                    SpiceWire.message(
                        SpiceWire.ClientMessage.pong, serial: serial,
                        payload: SpiceWire.encodePong(ping)
                    )
                )
                serial += 1

            case SpiceWire.Message.setAck:
                // The generation has to be echoed: it is how the server tells
                // an acknowledgement for this window from one for the last.
                let ack = try SpiceWire.decodeSetAck(payload)
                try await stream.write(
                    SpiceWire.message(
                        SpiceWire.ClientMessage.ackSync, serial: serial,
                        payload: Data(SpiceWire.u32(ack.generation))
                    )
                )
                serial += 1

            case SpiceWire.Message.notify:
                notices.append(try SpiceWire.decodeNotify(payload))

            case SpiceWire.Message.disconnecting:
                throw SpiceError.refused(.error)

            default:
                // Unknown messages are skipped, not fatal. The payload was
                // already consumed, so the stream stays in step — which is the
                // only thing that actually matters about a message nobody here
                // understands.
                continue
            }
        }

        // Ran out of patience. Which half of the exchange never arrived says
        // something different, so it is not flattened to one error.
        throw askedForChannels ? SpiceError.noChannelList : SpiceError.noMainInit
    }
}
