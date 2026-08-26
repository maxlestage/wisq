import Foundation
import XCTest

@testable import WisqCore

/// One rule about VM identifiers, kept by two implementations in two languages.
///
/// `crates/wisq-agent/src/service.rs` has refused anything outside an allowlist
/// since the slice that closed the argument-injection hole. Nothing else knew:
/// not `docs/AGENT-PROTOCOL.md`, which is the contract between the two sides,
/// and not the phone, which let you save a machine the agent would refuse for
/// as long as it existed and only said so at the first connection attempt.
///
/// The case list below is written **twice**, here and in `service.rs`'s
/// `the_two_sides_agree_on_what_an_identifier_may_be`. That is the point: a
/// rule two implementations keep separately is a rule that drifts, and the only
/// thing that stops it is the same fixtures on both sides.
final class VMIdentifierTests: XCTestCase {
    /// Refused. The leading dash is the one that mattered: `virsh start
    /// --version` is not a request to start a domain called `--version`.
    static let refused = [
        "",
        "-domaine",
        "--version",
        "mon domaine",
        "mon/domaine",
        "../../admin",
        "..",
        ".",
        "domaine;rm",
        "domaine\u{0000}",
        "café",
        "domaine?x=1",
        "domaine#f",
        "domaine@hôte",
    ]

    /// Accepted, and this half is not decoration. A rule that also refused
    /// these would stop people reaching VMs that exist: libvirt domain names
    /// really do look like this.
    static let accepted = [
        "debian",
        "debian-12",
        "debian_12",
        "debian.12",
        "DEBIAN",
        "vm0",
        "0",
        "a.b-c_d.9",
    ]

    func testWhatTheDaemonRefuses() {
        for id in Self.refused {
            XCTAssertThrowsError(try Validation.validatedVMIdentifier(id), id.debugDescription)
        }
    }

    func testWhatMustKeepWorking() throws {
        for id in Self.accepted {
            XCTAssertEqual(try Validation.validatedVMIdentifier(id), id, id.debugDescription)
        }
    }

    /// Surrounding whitespace is typing, not an identifier. It is trimmed and
    /// the rest is judged — so a name with a stray space around it works,
    /// while one with a space *inside* it does not.
    ///
    /// This is the one place the two sides deliberately differ, and it is not
    /// a drift: the daemon reads a path segment off the wire and must refuse a
    /// name with a newline in it, while this reads a text field and returns the
    /// **trimmed** value, which is what then goes on the wire. So the shared
    /// list is a list of already-trimmed cases; `"debian\n"` belongs here
    /// instead, where the answer is stated rather than assumed.
    func testSurroundingWhitespaceIsTrimmedRatherThanRefused() throws {
        XCTAssertEqual(try Validation.validatedVMIdentifier("  debian  "), "debian")
        XCTAssertEqual(try Validation.validatedVMIdentifier("debian\n"), "debian")
        XCTAssertThrowsError(try Validation.validatedVMIdentifier("deb ian"))
        XCTAssertThrowsError(try Validation.validatedVMIdentifier("deb\nian"))
    }

    /// 255 bytes is the daemon's limit, so both edges of it are held here.
    func testTheLengthLimitIsTheDaemonsAndBothSidesOfItAreHeld() throws {
        let atTheLimit = String(repeating: "a", count: 255)
        XCTAssertEqual(try Validation.validatedVMIdentifier(atTheLimit), atTheLimit)
        XCTAssertThrowsError(try Validation.validatedVMIdentifier(atTheLimit + "a"))
    }

    /// Counted in bytes, as the daemon counts them — but non-ASCII is refused
    /// before the length is ever the reason, which is what this pins.
    func testANonASCIINameIsRefusedForBeingNonASCIINotForItsLength() {
        XCTAssertThrowsError(try Validation.validatedVMIdentifier("é"))
    }
}
