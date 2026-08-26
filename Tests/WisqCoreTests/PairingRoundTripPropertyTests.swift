import XCTest

@testable import WisqCore

/// `AgentPairing`'s doc says the two sides of the wire live there "so generation
/// and parsing cannot drift apart". This is the test that makes the sentence
/// true instead of merely intended.
///
/// It was not: `url(for:)` wrote any fingerprint it was handed, while `parse`
/// has always demanded a 32-byte one. A payload carrying four bytes produced
/// `…&fp=aa11bb22` — a link the same type refuses.
final class PairingRoundTripPropertyTests: XCTestCase {
    private let realFingerprint = Data(repeating: 0x07, count: 32)

    /// The property, over every payload shape the type can hold.
    func testEveryLinkThisTypeProducesIsALinkItAccepts() throws {
        let payloads: [AgentPairing.Payload] = [
            .init(host: "nas.local"),
            .init(host: "nas.local", port: 1),
            .init(host: "nas.local", port: 65535),
            .init(host: "192.168.1.4", token: "jeton"),
            .init(host: "2001:db8::1", token: "a&b=c d/é+?#"),
            .init(host: "nas.local", token: nil, name: "Le NAS du salon"),
            .init(host: "nas.local", token: "jeton", name: "NAS", certificateFingerprint: realFingerprint),
            .init(host: "nas.local", certificateFingerprint: realFingerprint),
        ]
        for payload in payloads {
            let url = try XCTUnwrap(AgentPairing.url(for: payload), "aucun lien pour \(payload.host)")
            let parsed = try AgentPairing.parse(url)
            XCTAssertEqual(parsed, payload, "aller-retour perdu pour \(url.absoluteString)")
        }
    }

    /// The other half of the same property: what the type will not accept, it
    /// must not produce either.
    func testAFingerprintOfTheWrongLengthYieldsNoLinkAtAll() {
        for count in [0, 4, 31, 33, 64] {
            let payload = AgentPairing.Payload(
                host: "nas.local", certificateFingerprint: Data(repeating: 7, count: count))
            XCTAssertNil(
                AgentPairing.url(for: payload),
                "\(count) octets ont produit un lien que parse refuserait")
        }
    }

    /// And no link is not the same as a link without `fp`. The absent form means
    /// plain HTTP, so producing it here would turn a broken fingerprint into a
    /// silent downgrade — the very thing `parse` refuses at the other end.
    func testABrokenFingerprintIsNeverTurnedIntoAPlainHTTPLink() {
        let payload = AgentPairing.Payload(
            host: "nas.local", certificateFingerprint: Data([0xAA, 0x11, 0xBB, 0x22]))
        XCTAssertNil(AgentPairing.url(for: payload))
    }

    /// The control: the length both halves agree on is a SHA-256 digest, and a
    /// payload carrying one still makes a link.
    func testTheAgreedLengthIsThatOfASHA256Digest() throws {
        XCTAssertEqual(AgentPairing.fingerprintByteCount, 32)
        let payload = AgentPairing.Payload(host: "nas.local", certificateFingerprint: realFingerprint)
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        XCTAssertEqual(try AgentPairing.parse(url).certificateFingerprint, realFingerprint)
    }
}
