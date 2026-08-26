import Foundation

/// The project's one hexadecimal rendering, and the one that reads it back.
///
/// There is a single hex format on wisq's wire and it is not a choice made
/// here: the Rust agent writes `&fp=` into the pairing link with
/// `format!("{byte:02x}")` — lower case, no separator — and everything on the
/// phone side has to agree with that or the link does not survive the trip.
///
/// This exists because the agreement was being kept by coincidence. `AgentPairing`
/// had its own private renderer in that format, `WisqNet.SHA256.fingerprintString`
/// had another one in `AA:BB:CC`, and nothing connected them; two spellings of the
/// same 32 bytes, one of which no reader in this project would accept. A shared
/// implementation is what makes "the same format" a fact rather than a habit.
public enum Hex {
    /// Lower case, two characters per byte, no separator. The wire format.
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes, or nil if the text is not an even run of hex digits.
    ///
    /// Case-insensitive on the way in: a fingerprint read off a terminal and
    /// retyped in capitals is the same fingerprint, and refusing it would be a
    /// refusal about typography rather than about the certificate.
    public static func decode(_ text: String) -> Data? {
        let characters = Array(text.lowercased().utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
