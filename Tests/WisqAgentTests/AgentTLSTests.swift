import XCTest
import WisqCore

/// The certificate story, checked against the real daemon: TLS is the default,
/// the fingerprint it announces is the one its links carry, and the app's
/// parser turns that link into the exact bytes the pinning compares.
///
/// The pinned URLSession handshake itself is exercised on Apple platforms; on
/// Linux, URLSession cannot override trust, so these tests stop at the link —
/// the handshake against a pinning client is covered by the Rust side's own
/// tests, which speak rustls-to-rustls over a real socket.
final class AgentTLSTests: XCTestCase {
    func testTheDefaultDaemonAnnouncesTLSAndLinksCarryItsFingerprint() throws {
        let agent = try RustAgentProcess(tls: true)
        defer { agent.stop() }

        let announced = agent.startupOutput
            .split(separator: "\n")
            .first { $0.contains("TLS : sha256 ") }
            .map { $0.replacingOccurrences(of: "TLS : sha256 ", with: "").trimmingCharacters(in: .whitespaces) }
        let fingerprint = try XCTUnwrap(announced, "le démon doit annoncer son empreinte")
        XCTAssertEqual(fingerprint.count, 64)

        let links = agent.pairingURLs
        XCTAssertFalse(links.isEmpty)
        for link in links {
            let payload = try AgentPairing.parse(link)
            let carried = try XCTUnwrap(payload.certificateFingerprint, link.absoluteString)
            XCTAssertEqual(
                carried.map { String(format: "%02x", $0) }.joined(),
                fingerprint,
                "le lien doit porter l'empreinte annoncée"
            )
        }
    }

    func testOptingOutOfTLSRemovesTheFingerprintFromLinks() throws {
        let agent = try RustAgentProcess(tls: false)
        defer { agent.stop() }

        XCTAssertTrue(agent.startupOutput.contains("TLS désactivé"))
        for link in agent.pairingURLs {
            XCTAssertNil(try AgentPairing.parse(link).certificateFingerprint, link.absoluteString)
        }
    }
}
