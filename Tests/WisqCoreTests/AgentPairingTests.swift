import XCTest
@testable import WisqCore

final class AgentPairingTests: XCTestCase {
    func testRoundTrip() throws {
        let payload = AgentPairing.Payload(host: "nas.local", port: 7442, token: "abc123", name: "NAS")
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertEqual(try AgentPairing.parse(url), payload)
    }

    /// Tokens are random bytes; the URL layer must carry whatever they contain.
    func testTokenSurvivesURLHostileCharacters() throws {
        let payload = AgentPairing.Payload(host: "10.0.0.5", token: "a&b=c d/é+?#")
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertEqual(try AgentPairing.parse(url).token, "a&b=c d/é+?#")
    }

    func testPortDefaultsWhenAbsent() throws {
        let url = try XCTUnwrap(URL(string: "wisq://agent?host=nas.local"))
        XCTAssertEqual(try AgentPairing.parse(url).port, 7442)
    }

    func testRejectsForeignURLs() {
        XCTAssertThrowsError(try AgentPairing.parse(URL(string: "https://agent?host=x")!))
        XCTAssertThrowsError(try AgentPairing.parse(URL(string: "wisq://machine?host=x")!))
        XCTAssertThrowsError(try AgentPairing.parse(URL(string: "wisq://agent?port=7442")!))
        XCTAssertThrowsError(try AgentPairing.parse(URL(string: "wisq://agent?host=nas.local&port=99999")!))
    }
}
