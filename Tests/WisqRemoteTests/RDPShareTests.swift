import XCTest
import WisqCore

@testable import WisqRemote

/// Les deux en-têtes de partage, jugés sur les PDU d'un vrai serveur.
///
/// **Les deux se ressemblent assez pour qu'on les confonde**, et la confusion
/// ne donne pas d'erreur : elle donne un genre de PDU pris pour un autre. Les
/// six PDU lus ici sont ceux que xrdp a envoyés après notre Confirm Active,
/// dans l'ordre où il les a envoyés.
final class RDPShareTests: XCTestCase {
    /// **Le Demand Active n'est pas un PDU de données**, et n'a donc pas de
    /// second en-tête. Lui en chercher un mangerait douze octets de capacités.
    func testARealDemandActiveHasNoSecondHeader() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        XCTAssertEqual(pdu.kind, .demandActive)
        XCTAssertNil(pdu.dataKind)
        XCTAssertEqual(pdu.body.count, RDPServerFixtures.demandActive.count - 6)
        XCTAssertEqual([UInt8](pdu.body.prefix(4)), [0xEA, 0x03, 0x01, 0x00],
                       "le corps commence à l'identifiant de partage")
    }

    /// La synchronisation que le serveur renvoie.
    func testARealSynchroniseIsReadAsOne() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.serverSynchronise)
        XCTAssertEqual(pdu.kind, .data)
        XCTAssertEqual(pdu.dataKind, .synchronise)
        XCTAssertEqual(pdu.body.count, 4)
    }

    /// **Ses deux contrôles portent deux actions différentes**, et c'est le
    /// second — « accordé » — qui dit que la session est à nous.
    func testTheTwoRealControlsCarryCooperateThenGranted() throws {
        let cooperate = try RDPShare.read(RDPServerFixtures.serverControlCooperate)
        let granted = try RDPShare.read(RDPServerFixtures.serverControlGranted)
        XCTAssertEqual(cooperate.dataKind, .control)
        XCTAssertEqual(granted.dataKind, .control)
        XCTAssertEqual(UInt16([UInt8](cooperate.body)[0]), 4, "coopérer")
        XCTAssertEqual(UInt16([UInt8](granted.body)[0]), 2, "accordé")
    }

    /// La carte des polices, dernier message de l'établissement.
    func testTheRealFontMapClosesTheSetup() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.serverFontMap)
        XCTAssertEqual(pdu.dataKind, .fontMap)
    }

    /// Et la première mise à jour, qui suit.
    func testTheFirstRealUpdateIsAnUpdate() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.serverFirstUpdate)
        XCTAssertEqual(pdu.dataKind, .update)
    }

    // MARK: - Ce qu'on refuse

    /// **La longueur annoncée borne la lecture.** Un serveur qui annonce plus
    /// qu'il n'envoie ferait lire les octets d'après.
    func testAPDUThatAnnouncesMoreThanItSendsIsRefused() {
        let cut = RDPServerFixtures.demandActive.prefix(200)
        XCTAssertThrowsError(try RDPShare.read(Data(cut))) { error in
            guard case WisqError.malformedMessage = error else {
                return XCTFail("attendu un message malformé, obtenu \(error)")
            }
        }
    }

    /// **Et ce qui suit la longueur annoncée n'est pas lu.** Deux PDU dans un
    /// même paquet : le premier ne doit pas emporter le second.
    func testBytesBeyondTheDeclaredLengthAreNotRead() throws {
        let both = RDPServerFixtures.serverFontMap + RDPServerFixtures.serverFirstUpdate
        let pdu = try RDPShare.read(both)
        XCTAssertEqual(pdu.dataKind, .fontMap)
        XCTAssertEqual(pdu.body.count, RDPServerFixtures.serverFontMap.count - 18)
    }

    /// Un genre inconnu est nommé plutôt qu'ignoré.
    func testAnUnknownKindIsRefused() {
        var bytes = [UInt8](RDPServerFixtures.serverFontMap)
        bytes[2] = 0x15                                   // genre 5, qui n'existe pas
        XCTAssertThrowsError(try RDPShare.read(Data(bytes)))
    }

    /// **La compression est refusée plutôt que devinée.** wisq ne l'annonce
    /// pas ; l'afficher quand même ferait un écran de bruit dont personne ne
    /// saurait dire d'où il vient.
    func testACompressedPDUIsRefusedRatherThanGuessed() {
        var bytes = [UInt8](RDPServerFixtures.serverFirstUpdate)
        bytes[15] |= 0x20
        XCTAssertThrowsError(try RDPShare.read(Data(bytes))) { error in
            guard case WisqError.unsupportedEncoding = error else {
                return XCTFail("attendu un encodage non pris en charge, obtenu \(error)")
            }
        }
    }

    /// Un PDU de données trop court pour son second en-tête est refusé.
    func testADataPDUWithoutItsSecondHeaderIsRefused() {
        var bytes = [UInt8](RDPServerFixtures.serverFontMap.prefix(16))
        bytes[0] = 16
        bytes[1] = 0
        XCTAssertThrowsError(try RDPShare.read(Data(bytes)))
    }

    /// Six octets sont le minimum d'un en-tête de contrôle.
    func testATruncatedHeaderIsRefused() {
        XCTAssertThrowsError(try RDPShare.read(RDPServerFixtures.serverFontMap.prefix(5)))
    }

    /// Une longueur plus petite que l'en-tête qu'elle décrit est refusée.
    func testALengthSmallerThanItsOwnHeaderIsRefused() {
        var bytes = [UInt8](RDPServerFixtures.serverFontMap)
        bytes[0] = 4
        bytes[1] = 0
        XCTAssertThrowsError(try RDPShare.read(Data(bytes)))
    }

    // MARK: - Ce que wisq écrit

    /// **Ce qu'on écrit, on sait le relire** — et le relire donne le genre, le
    /// second genre et le corps qu'on y a mis.
    func testWhatWeWriteReadsBackAsWhatWePutIn() throws {
        let written = RDPShare.data(.input, share: 0x0001_03EA, source: 1007,
                                    Data([0xAA, 0xBB, 0xCC]))
        let pdu = try RDPShare.read(written)
        XCTAssertEqual(pdu.kind, .data)
        XCTAssertEqual(pdu.dataKind, .input)
        XCTAssertEqual([UInt8](pdu.body), [0xAA, 0xBB, 0xCC])
    }

    /// Et la longueur qu'on annonce est celle qu'on envoie.
    func testTheLengthWeAnnounceIsTheLengthWeSend() {
        for payload in [Data(), Data([1]), Data(repeating: 7, count: 500)] {
            let written = [UInt8](RDPShare.data(.update, share: 1, source: 1007, payload))
            XCTAssertEqual(Int(written[0]) | Int(written[1]) << 8, written.count)
        }
    }

    /// **Le bit de version est dans tout ce qu'on écrit.** xrdp ne le regarde
    /// pas — c'est mesuré — mais la spécification le demande, et ce test tient
    /// ce qu'on écrit plutôt que ce qu'un serveur en fait.
    func testEveryPDUWeWriteCarriesTheVersionBit() {
        for written in [RDPShare.control(.confirmActive, source: 1007, Data()),
                        RDPShare.synchronise(share: 1, source: 1007, target: 1002),
                        RDPShare.controlCooperate(share: 1, source: 1007),
                        RDPShare.controlRequest(share: 1, source: 1007),
                        RDPShare.fontList(share: 1, source: 1007)] {
            let bytes = [UInt8](written)
            let type = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
            XCTAssertEqual(type & 0xFFF0, RDPShare.versionLow, "version absente de \(type)")
        }
    }

    /// **Les quatre messages de fin portent chacun leur action.** Deux d'entre
    /// elles sont mesurées nécessaires contre un vrai serveur — la demande de
    /// contrôle et la liste de polices ; les deux autres suivent la
    /// spécification. Le serveur ne se plaint jamais d'une action fausse : il
    /// n'envoie simplement pas le premier pixel.
    func testTheFourFinalisationMessagesCarryTheirOwnAction() throws {
        let synchronise = try RDPShare.read(
            RDPShare.synchronise(share: 9, source: 1007, target: 1002))
        XCTAssertEqual(synchronise.dataKind, .synchronise)
        XCTAssertEqual([UInt8](synchronise.body), [0x01, 0x00, 0xEA, 0x03],
                       "type 1, puis le canal du serveur")

        let cooperate = try RDPShare.read(RDPShare.controlCooperate(share: 9, source: 1007))
        XCTAssertEqual(cooperate.dataKind, .control)
        XCTAssertEqual([UInt8](cooperate.body)[0], 4)

        let request = try RDPShare.read(RDPShare.controlRequest(share: 9, source: 1007))
        XCTAssertEqual(request.dataKind, .control)
        XCTAssertEqual([UInt8](request.body)[0], 1)

        let fonts = try RDPShare.read(RDPShare.fontList(share: 9, source: 1007))
        XCTAssertEqual(fonts.dataKind, .fontList)
        XCTAssertEqual([UInt8](fonts.body), [0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x32, 0x00],
                       "aucune police, un seul fragment, entrées de 50 octets")
    }

    /// **Le second en-tête compte la longueur une seconde fois**, et celle-là
    /// couvre le PDU entier, ses dix-huit octets d'en-têtes compris. C'est
    /// ainsi que xrdp l'écrit dans chacun de ses PDU ; un client qui y met la
    /// taille de sa charge utile seule annonce un PDU plus court qu'il n'est.
    func testTheUncompressedLengthCountsTheWholePDU() {
        for fixture in [RDPServerFixtures.serverSynchronise,
                        RDPServerFixtures.serverControlCooperate,
                        RDPServerFixtures.serverFontMap,
                        RDPServerFixtures.serverFirstUpdate] {
            let bytes = [UInt8](fixture)
            XCTAssertEqual(Int(bytes[12]) | Int(bytes[13]) << 8, bytes.count,
                           "ce que xrdp annonce")
            XCTAssertEqual(Array(bytes[10...11]), [0x00, 0x01],
                           "garniture nulle, et le flux de priorité basse")
        }
        for payload in [Data(), Data(repeating: 3, count: 40)] {
            let bytes = [UInt8](RDPShare.data(.input, share: 1, source: 1007, payload))
            XCTAssertEqual(Int(bytes[12]) | Int(bytes[13]) << 8, bytes.count,
                           "et ce que wisq annonce")
            XCTAssertEqual(Array(bytes[10...11]), [0x00, 0x01],
                           "wisq écrit le même flux que le serveur")
        }
    }

    /// **L'en-tête de contrôle dit de quel canal le PDU vient**, et c'est ce
    /// canal que la synchronisation du client devra viser. Le jeter oblige
    /// l'appelant à le deviner, et un nombre deviné qui se trouve juste chez
    /// xrdp ne le sera pas ailleurs.
    func testTheControlHeaderNamesTheChannelThePDUCameFrom() throws {
        for fixture in [RDPServerFixtures.demandActive,
                        RDPServerFixtures.serverSynchronise,
                        RDPServerFixtures.serverFontMap] {
            XCTAssertEqual(try RDPShare.read(fixture).source, 1004)
        }
        let ours = RDPShare.data(.input, share: 1, source: 1007, Data())
        XCTAssertEqual(try RDPShare.read(ours).source, 1007)
    }

    /// L'identifiant de partage qu'on écrit est celui qu'on nous a donné.
    func testTheShareIdentifierWeWriteIsTheOneTheServerGaveUs() {
        let written = [UInt8](RDPShare.data(.control, share: 0x0001_03EA, source: 1007, Data()))
        XCTAssertEqual(RDPStandardSecurity.le32(written, 6), 0x0001_03EA)
    }
}
