import Foundation

/// A certificate fingerprint as people paste it, and as the app shows it.
///
/// The bytes are what `NetworkByteStream` pins to: the SHA-256 of the leaf
/// certificate's DER, thirty-two of them. What arrives in the editor is
/// whatever a terminal printed — `openssl x509 -fingerprint -sha256` writes
/// `sha256 Fingerprint=AA:BB:…`, a browser shows the same in upper case with
/// colons, the agent's pairing link writes it in lower case with none — and
/// refusing any of those would be a refusal about typography rather than
/// about the certificate. The one thing that is refused is a length that is
/// not thirty-two bytes: that is not a fingerprint in a different coat, it is
/// not a fingerprint.
public enum CertificateFingerprint {
    /// SHA-256: exactly this many bytes. Shared with the pairing link, which
    /// carries the same kind of digest for the agent's certificate.
    public static let byteCount = AgentPairing.fingerprintByteCount

    /// The bytes, or nil unless the text holds exactly thirty-two bytes of
    /// hex once an `=`-prefixed label, colons and whitespace are set aside.
    public static func parse(_ text: String) -> Data? {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let label = digits.lastIndex(of: "=") {
            digits = digits[digits.index(after: label)...]
        }
        let cleaned = String(digits.filter { $0 != ":" && !$0.isWhitespace })
        guard let bytes = Hex.decode(cleaned), bytes.count == byteCount else { return nil }
        return bytes
    }

    /// `AA:BB:CC:…` — the form a person compares by eye against what a
    /// browser or `openssl` shows them.
    public static func format(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
