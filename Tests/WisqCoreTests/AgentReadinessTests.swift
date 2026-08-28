import Foundation
import XCTest

@testable import WisqCore

/// When a VM is ready for a console, and when it only looks it.
///
/// The rule has two halves and the second is the one that is easy to drop:
/// `running` **and** a console port. A running VM with no port is not a
/// contradiction, it is what every real boot looks like for a while — libvirt
/// reports a domain as `running` the moment it exists, and `virsh vncdisplay`
/// has nothing to say until the guest has brought up its display.
///
/// The rule used to live inside `AgentClient.waitUntilRunning`'s polling loop,
/// where nothing could reach it. The end-to-end suite drives the daemon's demo
/// backend, which walks `stopped → starting → running` with a port attached at
/// the same instant — so the state that matters here never occurs there, and
/// the suite that looks like it covers the boot flow cannot see this at all.
final class AgentReadinessTests: XCTestCase {
    private func vm(_ state: AgentVM.State, port: Int?) -> AgentVM {
        AgentVM(
            id: "debian-13", name: "Debian 13", state: state,
            consoleProtocol: port == nil ? nil : .vnc, consolePort: port
        )
    }

    func testAVMIsReadyWhenItIsRunningAndHasAPort() {
        XCTAssertTrue(vm(.running, port: 5901).isReadyForConsole)
    }

    /// The half a rule written from memory forgets, and the one a real libvirt
    /// produces on every boot.
    func testARunningVMWithNoPortIsNotReady() {
        XCTAssertFalse(
            vm(.running, port: nil).isReadyForConsole,
            "une VM en marche sans port de console ferait ouvrir une console sur rien"
        )
    }

    /// The other edge: nothing that is not running is ready, whatever port it
    /// happens to carry. A stale port on a stopped VM is exactly what a
    /// half-finished shutdown leaves behind.
    func testNothingElseIsReadyEvenWithAPort() {
        for state in [AgentVM.State.stopped, .paused, .starting, .unknown] {
            XCTAssertFalse(
                vm(state, port: 5901).isReadyForConsole,
                "\(state) avec un port ne doit pas être prête"
            )
        }
    }
}
