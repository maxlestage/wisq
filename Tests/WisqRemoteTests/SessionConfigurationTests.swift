import Foundation
import WisqCore
import XCTest

@testable import WisqRemote

/// The configuration a saved machine asks for. One initialiser carries every
/// field the transport must see; a field added to `Machine` and forgotten
/// here would be saved, shown, and never used — which is what happened to
/// nothing yet, and what this file exists to keep that way.
final class SessionConfigurationTests: XCTestCase {
    func testAMachineIsCarriedWholeIntoItsConfiguration() {
        let fingerprint = Data(repeating: 0x33, count: 32)
        var display = DisplaySettings()
        display.keepScreenAwake = !display.keepScreenAwake
        let machine = Machine(
            name: "nas", host: "nas.local", port: 5901, proto: .spice, security: .tlsPinned,
            username: "max", display: display, certificateFingerprint: fingerprint)

        let configuration = SessionConfiguration(machine: machine, password: "secret")

        XCTAssertEqual(configuration.host, "nas.local")
        XCTAssertEqual(configuration.port, 5901)
        XCTAssertEqual(configuration.security, .tlsPinned)
        XCTAssertEqual(configuration.certificateFingerprint, fingerprint, "l'empreinte doit atteindre le transport")
        XCTAssertEqual(configuration.username, "max")
        XCTAssertEqual(configuration.password, "secret")
        XCTAssertEqual(configuration.display.keepScreenAwake, display.keepScreenAwake)
    }

    func testNoFingerprintAndNoPasswordStayAbsent() {
        let configuration = SessionConfiguration(
            machine: Machine(name: "x", host: "x.local", security: .tls), password: nil)
        XCTAssertNil(configuration.certificateFingerprint)
        XCTAssertNil(configuration.password)
        XCTAssertEqual(
            ResolvedTransportSecurity.resolve(configuration.security, fingerprint: configuration.certificateFingerprint),
            .systemValidated)
    }
}
