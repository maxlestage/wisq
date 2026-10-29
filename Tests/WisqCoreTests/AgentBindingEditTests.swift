import Foundation
import XCTest

@testable import WisqCore

/// **Une édition ne fait jamais descendre une liaison d'agent en clair.**
///
/// L'éditeur reconstruisait la liaison en `http`, sans empreinte : changer le
/// nom d'une machine appairée par un lien `wisq://agent?…&fp=…` suffisait pour
/// que le jeton parte en clair. `AgentBinding.edited` est la règle, et ces
/// tests la tiennent.
final class AgentBindingEditTests: XCTestCase {
    let fingerprint = Data(repeating: 0xAB, count: 32)

    func paired() -> AgentBinding {
        AgentBinding(baseURL: URL(string: "https://nas.local:7442")!, vmIdentifier: "debian",
                     autoStart: true, credentialRef: "agent.nas.local:7442", certificateFingerprint: fingerprint)
    }

    /// Même hôte, même port : `https` et l'empreinte restent.
    func testTheSameEndpointKeepsTLSAndThePin() throws {
        let edited = try XCTUnwrap(AgentBinding.edited(
            from: paired(), at: ("nas.local", 7442), vmIdentifier: "debian",
            autoStart: false, credentialRef: "agent.nas.local:7442"))
        XCTAssertEqual(edited.baseURL.absoluteString, "https://nas.local:7442")
        XCTAssertEqual(edited.certificateFingerprint, fingerprint)
        XCTAssertFalse(edited.autoStart, "ce que l'éditeur change, lui, change")
    }

    /// Une autre adresse : `https` reste, l'empreinte de l'ancienne part.
    func testAnotherEndpointStaysTLSWithoutTheOldPin() throws {
        let edited = try XCTUnwrap(AgentBinding.edited(
            from: paired(), at: ("nas2.local", 7443), vmIdentifier: "debian",
            autoStart: true, credentialRef: "agent.nas2.local:7443"))
        XCTAssertEqual(edited.baseURL.scheme, "https", "jamais en clair par une édition")
        XCTAssertNil(edited.certificateFingerprint)
    }

    /// Une liaison d'avant 0.3, en `http`, le reste ; une nouvelle aussi.
    func testPlainBindingsStayPlain() throws {
        let old = AgentBinding(baseURL: URL(string: "http://nas.local:7442")!, vmIdentifier: "vm")
        XCTAssertEqual(AgentBinding.edited(from: old, at: ("nas.local", 7442), vmIdentifier: "vm",
                                           autoStart: true, credentialRef: "r")?.baseURL.scheme, "http")
        XCTAssertEqual(AgentBinding.edited(from: nil, at: ("fd00::1", 7442), vmIdentifier: "vm",
                                           autoStart: true, credentialRef: "r")?.baseURL.absoluteString,
                       "http://[fd00::1]:7442")
    }
}
