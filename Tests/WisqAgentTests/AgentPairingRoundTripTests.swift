#if os(macOS) || os(Linux)
import XCTest
import WisqCore
import WisqRemote

/// The token, from the daemon's own link to a request the daemon accepts.
///
/// Two hand-written codecs face each other here. On the way out,
/// `pairing::percent_encode` in Rust — an allowlist of RFC 3986 unreserved
/// characters, everything else `%XX`. On the way in, `URLComponents` as
/// `AgentPairing.parse` uses it. Both halves were already tested, and that was
/// the problem: Rust asserted its output contained `token=a%20b%26c%3Dd`, Swift
/// asserted that parsing a hand-written URL gave back `a&b=c d/é+?#`. Each half
/// agreed with a string someone typed. Neither had ever met the other.
///
/// `AgentEndToEndTests` looked like it closed that gap and does not: it starts
/// the daemon with `--token secret-token` and authenticates with the same
/// literal, so the link is never read. `secret-token` is also the wrong probe —
/// it is letters and a hyphen, all unreserved, so it crosses `percent_encode`
/// unchanged and would still round-trip if the function returned its argument.
///
/// The fingerprint half of the link is already checked end to end, by
/// `AgentTLSTests` and `ConsoleResolverTests`, against the real daemon. This is
/// the field that was left.
final class AgentPairingRoundTripTests: XCTestCase {
    /// One character from each class that decides something: `&` and `=` end a
    /// query value, ` ` is not legal in a URL at all, `/` and `+` and `?` and
    /// `#` each mean something to some parser, and `é` is two bytes rather than
    /// one — the case a codec written over `chars` instead of `bytes` gets
    /// wrong. A generated token is `[a-z0-9]{32}` and touches none of it, but
    /// `--token` is a documented option and `scripts/install.sh` mentions it.
    private static let hostileToken = "a&b=c d/é+?#"

    private var agent: RustAgentProcess!

    /// The daemon is torn down here rather than by a `defer` in each test.
    /// `RustAgentProcess.stop` says why: these tests are `async`, so a `defer`
    /// would run `waitUntilExit()` on a concurrency worker, where it spins
    /// forever instead of returning.
    override func setUpWithError() throws {
        agent = try RustAgentProcess(token: Self.hostileToken)
    }

    override func tearDown() {
        agent?.stop()
        agent = nil
    }

    /// The value as it appears in the link, still encoded.
    private func rawTokenField(of link: URL) throws -> String {
        let query = try XCTUnwrap(link.query, link.absoluteString)
        let field = query
            .split(separator: "&")
            .first { $0.hasPrefix("token=") }
        return String(try XCTUnwrap(field, query).dropFirst("token=".count))
    }

    func testAHostileTokenSurvivesTheDaemonsOwnLinkAndStillAuthenticates() async throws {
        let link = try XCTUnwrap(agent.pairingURLs.first, agent.startupOutput)
        let payload = try AgentPairing.parse(link)

        // The encoding has to have done something, or the round trip below is
        // satisfied by a `percent_encode` that returns its argument and a
        // decoder that never decodes. This is the assertion that makes the next
        // one mean anything.
        let encoded = try rawTokenField(of: link)
        XCTAssertNotEqual(
            encoded, Self.hostileToken,
            "le jeton traverse le lien sans être encodé : \(link.absoluteString)"
        )

        XCTAssertEqual(payload.token, Self.hostileToken, "aller-retour du jeton : \(encoded)")

        // And the recovered token is the one the daemon compares against. The
        // link's `host` is the machine's LAN address, which a CI container
        // cannot dial; the port is the daemon's real one and is checked, then
        // the request goes to loopback with the parsed credential.
        XCTAssertEqual(payload.port, agent.baseURL.port, "le lien annonce le mauvais port")
        let paired = AgentClient(baseURL: agent.baseURL, token: payload.token)
        let vms = try await paired.listVMs()
        XCTAssertEqual(vms.map(\.id), ["debian-13", "win11"])
    }

    /// The failure a broken decoder actually produces: the still-encoded string
    /// handed over as the credential. Without this, "the request succeeded"
    /// would be weak evidence — a daemon that accepted anything would give the
    /// same green.
    func testTheStillEncodedTokenIsRefused() async throws {
        let link = try XCTUnwrap(agent.pairingURLs.first, agent.startupOutput)
        let encoded = try rawTokenField(of: link)

        do {
            _ = try await AgentClient(baseURL: agent.baseURL, token: encoded).listVMs()
            XCTFail("le jeton non décodé (\(encoded)) doit être refusé")
        } catch let error as WisqError {
            guard case .agentFailure = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        }
    }

    /// There is deliberately no test for a fingerprint that needs encoding.
    ///
    /// `fp` is the one field `pairing::urls` appends without `percent_encode`,
    /// which reads like an oversight and is not reachable as one: the value
    /// comes from `tls::fingerprint_hex`, which writes a SHA-256 digest with
    /// `{byte:02x}` and can produce nothing but 64 characters of `[0-9a-f]`.
    /// Every one of them is unreserved, so encoding them would be the identity.
    ///
    /// A test passing a hostile fingerprint would have to call `urls` directly
    /// with a string no caller can construct, and would then be pinning a
    /// behaviour of a branch that does not exist rather than a property of the
    /// program. The guard that keeps this true is `AgentPairing.parse`, which
    /// refuses any `fp` that is not exactly 32 hex bytes — tested in
    /// `AgentPairingTests` — so a fingerprint that needed encoding would be
    /// rejected on arrival rather than silently mangled.
}
#endif
