import XCTest
@testable import WisqCore

/// Le bureau de la machine locale : voir `LocalDesktop`.
final class LocalDesktopTests: XCTestCase {
    /// **La boucle locale, en VNC, sans rien à demander** : c'est là qu'écoute
    /// le port relayé, et rien ne quitte le téléphone.
    func testTheDesktopIsAPlainVNCOnLoopback() {
        let desktop = LocalDesktop.machine(port: 49_321, name: "Alpine")
        XCTAssertEqual(desktop.host, "127.0.0.1")
        XCTAssertEqual(desktop.port, 49_321)
        XCTAssertEqual(desktop.proto, .vnc)
        XCTAssertEqual(desktop.security, .none)
        XCTAssertNil(desktop.credentialRef, "aucun secret à aller chercher")
        XCTAssertNil(desktop.agent, "aucun agent à réveiller")
        XCTAssertEqual(desktop.name, "Alpine")
        XCTAssertEqual(LocalDesktop.guestPort, 5900)
        XCTAssertTrue(LocalDesktop.hint.contains("5900"))
    }
}
