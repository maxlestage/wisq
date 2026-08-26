import Foundation

/// Input checks shared by the machine editor and by any import path (QR, URL scheme).
public enum Validation {
    /// Accepts hostnames, IPv4, IPv6 (with or without brackets) and `.local`
    /// names, and returns the **bare** host — brackets removed.
    ///
    /// The refusals below are not a list of characters that look suspicious.
    /// They are the characters that change what a host *means* once the caller
    /// pastes this string back into a URL, which is what every caller does:
    ///
    ///   * `@` ends the userinfo, so `real.local@evil.com` is a URL whose host
    ///     is `evil.com` — the list would show one machine and the connection
    ///     would open on another;
    ///   * `?` and `#` start the query and the fragment, so
    ///     `real.local?x=1` swallows the `:7442` that follows it and the
    ///     connection quietly goes to port 80;
    ///   * `/` and `\` end the authority;
    ///   * `[` and `]` are the IPv6 delimiters, and are stripped above rather
    ///     than carried through the middle of a name;
    ///   * whitespace and control characters have no place in a host, and a tab
    ///     or a newline is not caught by looking for a space — which is all
    ///     this function used to do.
    ///
    /// What must **not** be refused is the other half of the job: IPv4, IPv6
    /// with and without brackets, a trailing dot, and a non-ASCII name, which
    /// `URL` turns into its IDNA form. `HostValidationTests` holds both edges.
    public static func normalizedHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw WisqError.invalidHost(raw) }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { throw WisqError.invalidHost(raw) }
        guard !host.unicodeScalars.contains(where: isDelimiter) else {
            throw WisqError.invalidHost(raw)
        }
        return host
    }

    /// A scalar a host may not contain. See `normalizedHost`'s doc for why each
    /// one is here.
    private static func isDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7F {
            return true
        }
        return "@?#/\\[]".unicodeScalars.contains(scalar)
    }

    /// The URL for an agent at `host`, which is not the same string as `host`.
    ///
    /// An IPv6 literal has to go back inside brackets or the colons in it read
    /// as the port separator: `URL(string: "http://2001:db8::1:7442")` is
    /// **nil**, so before this existed the app could accept a pairing link for
    /// an IPv6 agent, store it, show it, and then refuse it with "Adresse
    /// invalide" at the moment of connecting. `normalizedHost` says it accepts
    /// IPv6; this is what makes that true of the caller too.
    ///
    /// Nil when the pieces do not make a URL — a host this function was handed
    /// without going through `normalizedHost` first, for instance.
    public static func agentURL(scheme: String, host: String, port: Int) -> URL? {
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(authority):\(port)")
    }

    public static func validatedPort(_ port: Int) throws -> Int {
        guard (1...65535).contains(port) else { throw WisqError.invalidPort(port) }
        return port
    }

    /// Parses `host`, `host:port` and `[::1]:port` into their parts.
    public static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
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
