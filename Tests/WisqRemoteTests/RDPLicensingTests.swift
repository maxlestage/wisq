#if canImport(Glibc)
import XCTest
import WisqCore

@testable import WisqRemote

/// L'étape de licence, jugée sur les octets d'un vrai serveur.
///
/// **C'est l'étape où une connexion RDP s'arrête sans rien dire.** Le serveur
/// envoie sa demande ; un client qui ne répond pas, ou qui prend l'alerte
/// « client valide » pour une panne, reste devant un écran vide. Les deux
/// messages testés ici sont ceux que xrdp a réellement envoyés.
final class RDPLicensingTests: XCTestCase {
    /// **Le vrai premier message est une demande.**
    func testARealLicenseRequestAsksForOne() throws {
        XCTAssertEqual(try RDPLicensing.read(RDPServerFixtures.licenseRequest), .wantsRequest)
    }

    /// **Et la vraie réponse à notre demande est un succès**, bien qu'elle
    /// arrive dans un message dont le type s'appelle « alerte d'erreur ».
    func testARealValidClientAlertFinishesTheStage() throws {
        XCTAssertEqual(try RDPLicensing.read(RDPServerFixtures.statusValidClient), .finished)
    }

    /// L'aléa du serveur est les trente-deux octets qui suivent le préambule.
    func testTheServerRandomIsTheThirtyTwoBytesAfterThePreamble() throws {
        let random = try XCTUnwrap(RDPLicensing.serverRandom(
            [UInt8](RDPServerFixtures.licenseRequest)))
        XCTAssertEqual(random.count, 32)
        XCTAssertEqual(random, Array([UInt8](RDPServerFixtures.licenseRequest)[4..<36]))
        XCTAssertFalse(random.allSatisfy { $0 == 0 }, "un aléa nul n'en est pas un")
    }

    /// Et il n'y en a pas dans un message trop court pour en porter un.
    func testThereIsNoServerRandomInAMessageTooShortToHoldOne() {
        let short = Array([UInt8](RDPServerFixtures.licenseRequest)[0..<35])
        XCTAssertNil(RDPLicensing.serverRandom(short))
    }

    /// **Un code d'erreur qui n'est pas « client valide » n'est pas forcément
    /// un refus** : c'est la transition d'état qui le dit. Un serveur sans
    /// licence à donner répond ERR_NO_LICENSE et « pas de transition », et la
    /// session continue — prendre ce message pour une panne fermerait la
    /// connexion à tous les serveurs qui ne distribuent rien, c'est-à-dire à
    /// presque tous.
    func testAnErrorWithoutATransitionLetsTheSessionContinue() throws {
        var alert = [UInt8](RDPServerFixtures.statusValidClient)
        alert[4] = 0x06                                  // ERR_NO_LICENSE_SERVER
        XCTAssertEqual(alert[8], 0x02, "ST_NO_TRANSITION, tel que xrdp l'envoie")
        XCTAssertEqual(try RDPLicensing.read(Data(alert)), .finished)
    }

    /// **Et un abandon total en est un.** C'est le seul cas où le serveur dit
    /// qu'il n'y aura pas de suite.
    func testATotalAbortIsARefusal() throws {
        var alert = [UInt8](RDPServerFixtures.statusValidClient)
        alert[4] = 0x08                                  // ERR_INVALID_CLIENT
        alert[8] = 0x01                                  // ST_TOTAL_ABORT
        XCTAssertEqual(try RDPLicensing.read(Data(alert)), .refused(8))
    }

    /// Un message plus court que son préambule n'est pas lisible.
    func testATruncatedMessageIsRefused() {
        XCTAssertThrowsError(try RDPLicensing.read(Data([0x01, 0x02, 0x3E])))
    }

    /// **Un message qui annonce plus qu'il n'envoie est refusé.** Sans cette
    /// borne, la lecture déborderait sur le message suivant.
    func testAMessageThatAnnouncesMoreThanItSendsIsRefused() {
        let cut = RDPServerFixtures.licenseRequest.prefix(100)
        XCTAssertThrowsError(try RDPLicensing.read(Data(cut))) { error in
            guard case WisqError.malformedMessage = error else {
                return XCTFail("attendu un message malformé, obtenu \(error)")
            }
        }
    }

