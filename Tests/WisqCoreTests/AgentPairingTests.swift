import XCTest
@testable import WisqCore

final class AgentPairingTests: XCTestCase {
    func testRoundTrip() throws {
        let payload = AgentPairing.Payload(host: "nas.local", port: 7442, token: "abc123", name: "NAS")
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertEqual(try AgentPairing.parse(url), payload)
    }

    /// Tokens are random bytes; the URL layer must carry whatever they contain.
    func testFingerprintRoundTripsThroughTheLink() throws {
        let fingerprint = Data((0..<32).map { UInt8($0) })
        let payload = AgentPairing.Payload(
            host: "nas.local",
            token: "t",
            certificateFingerprint: fingerprint
        )
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertTrue(url.absoluteString.contains("fp=000102"), url.absoluteString)
        XCTAssertEqual(try AgentPairing.parse(url).certificateFingerprint, fingerprint)
    }

    func testLinkWithoutFingerprintStaysPlain() throws {
        let url = try XCTUnwrap(URL(string: "wisq://agent?host=nas&port=7442&token=t"))
        XCTAssertNil(try AgentPairing.parse(url).certificateFingerprint)
    }

    /// Dropping a bad fingerprint instead of failing would downgrade the
    /// connection to plain HTTP — the exact outcome an attacker mangling the
    /// link would be after.
    func testAMalformedFingerprintIsAnErrorNotADowngrade() {
        for bad in ["fp=abc", "fp=", "fp=zz" + String(repeating: "ab", count: 31),
                    "fp=" + String(repeating: "ab", count: 33)] {
            let url = URL(string: "wisq://agent?host=nas&\(bad)")!
            XCTAssertThrowsError(try AgentPairing.parse(url), bad)
        }
    }

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
