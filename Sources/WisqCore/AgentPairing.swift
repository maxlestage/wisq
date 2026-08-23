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

        public init(host: String, port: Int = 7442, token: String? = nil, name: String? = nil) {
            self.host = host
            self.port = port
            self.token = token
            self.name = name
        }
    }

    public static let scheme = "wisq"

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
        return Payload(host: host, port: port, token: values["token"], name: values["name"])
    }
}
