import Foundation

/// Input checks shared by the machine editor and by any import path (QR, URL scheme).
public enum Validation {
    /// Accepts hostnames, IPv4, IPv6 (with or without brackets) and `.local` names.
    public static func normalizedHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw WisqError.invalidHost(raw) }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // No scheme, no path, no spaces: this is a bare host.
        guard !host.contains("/"), !host.contains(" ") else { throw WisqError.invalidHost(raw) }
        return host
    }

    public static func validatedPort(_ port: Int) throws -> Int {
        guard (1...65535).contains(port) else { throw WisqError.invalidPort(port) }
        return port
    }

    /// Parses `host`, `host:port` and `[::1]:port` into their parts.
    public static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("[") , let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }

        // A bare IPv6 literal has several colons; only split on the last one when
        // there is exactly one.
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return (trimmed, nil)
    }
}