    /// Et un qui en annonce moins que son propre préambule aussi.
    func testAMessageThatAnnouncesLessThanItsPreambleIsRefused() {
        var alert = [UInt8](RDPServerFixtures.statusValidClient)
        alert[2] = 0x02
        alert[3] = 0x00
        XCTAssertThrowsError(try RDPLicensing.read(Data(alert)))
    }

    /// Une alerte sans son code ni sa transition ne se lit pas.
    func testAnAlertWithoutItsCodeIsRefused() {
        let alert: [UInt8] = [0xFF, 0x02, 0x08, 0x00, 0x07, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try RDPLicensing.read(Data(alert)))
    }

    /// **Un défi de plateforme dit pourquoi wisq s'arrête.** Le serveur exige
    /// une identité de poste Windows enregistré ; inventer une réponse la
    /// ferait refuser plus loin, sans que personne sache où.
    func testAPlatformChallengeSaysWhyWisqCannotAnswer() {
        let challenge: [UInt8] = [0x02, 0x03, 0x10, 0x00] + [UInt8](repeating: 0, count: 12)
        XCTAssertThrowsError(try RDPLicensing.read(Data(challenge))) { error in
            guard case WisqError.authenticationFailed(let why) = error else {
                return XCTFail("attendu un refus d'authentification, obtenu \(error)")
            }
            XCTAssertTrue(why.contains("licence"), why)
        }
    }

    /// Une nouvelle licence délivrée termine l'étape.
    func testAGrantedLicenseFinishesTheStage() throws {
        let granted: [UInt8] = [0x03, 0x03, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(try RDPLicensing.read(Data(granted)), .finished)
    }

    /// Un type inconnu est nommé plutôt qu'ignoré.
    func testAnUnknownTypeIsRefused() {
        let strange: [UInt8] = [0x7E, 0x03, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try RDPLicensing.read(Data(strange))) { error in
            guard case WisqError.malformedMessage(let why) = error else {
                return XCTFail("attendu un message malformé, obtenu \(error)")
            }
            XCTAssertTrue(why.contains("7e"), why)
        }
    }

    // MARK: - Ce que wisq envoie

    /// **Notre demande annonce sa propre taille**, et c'est la longueur que
    /// notre propre lecteur y trouve.
    func testOurRequestAnnouncesItsOwnLength() throws {
        let request = RDPLicensing.newLicenseRequest(user: "essai", machine: "wisq")
        let bytes = [UInt8](request)
        XCTAssertEqual(bytes[0], RDPLicensing.Message.newLicenseRequest.rawValue)
        let declared = Int(bytes[2]) | Int(bytes[3]) << 8
        XCTAssertEqual(declared, bytes.count, "le préambule doit compter tout le message")
    }

    /// Elle porte le nom d'utilisateur et celui de la machine, terminés par un
    /// zéro, chacun dans son bloc étiqueté.
    func testOurRequestCarriesTheUserAndTheMachine() {
        let request = [UInt8](RDPLicensing.newLicenseRequest(user: "maxime", machine: "wisq"))
        let user = [UInt8](RDPLicensing.blob(0x000F, Data("maxime".utf8) + Data([0])))
        let machine = [UInt8](RDPLicensing.blob(0x0010, Data("wisq".utf8) + Data([0])))
        XCTAssertNotNil(request.firstRange(of: user), "le bloc d'utilisateur manque")
        XCTAssertNotNil(request.firstRange(of: machine), "le bloc de machine manque")
    }

    /// Un bloc dit son type puis sa longueur, et la longueur est celle de son
    /// contenu — pas celle du bloc entier.
    func testABlobDeclaresTheLengthOfItsContentAlone() {
        let blob = [UInt8](RDPLicensing.blob(0x000F, Data([1, 2, 3])))
        XCTAssertEqual(blob.count, 7)
        XCTAssertEqual(Int(blob[2]) | Int(blob[3]) << 8, 3)
    }
}
#endif
