#if canImport(Network)
import Foundation
import Network
import WisqCore

/// `ByteStream` over Network.framework, with optional TLS.
///
/// `NWConnection.receive(minimumIncompleteLength:maximumLength:)` already delivers
/// exactly N bytes when both bounds are N, so there is no reassembly buffer here.
public actor NetworkByteStream: ByteStream {
    private static let chunkSize = 64 * 1024

    private let connection: NWConnection
    private var isOpen = false
    private var buffer = Data()

    public init(host: String, port: Int, security: TransportSecurity, pinnedFingerprint: Data? = nil) throws {
        let host = try Validation.normalizedHost(host)
        let port = try Validation.validatedPort(port)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw WisqError.invalidPort(port)
        }

        let parameters: NWParameters
        switch security {
        case .none:
            parameters = .tcp
        case .tls:
            parameters = .tls
        case .tlsPinned:
            parameters = NetworkByteStream.pinnedParameters(fingerprint: pinnedFingerprint)
        }
        // The numbers live in `TransportTuning`, where a Linux runner can read
        // them; what is left here is the handful of assignments that need
        // Network.framework to exist.
        let tuning = TransportTuning.interactive
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = tuning.noDelay
            tcp.connectionTimeout = tuning.connectionTimeout
            tcp.enableKeepalive = tuning.keepaliveEnabled
            tcp.keepaliveIdle = tuning.keepaliveIdle
            tcp.keepaliveInterval = tuning.keepaliveInterval
            tcp.keepaliveCount = tuning.keepaliveCount
        }
        parameters.serviceClass = .responsiveData

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
    }

    /// Opens the connection, resolving once the peer is reachable.
    public func open() async throws {
        guard !isOpen else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: WisqError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: WisqError.connectionClosed) }
                case .waiting(let error):
                    // `.waiting` means no route yet; surface it instead of hanging
                    // on a phone that just lost Wi-Fi.
                    if once.claim() {
                        continuation.resume(throwing: WisqError.connectionFailed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        isOpen = true
        connection.stateUpdateHandler = nil
    }

    /// Reads from an internal buffer, topping it up with whatever the socket has
    /// ready. Framebuffer decoders ask for a few bytes at a time, so pulling up to
    /// 64 KiB per syscall matters more here than it would for a request/response
    /// protocol.
    ///
    /// **This is the implementation the protocol's one-reader rule is about.**
    /// The `await` sits inside the loop, with `buffer` read before it and
    /// mutated after, so two overlapping calls each take bytes from the other's
    /// run. `MemoryByteStream` never suspends inside its read and has no such
    /// window — same protocol, different precondition.
    ///
    /// Making this safe for several readers is a real change and not made here:
    /// `Network` is Apple-only, so it cannot be exercised from the Linux CI
    /// where the rest of this is proven, and an untested serialisation of reads
    /// would be a fix nothing could see break. `docs/ROADMAP.md` records what
    /// verifying it needs.
    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk(upTo: max(count - buffer.count, Self.chunkSize))
            buffer.append(chunk)
        }
        let head = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(head)
    }

    private func receiveChunk(upTo maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: WisqError.connectionFailed(error.localizedDescription))
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: isComplete ? WisqError.connectionClosed
                                                             : WisqError.malformedMessage("lecture vide"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: WisqError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        connection.cancel()
    }

    /// TLS parameters that accept whatever certificate the host presents on first
    /// use and pin it afterwards. Home labs run self-signed certs; refusing them
    /// outright would push people back to plaintext, which is worse.
    private static func pinnedParameters(fingerprint: Data?) -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false)
                    return
                }
                let presented = SHA256.digest(Data(SecCertificateCopyData(leaf) as Data))
                guard let fingerprint else {
                    // Trust on first use: the caller records `presented` and pins it.
                    complete(true)
                    return
                }
                complete(presented == fingerprint)
            },
            .global(qos: .userInitiated)
        )
        return NWParameters(tls: options)
    }
}
#endif
