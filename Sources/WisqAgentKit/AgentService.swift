#if os(macOS) || os(Linux)
import Foundation
import WisqCore

/// Routes the protocol documented in docs/AGENT-PROTOCOL.md onto a backend.
public struct AgentService: Sendable {
    private let backend: any VMBackend
    private let token: String

    public init(backend: any VMBackend, token: String) {
        self.backend = backend
        self.token = token
    }

    public func handle(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard isAuthorized(request) else {
            return errorResponse(status: 401, message: "jeton manquant ou invalide")
        }

        // Routes are /v1/vms[/{id}[/start|/stop]].
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1", parts.count >= 2, parts[1] == "vms" else {
            return errorResponse(status: 404, message: "route inconnue : \(request.path)")
        }

        do {
            switch (request.method, parts.count) {
            case ("GET", 2):
                return .json(try backend.list())

            case ("GET", 3):
                guard let vm = try backend.get(id: parts[2]) else {
                    return errorResponse(status: 404, message: "VM introuvable : \(parts[2])")
                }
                return .json(vm)

            case ("POST", 4) where parts[3] == "start":
                return .json(try backend.start(id: parts[2]))

            case ("POST", 4) where parts[3] == "stop":
                let force = (try? JSONDecoder().decode(StopBody.self, from: request.body))?.force ?? false
                return .json(try backend.stop(id: parts[2], force: force))

            case ("GET", _), ("POST", _):
                return errorResponse(status: 404, message: "route inconnue : \(request.path)")

            default:
                return errorResponse(status: 405, message: "méthode non autorisée")
            }
        } catch let error as AgentError {
            return errorResponse(status: 400, message: error.message)
        } catch {
            return errorResponse(status: 400, message: error.localizedDescription)
        }
    }

    private func isAuthorized(_ request: HTTPServer.Request) -> Bool {
        guard let header = request.headers["authorization"],
              header.hasPrefix("Bearer ") else { return false }
        // Constant-time-ish comparison is overkill for a LAN daemon, but cheap.
        return header.dropFirst("Bearer ".count) == token
    }

    private func errorResponse(status: Int, message: String) -> HTTPServer.Response {
        .json(ErrorBody(error: message), status: status)
    }

    private struct ErrorBody: Encodable {
        let error: String
    }

    private struct StopBody: Decodable {
        let force: Bool?
    }
}
#endif
