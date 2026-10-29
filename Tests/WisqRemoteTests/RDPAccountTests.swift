import XCTest

@testable import WisqRemote

/// **`DOMAINE\utilisateur` en ses deux champs.** Le paquet d'informations du
/// client a un champ pour le domaine et un pour l'utilisateur ; le compte
/// partait entier dans le second, le premier vide.
final class RDPAccountTests: XCTestCase {
    func testADomainAccountIsSplitIntoItsTwoFields() {
        XCTAssertEqual(RDPClientInfo.account("CORP\\jdoe").domain, "CORP")
        XCTAssertEqual(RDPClientInfo.account("CORP\\jdoe").user, "jdoe")
    }

    func testAPrincipalNameAndAPlainNameStayWhole() {
        XCTAssertEqual(RDPClientInfo.account("jdoe@corp.example").domain, "")
        XCTAssertEqual(RDPClientInfo.account("jdoe@corp.example").user, "jdoe@corp.example")
        XCTAssertEqual(RDPClientInfo.account("jdoe").user, "jdoe")
        XCTAssertEqual(RDPClientInfo.account("").user, "")
    }
}
