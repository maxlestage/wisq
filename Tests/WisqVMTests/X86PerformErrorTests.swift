import XCTest
@testable import WisqVM

/// **Le message d'une table inconnue**, construit hors de `perform` pour que
/// celle-ci n'ait pas à porter un cadre de pile à chaque instruction : le
/// déplacer ne devait rien changer à ce qu'il dit.
final class X86PerformErrorTests: XCTestCase {
    func testAnUnknownMapIsNamedInTheFault() {
        XCTAssertEqual(X86Core.unsupportedMap(.unknown(5)), .unsupported("la table unknown(5)"))
    }
}
