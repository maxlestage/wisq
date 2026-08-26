import Foundation
import XCTest

@testable import WisqCore

/// A host is validated, then pasted back into a URL where "host" no longer
/// means the same thing.
///
/// `normalizedHost` returns a **bare** host. Both callers that build an agent
/// URL then wrote `"\(scheme)://\(host):\(port)"`, and three separate things
/// came out of that one gap:
///
///   * `real.local@evil.com` passed, and the URL's host was `evil.com`;
///   * `real.local?x=1` passed, and the `:7442` after it became part of the
///     query — the connection went to port 80 without saying so;
///   * an IPv6 literal passed, brackets stripped, and made no URL at all, so a
///     pairing link for an IPv6 agent was accepted, stored and shown before
///     being refused with "Adresse invalide" at the moment of connecting.
///
/// The refusals below are the URL delimiters, not characters that merely look
/// suspicious. The second half of this file is the half that matters as much:
/// what must still be accepted.
final class HostValidationTests: XCTestCase {
    // MARK: - What changes the meaning of a host

    /// The one with teeth: the machine list shows the whole string, and the
    /// connection would open somewhere else entirely.
    func testAHostThatWouldRedirectTheConnectionIsRefused() {
        XCTAssertThrowsError(try Validation.normalizedHost("real.local@evil.com"))
        // The control that gives the refusal its meaning: this is what the URL
        // would have done with it.
        XCTAssertEqual(URL(string: "http://real.local@evil.com:7442")?.host, "evil.com")
    }

    /// And the one that changes the port rather than the host.
    func testAHostThatWouldSwallowThePortIsRefused() {
        XCTAssertThrowsError(try Validation.normalizedHost("real.local?x=1"))
        XCTAssertThrowsError(try Validation.normalizedHost("real.local#frag"))
        // Again the control: `:7442` lands inside the query, not in the port.
        XCTAssertNil(URL(string: "http://real.local?x=1:7442")?.port)
    }

    /// A tab and a newline are not spaces, and looking for a space was all this
    /// used to do.
    func testWhitespaceInsideAHostIsRefusedWhateverItsShape() {
        for host in ["real.local evil", "real.local\tevil", "real.local\nevil", "real\u{00A0}local"] {
            XCTAssertThrowsError(try Validation.normalizedHost(host), host.debugDescription)
        }
    }

    func testControlCharactersAreRefused() {
        XCTAssertThrowsError(try Validation.normalizedHost("nas\u{0000}.local"))
        XCTAssertThrowsError(try Validation.normalizedHost("nas\u{007F}.local"))
    }

    func testTheAuthorityCannotBeEndedEarly() {
        XCTAssertThrowsError(try Validation.normalizedHost("real.local/path"))
        XCTAssertThrowsError(try Validation.normalizedHost("real.local\\evil"))
    }

    /// Brackets are the IPv6 delimiters and belong at the ends or nowhere.
    func testBracketsInTheMiddleAreRefused() {
        XCTAssertThrowsError(try Validation.normalizedHost("real[evil].local"))
        XCTAssertThrowsError(try Validation.normalizedHost("[]"))
    }

    func testAnEmptyHostIsRefused() {
        XCTAssertThrowsError(try Validation.normalizedHost(""))
        XCTAssertThrowsError(try Validation.normalizedHost("   "))
    }

    // MARK: - What must not be refused

    /// Half the work of a rule is here. A refusal that also caught these would
    /// be a worse bug than the one it fixes: nobody can reach their machine.
    func testTheHostsThatMustStillBeAccepted() throws {
        XCTAssertEqual(try Validation.normalizedHost("nas.local"), "nas.local")
        XCTAssertEqual(try Validation.normalizedHost("  nas.local  "), "nas.local")
        XCTAssertEqual(try Validation.normalizedHost("192.168.1.4"), "192.168.1.4")
        XCTAssertEqual(try Validation.normalizedHost("NAS.Local"), "NAS.Local")
        XCTAssertEqual(try Validation.normalizedHost("nas.local."), "nas.local.")
        XCTAssertEqual(try Validation.normalizedHost("mon-nas-2.local"), "mon-nas-2.local")
        XCTAssertEqual(try Validation.normalizedHost("café.local"), "café.local")
        XCTAssertEqual(try Validation.normalizedHost("[2001:db8::1]"), "2001:db8::1")
        XCTAssertEqual(try Validation.normalizedHost("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(try Validation.normalizedHost("::1"), "::1")
    }

    // MARK: - The URL the caller actually needs

    /// The claim `normalizedHost` makes about IPv6, made true of its caller.
    func testAnIPv6AgentIsReachable() throws {
        let url = try XCTUnwrap(Validation.agentURL(scheme: "https", host: "2001:db8::1", port: 7442))
        XCTAssertEqual(url.host, "2001:db8::1")
        XCTAssertEqual(url.port, 7442)
        XCTAssertEqual(url.absoluteString, "https://[2001:db8::1]:7442")
    }

    /// The control: this is what the caller used to build, and it is nothing.
    func testTheUnbracketedFormMakesNoURLAtAll() {
        XCTAssertNil(URL(string: "https://2001:db8::1:7442"))
    }

    /// A name is not wrapped, and comes out with its port intact.
    func testANameIsLeftAlone() throws {
        let url = try XCTUnwrap(Validation.agentURL(scheme: "http", host: "nas.local", port: 7442))
        XCTAssertEqual(url.absoluteString, "http://nas.local:7442")
        XCTAssertEqual(url.host, "nas.local")
        XCTAssertEqual(url.port, 7442)
    }

    /// IPv4 has no colons, so it must not be bracketed either.
    func testAnIPv4AddressIsNotBracketed() throws {
        let url = try XCTUnwrap(Validation.agentURL(scheme: "http", host: "192.168.1.4", port: 80))
        XCTAssertEqual(url.absoluteString, "http://192.168.1.4:80")
    }

    /// The scheme is the caller's decision — a fingerprint means TLS — and it
    /// has to survive the trip.
    func testTheSchemeIsCarriedThrough() throws {
        XCTAssertEqual(
            try XCTUnwrap(Validation.agentURL(scheme: "https", host: "nas.local", port: 7442)).scheme,
            "https")
    }

    /// The whole chain, on the shape that used to fail at the last step: a
    /// pairing link for an IPv6 agent, parsed and turned into the URL the app
    /// connects to.
    func testAnIPv6PairingLinkSurvivesAllTheWayToItsURL() throws {
        let payload = AgentPairing.Payload(host: "[2001:db8::1]", port: 7442, token: "jeton")
        let url = try XCTUnwrap(AgentPairing.url(for: payload))
        let parsed = try AgentPairing.parse(url)
        let agent = try XCTUnwrap(
            Validation.agentURL(scheme: "http", host: parsed.host, port: parsed.port))
        XCTAssertEqual(agent.host, "2001:db8::1")
        XCTAssertEqual(agent.port, 7442)
    }
}
