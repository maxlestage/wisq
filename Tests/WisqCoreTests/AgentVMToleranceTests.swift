import Foundation
import XCTest

@testable import WisqCore

/// A VM this build does not understand used to cost the whole list.
///
/// `AgentVM` had **no tests at all**, and `listVMs` decodes `[AgentVM]` in one
/// call. So one machine reporting a state, a protocol or a guest OS this build
/// had never heard of did not cost that machine — it emptied the list.
///
/// The scenario is this project's own distribution model rather than a
/// hypothetical: the daemon is installed by Homebrew or a `curl` script and
/// updated independently of the sideloaded app. `brew upgrade` on the host, no
/// update on the phone, and "my VMs" goes blank.
///
/// Third time this exact shape has turned up — after `Settings` and
/// `MachineStore`. A habit rather than an accident, which is why the two edges
/// below are spelled out again: what falls back, and what must not.
final class AgentVMToleranceTests: XCTestCase {
    private func vm(_ json: String) throws -> AgentVM {
        try JSONDecoder().decode(AgentVM.self, from: Data(json.utf8))
    }

    private func list(_ json: String) throws -> [AgentVM] {
        try JSONDecoder().decode([AgentVM].self, from: Data(json.utf8))
    }

    // MARK: - What a newer agent may report

    /// The enum already had `.unknown`; the decoder simply never reached for it.
    func testAStateThisBuildDoesNotKnowBecomesUnknown() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"migrating"}"#).state, .unknown)
    }

    /// Found by probe rather than predicted: an **absent** state threw too.
    func testAnAbsentStateBecomesUnknownRatherThanThrowing() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n"}"#).state, .unknown)
    }

    func testAGuestOSThisBuildDoesNotKnowBecomesUnknown() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"running","guestOS":"plan9"}"#).guestOS, .unknown)
    }

    /// The consequence that made this worth fixing.
    func testOneUnreadableVMNoLongerEmptiesTheList() throws {
        let vms = try list(
            #"[{"id":"a","name":"bonne","state":"running"},"#
                + #"{"id":"b","name":"future","state":"migrating"}]"#)
        XCTAssertEqual(vms.map(\.name), ["bonne", "future"])
        XCTAssertEqual(vms.last?.state, .unknown)
    }

    // MARK: - The edge that must not fall back

    /// `consoleProtocol` decides what wisq speaks to the port the agent
    /// published. An unrecognised name becomes nil — "no console I know how to
    /// open" — and never `.vnc`, which would open a VNC session against
    /// something else entirely. Same asymmetry as `Machine.security`.
    func testAnUnknownConsoleProtocolBecomesNilRatherThanADefault() throws {
        let decoded = try vm(
            #"{"id":"a","name":"n","state":"running","consoleProtocol":"wayland","consolePort":5900}"#)
        XCTAssertNil(decoded.consoleProtocol, "un protocole inconnu ne doit pas devenir VNC")
        XCTAssertEqual(decoded.consolePort, 5900, "et le reste de la VM survit quand même")
    }

    /// And the VM is still listed: a console wisq cannot open is a VM the user
    /// may still want to see, and to start or stop.
    func testAVMWithAnUnopenableConsoleIsStillListed() throws {
        let vms = try list(
            #"[{"id":"a","name":"exotique","state":"running","consoleProtocol":"wayland"}]"#)
        XCTAssertEqual(vms.map(\.name), ["exotique"])
    }

    // MARK: - What must not change

    /// Every name this build knows still means itself. A fallback wide enough
    /// to swallow the unknown must not swallow the known — the half that makes
    /// the rest safe.
    func testEveryKnownNameStillMeansItself() throws {
        for state in [AgentVM.State.running, .paused, .stopped, .starting, .unknown] {
            XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"\#(state.rawValue)"}"#).state, state)
        }
        for proto in RemoteProtocol.allCases {
            XCTAssertEqual(
                try vm(#"{"id":"a","name":"n","state":"running","consoleProtocol":"\#(proto.rawValue)"}"#)
                    .consoleProtocol, proto)
        }
        for guest in GuestOS.allCases {
            XCTAssertEqual(
                try vm(#"{"id":"a","name":"n","state":"running","guestOS":"\#(guest.rawValue)"}"#).guestOS,
                guest)
        }
    }

    /// The fields that identify the VM are still required: a reply with no `id`
    /// is not a VM with a default name, it is a reply this client cannot use.
    func testAVMWithoutAnIdentityIsStillRefused() {
        XCTAssertThrowsError(try vm(#"{"name":"n","state":"running"}"#))
        XCTAssertThrowsError(try vm(#"{"id":"a","state":"running"}"#))
    }

    /// And a reply that is not a list at all still throws, rather than becoming
    /// an empty one — "you have no VMs" is a claim, and a wrong one here.
    func testAReplyThatIsNotAListStillThrows() {
        XCTAssertThrowsError(try list(#"{"vms":[]}"#))
    }

    /// A well-formed VM round-trips through encode and decode unchanged. The
    /// custom decoder is the only half that was rewritten, and this is what
    /// catches it drifting from the encoder the synthesis still provides.
    func testAFullVMSurvivesARoundTrip() throws {
        let original = AgentVM(
            id: "vm-1", name: "debian", state: .running,
            consoleProtocol: .vnc, consolePort: 5901, guestOS: .linux)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AgentVM.self, from: encoded), original)
    }
}
