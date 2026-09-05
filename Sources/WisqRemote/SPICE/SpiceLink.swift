import Foundation
import WisqNet

#if canImport(Security)
import Security
#endif

/// Turns the server's public key and a password into the ticket the link
/// expects.
///
/// A closure rather than a call, and this is the whole reason the link is
/// testable. SPICE encrypts the ticket with RSA, which on Apple means
/// `Security` and on Linux means nothing at all — there is no implementation
/// there. Calling it directly would put the entire handshake behind a platform
/// that CI does not have, and the sequence, the capability negotiation, the
/// framing and every error path would go unchecked.
///
/// `WisqNet.SHA256` made that mistake in the other direction and carried it a
/// long time: it *returned* empty `Data` without CryptoKit, so a digest built on
/// it passed its tests by agreeing with itself about nothing. That one has since
/// been given a real fallback, because SHA-256 is arithmetic anyone can write
/// down. RSA-OAEP is not, so a seam is the way out here rather than a second
/// implementation — and the seam buys the same thing the fallback bought there:
/// a Linux runner that can go red.
public typealias SpiceTicketEncryptor =
    @Sendable (_ password: String, _ publicKey: [UInt8]) throws -> Data

public enum SpiceTicket {
    /// The real one: RSA-OAEP with SHA-1, which is what every SPICE server
    /// expects and is not a choice this client gets to make.
    ///
    /// The password is NUL-terminated and padded to the ticket length before
    /// encryption, as the protocol specifies.
    public static let platform: SpiceTicketEncryptor = { password, publicKey in
        #if canImport(Security)
        let clear = clearText(password)

        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        // The 162 bytes are a DER SubjectPublicKeyInfo, which is what
        // `SecKeyCreateWithData` wants when told the key is RSA public.
        guard let key = SecKeyCreateWithData(
            Data(publicKey) as CFData, attributes as CFDictionary, &error
        ) else {
            throw SpiceError.ticketUnavailable
        }
        guard let encrypted = SecKeyCreateEncryptedData(
            key, .rsaEncryptionOAEPSHA1, Data(clear) as CFData, &error
        ) else {
            throw SpiceError.ticketUnavailable
        }
        return encrypted as Data
        #else
        // No RSA here. The link cannot complete against a real server on this
        // platform, and saying so is better than sending something a server
        // would reject with "invalid data".
        _ = (password, publicKey)
        throw SpiceError.ticketUnavailable
        #endif
    }

    /// The password field a SPICE ticket carries, before encryption.
    static let ticketLength = 128

    /// What actually goes through RSA: the password and one NUL, nothing more.
    ///
    /// **This used to be padded to 128 bytes, and that could never work.** The
    /// ticket the server reads is 128 bytes because that is the size of a
    /// 1024-bit RSA modulus — it is the size of the *ciphertext*. OAEP with
    /// SHA-1 leaves 128 − 2×20 − 2 = 86 bytes for the plaintext, so handing it
    /// 128 was asking a 128-byte key to carry 128 bytes of payload plus its own
    /// padding. `SecKeyCreateEncryptedData` refuses, the client throws
    /// `ticketUnavailable`, and every password-protected SPICE desktop was
    /// unreachable.
    ///
    /// Nothing caught it because nothing here had ever spoken to a SPICE server:
    /// the unit tests inject their own encryptor, and the seam above says in as
    /// many words that it exists so a Linux runner can go red. It never ran.
    /// `SPICELiveDesktopTests` is that runner, and this is what it found.
    ///
    /// The reference client does the same thing — spice-gtk encrypts
    /// `strlen(passwd) + 1` bytes — and the server compares the decrypted string
    /// against its own, so trailing padding was never wanted in the first place.
    /// The truncation stays: SPICE's own limit is sixty characters, and 86 is
    /// what OAEP allows here.
    public static func clearText(_ password: String) -> [UInt8] {
        var clear = [UInt8](Array(password.utf8).prefix(maximumPasswordBytes))
        clear.append(0)
        return clear
    }

    /// 128 − 2×20 − 2, the most OAEP-SHA1 fits through a 1024-bit key, minus the
    /// NUL. SPICE's own maximum is sixty; this is the arithmetic bound.
    static let maximumPasswordBytes = 85
}

/// The SPICE link handshake, over any byte stream.
///
/// Split from the session for the same reason `SpiceWire` is split from this:
/// the session owns a socket and a lifecycle, and neither is needed to check
/// that the client sends the right bytes in the right order and refuses the
/// wrong answers. Driven here by a scripted server in memory.
struct SpiceLink {
    let stream: ByteStream
    let encryptTicket: SpiceTicketEncryptor

    struct Outcome: Equatable {
        var commonCaps: [UInt32]
        var channelCaps: [UInt32]
    }

    /// Opens one channel. Returns what the server said it can do.
    ///
    /// The order is the protocol's and is not negotiable: link message, link
    /// reply, ticket, result. A server that is asked for the ticket before it
    /// has offered its key has nothing to decrypt with.
    func open(
        channel: SpiceWire.Channel, channelID: UInt8 = 0,
        connectionID: UInt32 = 0, password: String,
        commonCaps: [UInt32] = [], channelCaps: [UInt32] = []
    ) async throws -> Outcome {
        try await stream.write(
            SpiceWire.linkRequest(
                connectionID: connectionID, channel: channel, channelID: channelID,
                commonCaps: commonCaps, channelCaps: channelCaps
            )
        )

        let headerBytes = try await stream.read(exactly: SpiceWire.headerBytes)
        let size = try SpiceWire.decodeLinkHeader(headerBytes)
        let reply = try SpiceWire.decodeLinkReply(try await stream.read(exactly: size))
        guard reply.error == .ok else { throw SpiceError.refused(reply.error) }

        try await stream.write(try encryptTicket(password, reply.publicKey))

        // The result is a bare little-endian word with no header of its own,
        // which is the one place the protocol departs from its own framing.
        var reader = SpiceWire.Reader(try await stream.read(exactly: 4))
        let result = try reader.u32()
        guard let outcome = SpiceWire.LinkError(rawValue: result) else {
            throw SpiceError.invalidData
        }
        guard outcome == .ok else { throw SpiceError.refused(outcome) }

        return Outcome(commonCaps: reply.commonCaps, channelCaps: reply.channelCaps)
    }
}
