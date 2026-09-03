import XCTest

@testable import WisqCore
@testable import WisqRemote

/// One question asked of both places that answer it: *can wisq open this
/// protocol?*
///
/// `RemoteProtocol.isImplemented` is what the machine editor prints under the
/// picker. `SessionFactory.makeSession` is what happens when someone taps
/// Connect. Nothing tied them together, and they had drifted: the label said
/// `self == .vnc` while the factory had been building SPICE sessions since
/// lot 5. The picker therefore offered « SPICE (bientôt) » for the console
/// that carries the clipboard, the file drop and the resize.
final class ImplementedProtocolsTests: XCTestCase {
    /// The label and the factory must agree about every protocol that exists,
    /// not about the two someone remembered to update.
    ///
    /// Walking `allCases` is the point: a protocol added later is covered the
    /// day it is added, and a protocol whose session starts working cannot
    /// stay greyed out in the editor.
    func testTheLabelAndTheFactoryAgreeOnEveryProtocol() throws {
        for proto in RemoteProtocol.allCases {
            let machine = Machine(name: "m", host: "h", port: proto.defaultPort, proto: proto)
            var opens = true
            do {
                _ = try SessionFactory.makeSession(
                    machine: machine, credentials: EphemeralCredentialStore()
                )
            } catch let error as WisqError {
                guard case .unsupportedProtocol(let refused) = error else { throw error }
                XCTAssertEqual(
                    refused, proto,
                    "la fabrique a refusé \(proto.displayName) en nommant \(refused.displayName)")
                opens = false
            }
            XCTAssertEqual(
                opens, proto.isImplemented,
                """
                \(proto.displayName) : l'éditeur annonce \
                \(proto.isImplemented ? "disponible" : "« bientôt »") \
                et la fabrique \(opens ? "ouvre une session" : "refuse").
                """)
        }
    }

    /// And the state of the world today, written out rather than derived, so
    /// that a change to *both* sides at once still has to be deliberate: a
    /// refactor that made `isImplemented` return `false` everywhere would pass
    /// the test above and fail this one.
    func testSpiceAndVNCOpenAndRDPDoesNot() {
        XCTAssertTrue(RemoteProtocol.vnc.isImplemented)
        XCTAssertTrue(RemoteProtocol.spice.isImplemented, "SPICE est fait depuis le lot 5")
        XCTAssertFalse(RemoteProtocol.rdp.isImplemented, "RDP attend une machine Apple")
    }
}
