import Foundation

/// An `.rdp` connection file, as Windows, Azure and every RDP gateway hand out.
///
/// Same reason as `VirtViewerFile`: the user already clicked something that
/// produced this file, and it holds the address, the port and the geometry.
/// Retyping is a chance to get it wrong.
///
/// The format is one option per line, `key:type:value`, where the type is `s`
/// for a string, `i` for an integer and `b` for binary. The value may itself
/// contain colons — `full address:s:[2001:db8::1]:3389` is a legal line and the
/// reason this is a parser rather than a `split(separator: ":")`.
public enum RemoteDesktopFile {
    public struct Connection: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var username: String?
        public var domain: String?
        public var width: Int?
        public var height: Int?
        public var fullScreen: Bool
        public var redirectClipboard: Bool

        public init(
            host: String, port: Int, username: String? = nil, domain: String? = nil,
            width: Int? = nil, height: Int? = nil,
            fullScreen: Bool = false, redirectClipboard: Bool = false
        ) {
            self.host = host
            self.port = port
            self.username = username
            self.domain = domain
            self.width = width
            self.height = height
            self.fullScreen = fullScreen
            self.redirectClipboard = redirectClipboard
        }
    }

    public enum Failure: Error, Equatable {
        case notARemoteDesktopFile
        case missingAddress
        case badPort(String)
        case badInteger(key: String, value: String)
    }

    /// RDP's registered port. Applied only when the file gives none — never as
    /// a stand-in for one that could not be read, which would connect somewhere
    /// the file did not name.
    public static let defaultPort = 3389

    public static func parse(_ text: String) throws -> Connection {
        var strings: [String: String] = [:]
        var integers: [String: Int] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Split into exactly three parts: the value keeps every colon it
            // has, which is what makes an address with a port — or an IPv6
            // literal — survive the parse.
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = String(parts[0]).lowercased()
            let type = String(parts[1]).lowercased()
            let value = String(parts[2])

            switch type {
            case "s":
                strings[key] = value
            case "i":
                // A type that does not match its value is a malformed file, not
                // an invitation to guess. `i` says the writer meant a number.
                guard let number = Int(value) else {
                    throw Failure.badInteger(key: key, value: value)
                }
                integers[key] = number
            default:
                // `b` is binary, and the only one that matters is the saved
                // password. It is not decoded, not stored, and not carried —
                // it is encrypted to the machine that wrote the file and would
                // be useless here even if it were.
                continue
            }
        }

        guard !strings.isEmpty || !integers.isEmpty else {
            throw Failure.notARemoteDesktopFile
        }
        guard let address = strings["full address"], !address.isEmpty else {
            throw Failure.missingAddress
        }

        let (host, port) = try splitAddress(address)
        return Connection(
            host: host,
            port: port,
            username: strings["username"].flatMap { $0.isEmpty ? nil : $0 },
            domain: strings["domain"].flatMap { $0.isEmpty ? nil : $0 },
            width: integers["desktopwidth"],
            height: integers["desktopheight"],
            // `screen mode id` is 1 for windowed and 2 for full screen.
            fullScreen: integers["screen mode id"] == 2,
            redirectClipboard: integers["redirectclipboard"] == 1
        )
    }

    /// Separates `host:port`, leaving an IPv6 literal intact.
    ///
    /// `[2001:db8::1]:3389` has five colons and only the last one separates a
    /// port. Splitting on the first — or on any colon without looking at the
    /// brackets — produces a host of `[2001` and a connection to nowhere.
    private static func splitAddress(_ address: String) throws -> (String, Int) {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            guard !rest.isEmpty else { return (host, defaultPort) }
            guard rest.hasPrefix(":") else { throw Failure.badPort(String(rest)) }
            return (host, try port(String(rest.dropFirst())))
        }
        // An unbracketed address with several colons is a bare IPv6 literal,
        // which carries no port: taking its last group as one would silently
        // truncate the address.
        let colons = address.filter { $0 == ":" }.count
        guard colons == 1, let separator = address.lastIndex(of: ":") else {
            return (address, defaultPort)
        }
        return (
            String(address[..<separator]),
            try port(String(address[address.index(after: separator)...]))
        )
    }

    private static func port(_ text: String) throws -> Int {
        guard let value = Int(text), (1...65535).contains(value) else {
            throw Failure.badPort(text)
        }
        return value
    }
}

/// Printed without anything that could be a credential.
///
/// `.rdp` files carry a username and a domain, which are not secrets but are
/// still someone's identity, and a saved password blob that is never read at
/// all. Descriptions end up in logs; this one carries the address and the
/// geometry and nothing about who is connecting.
extension RemoteDesktopFile.Connection: CustomStringConvertible {
    public var description: String {
        var parts = ["rdp://\(host):\(port)"]
        if let width, let height { parts.append("\(width)×\(height)") }
        if fullScreen { parts.append("plein écran") }
        if username != nil { parts.append("utilisateur : (présent, masqué)") }
        return parts.joined(separator: ", ")
    }
}
