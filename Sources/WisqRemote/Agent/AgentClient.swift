import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module in the open-source Foundation.
import FoundationNetworking
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

    public func listVMs() async throws -> [AgentVM] {
        try await send(path: "vms", method: "GET", body: nil)
    }

    public func start(vm id: String) async throws -> AgentVM {
        try await send(path: "vms/\(id)/start", method: "POST", body: nil)
    }

    public func stop(vm id: String, force: Bool = false) async throws -> AgentVM {
        try await send(path: "vms/\(id)/stop", method: "POST", body: ["force": force])
    }

    public func status(vm id: String) async throws -> AgentVM {
        try await send(path: "vms/\(id)", method: "GET", body: nil)
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
