import Foundation

/// The pairing link an agent hands to the phone: `wisq://agent?host=…&port=…&token=…`.
///
/// One URL carries everything the app needs to talk to a daemon — printed in the
/// terminal, rendered as a QR code, or sent over any channel the user trusts.
/// Both sides of the wire live here so generation and parsing cannot drift apart.
public enum AgentPairing {
    public struct Payload: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var token: String?
        /// Display name for the host, purely cosmetic.
        public var name: String?
        /// SHA-256 of the agent's TLS certificate (DER), when the agent speaks
        /// TLS. Its presence is what switches the app to HTTPS and pins the
        /// connection to exactly that certificate — the link is the whole
        /// certificate story, the same way it is already the token story.
        public var certificateFingerprint: Data?

        public init(
            host: String,
            port: Int = 7442,
            token: String? = nil,
            name: String? = nil,
            certificateFingerprint: Data? = nil
        ) {
            self.host = host
            self.port = port
            self.token = token
            self.name = name
            self.certificateFingerprint = certificateFingerprint
        }
    }

    public static let scheme = "wisq"

    /// A certificate fingerprint is a SHA-256 digest: exactly this many bytes.
    ///
    /// Named because **both halves read from it**. `parse` refused any other
    /// length from the start — a malformed fingerprint is an error, never a
    /// shrug — while `url(for:)` would happily write one, so this type could
    /// produce a link it then refused. The doc above says the two sides live
    /// here so they cannot drift apart; a constant they share is what makes
    /// that true rather than merely intended.
    public static let fingerprintByteCount = 32

    /// The link for a payload, or nil when the payload cannot make a valid one.
    ///
    /// A fingerprint of the wrong length yields **no link at all**, rather than
    /// a link without `fp`. The absent-`fp` form is meaningful — it means plain
    /// HTTP — so emitting it here would turn a broken fingerprint into a silent
    /// downgrade, which is precisely what `parse` refuses to do at the other
    /// end.
    public static func url(for payload: Payload) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "agent"
        var items = [
            URLQueryItem(name: "host", value: payload.host),
            URLQueryItem(name: "port", value: String(payload.port)),
        ]
        if let token = payload.token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        if let name = payload.name, !name.isEmpty {
            items.append(URLQueryItem(name: "name", value: name))
        }
        if let fingerprint = payload.certificateFingerprint {
            guard fingerprint.count == fingerprintByteCount else { return nil }
            items.append(URLQueryItem(name: "fp", value: Hex.encode(fingerprint)))
        }
        components.queryItems = items
        return components.url
    }

    public static func parse(_ url: URL) throws -> Payload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == "agent" else {
            throw WisqError.malformedMessage("lien d'appairage invalide : \(url.absoluteString)")
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        guard let host = values["host"].flatMap({ try? Validation.normalizedHost($0) }) else {
            throw WisqError.malformedMessage("lien d'appairage sans hôte")
        }
        let port = try Validation.validatedPort(values["port"].flatMap(Int.init) ?? 7442)

        // A malformed fingerprint is an error, never a shrug: silently dropping
        // it would downgrade the connection to plain HTTP, which is exactly
        // what an attacker mangling the link would want.
        var fingerprint: Data?
        if let raw = values["fp"] {
            guard let parsed = Hex.decode(raw), parsed.count == fingerprintByteCount else {
                throw WisqError.malformedMessage("empreinte de certificat invalide dans le lien")
            }
            fingerprint = parsed
        }

        return Payload(
            host: host,
            port: port,
            token: values["token"],
            name: values["name"],
            certificateFingerprint: fingerprint
        )
    }
}
