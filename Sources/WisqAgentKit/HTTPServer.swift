#if os(macOS) || os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Minimal HTTP/1.1 server over POSIX sockets — no dependencies, by design.
///
/// The agent serves one phone on a home network; SwiftNIO would be nine
/// thousand files of solution for a problem this size. One thread accepts,
/// one short-lived thread per connection parses a request and writes a
/// response, `Connection: close` always.
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        public var path: String
        /// Header names lowercased; HTTP says they are case-insensitive.
        public var headers: [String: String]
        public var body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var contentType: String

        public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }

        public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Response(status: status, body: (try? encoder.encode(value)) ?? Data())
        }
    }

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1024 * 1024

    private let handler: @Sendable (Request) -> Response
    private var serverSocket: Int32 = -1
    private var acceptThread: Thread?
    private let stateLock = NSLock()
    private var running = false

    /// The port actually bound — differs from the requested one when asking for 0.
    public private(set) var port: UInt16 = 0

    public init(handler: @escaping @Sendable (Request) -> Response) {
        self.handler = handler
    }

    /// Binds and starts accepting. Pass port 0 for an ephemeral port (tests).
    public func start(port requestedPort: UInt16) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !running else { return }

        // A peer hanging up mid-write must not kill the daemon.
        signal(SIGPIPE, SIG_IGN)

        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else { throw AgentError("socket() a échoué (errno \(errno))") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw AgentError("bind() sur le port \(requestedPort) a échoué (errno \(errno))")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw AgentError("listen() a échoué (errno \(errno))")
        }

        // Read back the port the kernel actually assigned.
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: boundAddress.sin_port)

        serverSocket = fd
        running = true

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "wisq-agent-accept"
        thread.start()
        acceptThread = thread
    }

    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard running else { return }
        running = false
        // Closing the socket makes the blocked accept() return with an error.
        close(serverSocket)
        serverSocket = -1
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else {
                if isRunning { continue }
                return
            }
            let thread = Thread { [handler] in
                HTTPServer.serve(client: client, handler: handler)
            }
            thread.start()
        }
    }

    private static func serve(client: Int32, handler: (Request) -> Response) {
        defer { close(client) }
        guard let request = readRequest(from: client) else {
            write(status: 400, body: Data(#"{"error":"requête illisible"}"#.utf8),
                  contentType: "application/json", to: client)
            return
        }
        let response = handler(request)
        write(status: response.status, body: response.body,
              contentType: response.contentType, to: client)
    }

    // MARK: - Wire I/O

    private static func readRequest(from fd: Int32) -> Request? {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)

        // Head: read until the blank line.
        var headEnd: Int?
        while headEnd == nil {
            let count = read(fd, &scratch, scratch.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: scratch[0..<count])
            headEnd = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound
            if buffer.count > maxHeaderBytes { return nil }
        }
        guard let headEnd,
              let parsed = parseHead(Data(buffer[buffer.startIndex..<headEnd])) else { return nil }

        // Body: honour Content-Length, refuse anything oversized.
        let contentLength = Int(parsed.headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
        var body = Data(buffer[headEnd...])
        while body.count < contentLength {
            let count = read(fd, &scratch, min(scratch.count, contentLength - body.count))
            guard count > 0 else { return nil }
            body.append(contentsOf: scratch[0..<count])
        }

        return Request(
            method: parsed.method,
            path: parsed.path,
            headers: parsed.headers,
            body: body.prefix(contentLength)
        )
    }

    /// Parses the request line and headers. Pure, so it is testable off-socket.
    static func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)[...]
        guard let requestLine = lines.popFirst() else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(parts[0])
        // Strip any query string; the agent's routes carry none.
        let path = String(parts[1].split(separator: "?", maxSplits: 1)[0])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (method, path, headers)
    }

    private static func write(status: Int, body: Data, contentType: String, to fd: Int32) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Glibc)
                let written = Glibc.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                #else
                let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                #endif
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

/// Operational failure inside the agent, surfaced to the client as the JSON
/// `error` body the protocol documents.
public struct AgentError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
#endif
