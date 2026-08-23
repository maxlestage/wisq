#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote
@testable import WisqAgentKit

/// The full loop: a real HTTP server on an ephemeral port, spoken to by the same
/// `AgentClient` the iPhone app uses. If these pass, the wire format documented
/// in docs/AGENT-PROTOCOL.md is what both sides actually implement.
final class AgentEndToEndTests: XCTestCase {
    private var server: HTTPServer!
    private var client: AgentClient!

    override func setUpWithError() throws {
        let service = AgentService(
            backend: DemoBackend(startupDelay: 0.05),
            token: "secret-token"
        )
        server = HTTPServer { service.handle($0) }
        try server.start(port: 0)
        client = AgentClient(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            token: "secret-token"
        )
    }

    override func tearDown() {
        server.stop()
    }

    func testListsVMs() async throws {
        let vms = try await client.listVMs()
        XCTAssertEqual(vms.map(\.id), ["debian-13", "win11"])
        XCTAssertEqual(vms[0].state, .stopped)
        XCTAssertEqual(vms[0].guestOS, .linux)
    }

    func testRejectsAMissingOrWrongToken() async throws {
        let anonymous = AgentClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        do {
            _ = try await anonymous.listVMs()
            XCTFail("l'accès sans jeton doit être refusé")
        } catch let error as WisqError {
            guard case .agentFailure = error else { return XCTFail("erreur inattendue : \(error)") }
        }
    }

    func testUnknownVMIs404WithAReadableMessage() async throws {
        do {
            _ = try await client.status(vm: "nope")
            XCTFail("une VM inconnue doit être une erreur")
        } catch let error as WisqError {
            guard case .agentFailure(let message) = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
            XCTAssertTrue(message.contains("nope"), "le message doit nommer la VM : \(message)")
        }
    }

    /// The boot flow the app runs: start, then poll until running — exactly what
    /// `waitUntilRunning` does against a real host.
    func testStartThenWaitUntilRunning() async throws {
        let started = try await client.start(vm: "debian-13")
        XCTAssertEqual(started.state, .starting)
        XCTAssertNil(started.consolePort, "pas de console avant la fin du démarrage")

        let running = try await client.waitUntilRunning(
            vm: "debian-13",
            timeout: .seconds(5),
            pollInterval: .milliseconds(20)
        )
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.consolePort, 5901)
        XCTAssertEqual(running.consoleProtocol, .vnc)
    }

    func testStopTearsDownTheConsole() async throws {
        _ = try await client.start(vm: "win11")
        _ = try await client.waitUntilRunning(vm: "win11", timeout: .seconds(5), pollInterval: .milliseconds(20))
        let stopped = try await client.stop(vm: "win11")
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.consolePort)
    }
}

final class HTTPParsingTests: XCTestCase {
    func testParsesARequestHead() {
        let head = Data("GET /v1/vms HTTP/1.1\r\nHost: nas.local\r\nAuthorization: Bearer abc\r\n\r\n".utf8)
        let parsed = HTTPServer.parseHead(head)
        XCTAssertEqual(parsed?.method, "GET")
        XCTAssertEqual(parsed?.path, "/v1/vms")
        XCTAssertEqual(parsed?.headers["authorization"], "Bearer abc", "les noms d'en-têtes sont insensibles à la casse")
    }

    func testStripsQueryStrings() {
        let head = Data("GET /v1/vms?verbose=1 HTTP/1.1\r\n\r\n".utf8)
        XCTAssertEqual(HTTPServer.parseHead(head)?.path, "/v1/vms")
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(HTTPServer.parseHead(Data("RFB 003.008\n".utf8)))
    }
}

final class VirshParsingTests: XCTestCase {
    func testDomstateMapping() {
        XCTAssertEqual(VirshBackend.parseDomstate("running\n"), .running)
        XCTAssertEqual(VirshBackend.parseDomstate(" shut off \n"), .stopped)
        XCTAssertEqual(VirshBackend.parseDomstate("paused"), .paused)
        XCTAssertEqual(VirshBackend.parseDomstate("quelque chose de neuf"), .unknown)
    }

    func testVNCDisplayToPort() {
        XCTAssertEqual(VirshBackend.parseVNCDisplay(":1\n"), 5901)
        XCTAssertEqual(VirshBackend.parseVNCDisplay("127.0.0.1:2"), 5902)
        XCTAssertNil(VirshBackend.parseVNCDisplay(""))
        XCTAssertNil(VirshBackend.parseVNCDisplay(nil))
    }
}
#endif
