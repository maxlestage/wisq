import XCTest

@testable import WisqCore

/// The port wisq tries when a person types a host without one.
///
/// These are **measured numbers, not derived ones**, so a test is the only
/// place they can be held. SPICE used to say 5930 — the number in QEMU's
/// `-spice port=` examples — while a host built the way
/// `docs/TESTER-UBUNTU.md` describes listens on 5900: libvirt's `autoport`
/// allocates from 5900 upward, confirmed against a real libvirt driving a
/// real QEMU (`spice://localhost:5900`, then 5901 for a second VM, both
/// visible in `ss -ltn`).
final class DefaultPortTests: XCTestCase {
    func testTheDefaultPortsAreTheOnesHostsActuallyListenOn() {
        XCTAssertEqual(RemoteProtocol.vnc.defaultPort, 5900, "RFB : 5900 + écran, écran 0")
        XCTAssertEqual(
            RemoteProtocol.spice.defaultPort, 5900,
            "libvirt attribue les ports SPICE à partir de 5900, pas de 5930")
        XCTAssertEqual(RemoteProtocol.rdp.defaultPort, 3389, "RDP : port enregistré à l'IANA")
    }

}
