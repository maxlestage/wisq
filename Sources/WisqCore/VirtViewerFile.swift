import Foundation

/// A `.vv` connection file, as virt-manager, oVirt and Proxmox hand it out.
///
/// The point of reading these is that the user has already done the work. They
/// clicked "console" somewhere, their browser downloaded a file, and it holds
/// the host, the port, the transport and a one-shot password. Retyping any of
/// that is a chance to get it wrong, and the password in particular is usually
/// a random string nobody can retype at all.
///
/// The format is an INI file with one section that must be `[virt-viewer]`.
/// Everything here is decoding: no file system, no network, so every rule below
/// is a test rather than a hope.
public enum VirtViewerFile {
    public struct Connection: Equatable, Sendable {
        public var proto: RemoteProtocol
        public var host: String
        public var port: Int
        public var security: TransportSecurity
        /// A one-shot ticket, usually. Held here and never printed: see
        /// `description`.
        public var password: String?
        /// The subject the server's certificate must carry, when the file names
        /// one. Carried through because dropping it silently downgrades a
        /// pinned connection to a trusting one.
        public var hostSubject: String?
        /// The file asked to be deleted after use. An instruction about *this*
        /// file, and nothing else.
        public var deleteAfterUse: Bool
        /// **The HTTP proxy the console goes through**, when the file names
        /// one (`proxy=http://pve:3128`). Proxmox always does: its `host` is
        /// a ticket only that proxy can read. oVirt may, for access from
        /// outside, beside a host that is reachable directly.
        public var proxy: Proxy?
        /// The certificate authority the server's certificate chains to, as
        /// PEM, when the file carries one (`ca=`). The file writes its line
        /// breaks as `\n`; they are real line breaks here.
        public var certificateAuthority: String?

        public init(
            proto: RemoteProtocol, host: String, port: Int,
            security: TransportSecurity, password: String? = nil,
            hostSubject: String? = nil, deleteAfterUse: Bool = false,
            proxy: Proxy? = nil, certificateAuthority: String? = nil
        ) {
            self.proto = proto
            self.host = host
            self.port = port
            self.security = security
            self.password = password
            self.hostSubject = hostSubject
            self.deleteAfterUse = deleteAfterUse
            self.proxy = proxy
            self.certificateAuthority = certificateAuthority
        }
    }

    /// An HTTP CONNECT proxy, the only kind virt-viewer files name.
    public struct Proxy: Equatable, Sendable, CustomStringConvertible {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        public var description: String { "\(host):\(port)" }

        /// `http://host:port`, `http://host` (port 3128, Proxmox's), or the
        /// same without the scheme. Any other scheme is refused rather than
        /// read as HTTP: a `https://` or `socks://` proxy is a different
        /// conversation, and pretending otherwise would connect somewhere the
        /// file did not mean.
        static func parse(_ raw: String) throws -> Proxy {
            var rest = Substring(raw)
            if let scheme = rest.range(of: "://") {
                guard rest[..<scheme.lowerBound].lowercased() == "http" else {
                    throw Failure.unsupportedProxy(raw)
                }
                rest = rest[scheme.upperBound...]
            }
            if rest.hasSuffix("/") { rest = rest.dropLast() }
            guard !rest.isEmpty, !rest.contains("/") else { throw Failure.unsupportedProxy(raw) }
            guard let colon = rest.lastIndex(of: ":") else { return Proxy(host: String(rest), port: 3128) }
            let host = String(rest[..<colon])
            let portText = String(rest[rest.index(after: colon)...])
            guard !host.isEmpty else { throw Failure.unsupportedProxy(raw) }
            guard let port = Int(portText), (1...65535).contains(port) else {
                throw Failure.badPort(portText)
            }
            return Proxy(host: host, port: port)
        }
    }

    public enum Failure: Error, Equatable {
        case notAVirtViewerFile
        case missingHost
        case missingPort
        case badPort(String)
        case unsupportedProtocol(String)
        /// A `proxy=` that is not an HTTP proxy, or not one at all.
        case unsupportedProxy(String)
    }

    /// Parses a `.vv` file.
    ///
    /// Unknown keys are ignored rather than refused: these files carry a long
    /// tail of options for features wisq does not have, and failing on the
    /// first one would reject perfectly good files for saying something extra.
    /// What is *malformed* — a port that is not a number — is refused, because
    /// substituting a default there would connect somewhere the file did not
    /// name.
    public static func parse(_ text: String) throws -> Connection {
        var values: [String: String] = [:]
        var inSection = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                // A second section ends the one that matters; these files do
                // not nest, and anything after is not ours to read.
                inSection = line.lowercased() == "[virt-viewer]"
                continue
            }
            guard inSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        guard !values.isEmpty else { throw Failure.notAVirtViewerFile }

        let named = values["type"]?.lowercased() ?? "spice"
        guard let proto = RemoteProtocol(rawValue: named) else {
            throw Failure.unsupportedProtocol(named)
        }

        guard let host = values["host"], !host.isEmpty else { throw Failure.missingHost }

        // `tls-port` wins when both are present: a file that offers TLS and
        // plain is offering a choice, and the encrypted one is the answer.
        let secure = values["tls-port"].flatMap { $0.isEmpty ? nil : $0 }
        let plain = values["port"].flatMap { $0.isEmpty ? nil : $0 }
        guard let chosen = secure ?? plain else { throw Failure.missingPort }
        guard let port = Int(chosen), (1...65535).contains(port) else {
            throw Failure.badPort(chosen)
        }

        return Connection(
            proto: proto,
            host: host,
            port: port,
            // A file naming a TLS port is a file asking for TLS. Where it also
            // names the subject the certificate must carry, that is a pinned
            // connection rather than a merely encrypted one.
            security: secure != nil
                ? (values["host-subject"] == nil ? .tls : .tlsPinned)
                : .none,
            password: values["password"].flatMap { $0.isEmpty ? nil : $0 },
            hostSubject: values["host-subject"].flatMap { $0.isEmpty ? nil : $0 },
            deleteAfterUse: ["1", "true", "yes"].contains(
                (values["delete-this-file"] ?? "").lowercased()
            ),
            proxy: try values["proxy"].flatMap { $0.isEmpty ? nil : try Proxy.parse($0) },
            certificateAuthority: values["ca"].flatMap {
                $0.isEmpty ? nil : $0.replacingOccurrences(of: "\\n", with: "\n")
            }
        )
    }
}

/// Printed without the password.
///
/// These structures end up in error messages and diagnostics, and the default
/// synthesised description would put a live console ticket in whatever a log is
/// written to. Not a hypothetical: it is the one field in the file that is a
/// secret, and it is the one a crash report would carry.
extension VirtViewerFile.Connection: CustomStringConvertible {
    public var description: String {
        var parts = ["\(proto.rawValue)://\(host):\(port)", "security: \(security.rawValue)"]
        if password != nil { parts.append("password: (présent, masqué)") }
        if let hostSubject { parts.append("host-subject: \(hostSubject)") }
        if deleteAfterUse { parts.append("à supprimer après usage") }
        if let proxy { parts.append("proxy: \(proxy)") }
        if certificateAuthority != nil { parts.append("autorité de certification fournie") }
        return parts.joined(separator: ", ")
    }
}
