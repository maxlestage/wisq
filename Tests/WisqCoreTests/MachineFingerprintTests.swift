import Foundation
import XCTest

@testable import WisqCore

/// The first two steps of "le vrai épinglage du chemin machine": a saved
/// machine can carry a fingerprint, and what it says about itself follows
/// from whether it does. The third step — reading the fingerprint off the
/// connection and showing it to the person accepting it — needs
/// `Network.framework` and is not here.
final class MachineFingerprintTests: XCTestCase {
    private let fingerprint = Data(repeating: 0x5A, count: 32)

    /// Every library written before the field existed: the key is absent,
    /// and absent decodes to nil rather than to a refusal that would cost
    /// the machine (#78).
    func testAMachineSavedBeforeTheFieldExistedDecodesWithoutOne() throws {
        let json = """
            {"id":"11111111-1111-1111-1111-111111111111","name":"nas","host":"nas.local",
             "port":5900,"proto":"vnc","security":"tlsPinned","guestOS":"linux","tags":[],
             "createdAt":"2026-01-01T00:00:00Z","display":{},"input":{}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let machine = try decoder.decode(Machine.self, from: Data(json.utf8))
        XCTAssertNil(machine.certificateFingerprint)
        XCTAssertEqual(machine.security, .tlsPinned)
        XCTAssertEqual(machine.resolvedSecurity, .systemValidated, "sans empreinte, .tlsPinned vaut TLS")
        XCTAssertFalse(machine.pinsCertificate)
    }

    func testTheFingerprintSurvivesTheRoundTripByteForByte() throws {
        let machine = Machine(
            name: "nas", host: "nas.local", security: .tlsPinned, certificateFingerprint: fingerprint)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Machine.self, from: try encoder.encode(machine))
        XCTAssertEqual(back.certificateFingerprint, fingerprint)
        XCTAssertEqual(back.resolvedSecurity, .pinned(fingerprint))
        XCTAssertTrue(back.pinsCertificate)
    }

    // MARK: - What the machine says about itself

    /// #70 in its final form: the mode alone is a wish. The words come from
    /// what the connection will check, so the same `.tlsPinned` reads as a
    /// pin on one machine and as system validation on another.
    func testTheDescriptionFollowsTheFactNotTheMode() {
        let wished = Machine(name: "a", host: "a.local", security: .tlsPinned)
        XCTAssertFalse(wished.transportDescription.contains("épinglé"), wished.transportDescription)
        XCTAssertTrue(wished.transportDescription.contains("aucune empreinte"), wished.transportDescription)

        let pinned = Machine(
            name: "b", host: "b.local", security: .tlsPinned, certificateFingerprint: fingerprint)
        XCTAssertTrue(pinned.transportDescription.hasPrefix("TLS épinglé"), pinned.transportDescription)
        XCTAssertTrue(pinned.transportDescription.contains("5A:5A:5A:5A"), "les premiers octets, pour reconnaître l'empreinte")

        XCTAssertEqual(Machine(name: "c", host: "c.local", security: .tls).transportDescription, "TLS")
        XCTAssertEqual(Machine(name: "d", host: "d.local", security: .none).transportDescription, "Aucun chiffrement")
    }

    /// A fingerprint on a machine that did not ask for a pin is inert: the
    /// mode decides, and plain TLS with a stray fingerprint is still plain TLS.
    func testAFingerprintUnderAnotherModeDoesNotPin() {
        let machine = Machine(
            name: "e", host: "e.local", security: .tls, certificateFingerprint: fingerprint)
        XCTAssertEqual(machine.resolvedSecurity, .systemValidated)
        XCTAssertFalse(machine.pinsCertificate)
    }
}
