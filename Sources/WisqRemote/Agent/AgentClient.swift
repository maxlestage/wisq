import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module in the open-source Foundation.
import FoundationNetworking
#endif
#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Security
#endif
import WisqCore

/// Client for the wisq host agent: a small daemon on the machine that actually runs
/// the VMs, so the phone can power one on before connecting to its console.
/// The wire format is documented in `docs/AGENT-PROTOCOL.md`.
public struct AgentClient: Sendable {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// A client pinned to the agent's certificate, as recorded at pairing.
    ///
    /// The trust model is the pairing link's: no CA, no chain, no name checks —
    /// the server is authentic exactly when the SHA-256 of the certificate it
    /// presents equals the fingerprint the link carried. Standard validation
    /// would be strictly worse here: it would reject every self-signed agent
    /// and accept any certificate a public CA would sign for the same name.
    public init(baseURL: URL, token: String?, pinnedFingerprint: Data) {
        self.baseURL = baseURL
        self.token = token
        #if canImport(CryptoKit) && canImport(Security)
        let configuration = URLSessionConfiguration.ephemeral
        self.session = URLSession(
            configuration: configuration,
            delegate: PinnedCertificateDelegate(fingerprint: pinnedFingerprint),
            delegateQueue: nil
        )
        #else
        // The open-source Foundation cannot evaluate server trust, so a pinned
        // client cannot exist there. Standard validation stays on, and it
        // rejects the agent's self-signed certificate: closed, with a blunter
        // error than Apple platforms give — never open, which is what quietly
        // ignoring the fingerprint would be.
        self.session = URLSession(configuration: .ephemeral)
        #endif
    }

    public func listVMs() async throws -> [AgentVM] {
        try await send(path: "vms", method: "GET", body: nil)
    }

    /// The identifier goes into a URL path, so it is checked here too and not
    /// only where the user typed it.
    ///
    /// `appendingPathComponent` escapes `?` and `#` but passes `/` and `..`
    /// straight through, and `URLSession` resolves `..` before sending — so an
    /// identifier could aim a request outside `/v1/vms/` entirely. The daemon
    /// answers 404 to all of it, which is why this was never a hole; what the
    /// check buys is that the client cannot send a request the other side is
    /// certain to refuse, including one built from a list a hostile agent
    /// handed it.
    public func start(vm id: String) async throws -> AgentVM {
        let identifier = try Validation.validatedVMIdentifier(id)
        return try await send(path: "vms/\(identifier)/start", method: "POST", body: nil)
    }

    public func stop(vm id: String, force: Bool = false) async throws -> AgentVM {
        let identifier = try Validation.validatedVMIdentifier(id)
        return try await send(path: "vms/\(identifier)/stop", method: "POST", body: ["force": force])
    }

    public func status(vm id: String) async throws -> AgentVM {
        let identifier = try Validation.validatedVMIdentifier(id)
        return try await send(path: "vms/\(identifier)", method: "GET", body: nil)
    }

    /// Waits for a VM to report `.running` and expose a console port.
    /// Polls rather than holding a socket open, because a phone loses the network
    /// every time it changes cell.
    public func waitUntilRunning(
        vm id: String,
        timeout: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2)
    ) async throws -> AgentVM {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let vm = try await status(vm: id)
            if vm.state == .running, vm.consolePort != nil { return vm }
            if vm.state == .stopped { throw WisqError.agentFailure("la VM s'est arrêtée pendant le démarrage") }
            try await Task.sleep(for: pollInterval)
        }
        throw WisqError.timedOut
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WisqError.agentFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WisqError.agentFailure("réponse non HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(AgentErrorBody.self, from: data))?.error
            throw WisqError.agentFailure(message ?? "HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WisqError.agentFailure("réponse illisible : \(error.localizedDescription)")
        }
    }

    private struct AgentErrorBody: Decodable {
        let error: String
    }
}

#if canImport(CryptoKit) && canImport(Security)
/// Accepts exactly one server certificate: the one whose DER hashes to the
/// pinned fingerprint. Everything else — other certificates, other challenge
/// kinds — is rejected, and rejection cancels the connection rather than
/// falling back to the system's idea of trust.
private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate {
    private let fingerprint: Data

    init(fingerprint: Data) {
        self.fingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        guard Data(SHA256.hash(data: der)) == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
#endif
