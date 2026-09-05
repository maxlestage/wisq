#if canImport(Glibc)
import XCTest
import WisqCore

@testable import WisqRemote

/// L'échange de capacités, jugé sur le Demand Active d'un vrai serveur.
///
/// **Ce que le client annonce décide de ce que le serveur enverra**, et une
/// capacité annoncée à tort ne fait pas échouer la connexion : elle fait
/// arriver des messages qu'on ne saura pas lire. Le vecteur est le Demand
/// Active que xrdp a envoyé — treize jeux, 1024x768 en 24 bits.
final class RDPCapabilitiesTests: XCTestCase {
    static func offer() throws -> RDPCapabilities.ServerOffer {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        return try RDPCapabilities.readDemandActive(pdu.body, source: 1004)
    }

    /// **La taille de l'écran sort du jeu bitmap**, pas de l'en-tête. C'est le
    /// seul endroit du Demand Active qui la porte.
    func testTheRealDemandActiveGivesTheScreenSize() throws {
        let offer = try Self.offer()
        XCTAssertEqual(offer.width, 1024)
        XCTAssertEqual(offer.height, 768)
        XCTAssertEqual(offer.colourDepth, 24)
    }

    /// L'identifiant de partage est celui que tous nos PDU devront porter.
    func testTheShareIdentifierIsTheOneEveryLaterPDUCarries() throws {
        XCTAssertEqual(try Self.offer().shareId, 0x0001_03EA)
        // Et c'est bien celui que le serveur remet dans ses propres PDU.
        let font = [UInt8](RDPServerFixtures.serverFontMap)
        XCTAssertEqual(RDPStandardSecurity.le32(font, 6), 0x0001_03EA)
    }

    /// **Les treize jeux annoncés sont gardés dans l'ordre.** Un serveur qui
    /// n'annonce pas le pointeur n'enverra jamais de curseur, et l'attendre
    /// est un défaut qu'on ne voit qu'en le cherchant.
    func testTheOfferedSetsAreKeptAsTheServerNamedThem() throws {
        let offer = try Self.offer()
        XCTAssertEqual(offer.offered.count, 13)
        XCTAssertEqual(offer.offered.first, RDPCapabilities.Kind.share.rawValue,
                       "xrdp annonce le jeu de partage en premier, pas le général")
        for expected in [RDPCapabilities.Kind.general, .bitmap, .order, .pointer,
                         .input, .share, .colourCache] {
            XCTAssertTrue(offer.offered.contains(expected.rawValue),
                          "\(expected) manque dans \(offer.offered)")
        }
    }

    // MARK: - Ce qu'on refuse

    /// Un Demand Active trop court pour son propre en-tête est refusé, et le
    /// refus dit que le message est tronqué — pas qu'une longueur intérieure
    /// ne concorde pas, ce qui serait le signe qu'on a lu un champ qui n'est
    /// pas là.
    func testATruncatedDemandActiveIsRefused() {
        XCTAssertThrowsError(try RDPCapabilities.readDemandActive(
            RDPServerFixtures.demandActive.prefix(10), source: 1004)) {
            guard case WisqError.handshakeFailed(let why) = $0 else {
                return XCTFail("attendu un échec de poignée de main, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("tronqué"), why)
        }
    }

    /// **Un nombre de jeux absurde est refusé avant la boucle.** Le champ en
    /// compte seize bits ; soixante mille jeux demanderaient soixante mille
    /// tours sur des octets que le serveur n'a pas envoyés.
    func testAnAbsurdNumberOfSetsIsRefused() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        var bytes = [UInt8](pdu.body)
        let index = 8 + Int(bytes[4]) | Int(bytes[5]) << 8
        bytes[index] = 0x60
        bytes[index + 1] = 0xEA
        XCTAssertThrowsError(try RDPCapabilities.readDemandActive(Data(bytes), source: 1004)) {
            guard case WisqError.handshakeFailed(let why) = $0 else {
                return XCTFail("attendu un échec de poignée de main, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("60000"), why)
        }
    }

    /// **Un jeu plus long que le message est refusé.** Sans cette borne, la
    /// lecture sortirait du tampon au premier serveur mal élevé.
    func testASetLongerThanTheMessageIsRefused() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        var bytes = [UInt8](pdu.body)
        let start = 12 + (Int(bytes[4]) | Int(bytes[5]) << 8)
        bytes[start + 2] = 0xFF
        bytes[start + 3] = 0x7F
        XCTAssertThrowsError(try RDPCapabilities.readDemandActive(Data(bytes), source: 1004)) {
            guard case WisqError.handshakeFailed(let why) = $0 else {
                return XCTFail("attendu un échec de poignée de main, obtenu \($0)")
            }
            // **C'est la longueur qui doit être nommée.** Sans la borne, la
            // boucle sortirait sur un jeu introuvable et le refus parlerait de
            // la taille de l'écran — un refus juste pour une mauvaise raison,
            // qui laisse la vraie garde absente.
            XCTAssertTrue(why.contains("longueur"), why)
        }
    }

    /// Et un jeu qui n'a même pas la place de son propre en-tête aussi. Sans
    /// cette borne l'index n'avancerait pas, et la boucle tournerait sur place.
    func testASetShorterThanItsOwnHeaderIsRefused() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        var bytes = [UInt8](pdu.body)
        let start = 12 + (Int(bytes[4]) | Int(bytes[5]) << 8)
        bytes[start + 2] = 0x00
        bytes[start + 3] = 0x00
        XCTAssertThrowsError(try RDPCapabilities.readDemandActive(Data(bytes), source: 1004)) {
            guard case WisqError.handshakeFailed(let why) = $0 else {
                return XCTFail("attendu un échec de poignée de main, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("longueur"), why)
        }
    }

    /// **Un serveur qui ne dit pas la taille de son écran est refusé plutôt
    /// que deviné.** Peindre sur un écran de zéro par zéro ne se voit pas ;
    /// le dire se voit.
    func testADemandActiveWithoutABitmapSetIsRefused() throws {
        let pdu = try RDPShare.read(RDPServerFixtures.demandActive)
        var bytes = [UInt8](pdu.body)
        var index = 12 + (Int(bytes[4]) | Int(bytes[5]) << 8)
        var found = false
        while index + 4 <= bytes.count {
            let type = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2]) | Int(bytes[index + 3]) << 8
            if type == RDPCapabilities.Kind.bitmap.rawValue {
                bytes[index] = 0xFE                       // un type que rien ne lit
                found = true
                break
            }
            guard length >= 4 else { break }
            index += length
        }
        XCTAssertTrue(found, "le vecteur doit contenir un jeu bitmap")
        XCTAssertThrowsError(try RDPCapabilities.readDemandActive(Data(bytes), source: 1004)) {
            guard case WisqError.handshakeFailed(let why) = $0 else {
                return XCTFail("attendu un échec de poignée de main, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("taille"), why)
        }
    }

    // MARK: - Ce que wisq annonce

    /// **Chaque jeu qu'on écrit déclare sa propre longueur**, et les longueurs
    /// mises bout à bout couvrent exactement ce qu'on envoie. Un jeu qui
    /// mentirait d'un octet décalerait tous les suivants.
    func testEverySetWeAnnounceDeclaresItsOwnLength() {
        let written = [UInt8](RDPCapabilities.clientCapabilities(
            width: 1024, height: 768, depth: 24))
        let count = Int(written[0]) | Int(written[1]) << 8
        var index = 4
        var seen = 0
        while index + 4 <= written.count {
            let length = Int(written[index + 2]) | Int(written[index + 3]) << 8
            XCTAssertGreaterThanOrEqual(length, 4, "jeu de longueur \(length)")
            index += length
            seen += 1
        }
        XCTAssertEqual(index, written.count, "les longueurs doivent tomber juste")
        XCTAssertEqual(seen, count, "le nombre annoncé doit être le nombre écrit")
    }

    /// Et notre propre lecteur retrouve dans notre annonce ce qu'on y a mis.
    func testOurOwnReaderFindsTheScreenWeAnnounced() throws {
        let confirm = RDPCapabilities.confirmActive(
            offer: try Self.offer(), source: 1007, width: 800, height: 600, depth: 16)
        let pdu = try RDPShare.read(confirm)
        XCTAssertEqual(pdu.kind, .confirmActive)
        // Le Confirm Active a la même forme que le Demand Active, à deux
        // octets près : c'est ce qui permet de le relire ici.
        var body = [UInt8](pdu.body)
        body.removeSubrange(4..<6)                        // l'identifiant d'origine
        let ours = try RDPCapabilities.readDemandActive(Data(body), source: 1007)
        XCTAssertEqual(ours.width, 800)
        XCTAssertEqual(ours.height, 600)
        XCTAssertEqual(ours.colourDepth, 16)
    }

    /// **Ce qu'on n'annonce pas est délibéré.** Un cache annoncé et non tenu
    /// ferait envoyer au serveur des références à des images qu'on n'a jamais
    /// gardées, et ce qu'on peindrait serait faux sans qu'aucune erreur ne le
    /// dise.
    func testWeAnnounceNoCacheWeDoNotKeep() {
        let written = [UInt8](RDPCapabilities.clientCapabilities(
            width: 1024, height: 768, depth: 24))
        var index = 4
        var kinds: [UInt16] = []
        while index + 4 <= written.count {
            kinds.append(UInt16(written[index]) | UInt16(written[index + 1]) << 8)
            index += Int(written[index + 2]) | Int(written[index + 3]) << 8
        }
        for absent in [RDPCapabilities.Kind.bitmapCache, .glyphCache, .offscreenCache,
                       .surfaceCommands, .bitmapCodecs, .frameAcknowledge] {
            XCTAssertFalse(kinds.contains(absent.rawValue),
                           "wisq ne tient pas \(absent) et ne doit pas l'annoncer")
        }
        for present in [RDPCapabilities.Kind.general, .bitmap, .order, .pointer, .input] {
            XCTAssertTrue(kinds.contains(present.rawValue), "\(present) manque")
        }
    }

    /// **Et aucun ordre de dessin.** Les trente-deux octets du champ sont nuls,
    /// ce qui fait envoyer au serveur des bitmaps plutôt que des primitives de
    /// GDI que wisq ne sait pas exécuter.
    func testWeSupportNoDrawingOrderAtAll() {
        let written = [UInt8](RDPCapabilities.clientCapabilities(
            width: 1024, height: 768, depth: 24))
        var index = 4
        while index + 4 <= written.count {
            let type = UInt16(written[index]) | UInt16(written[index + 1]) << 8
            let length = Int(written[index + 2]) | Int(written[index + 3]) << 8
            if type == RDPCapabilities.Kind.order.rawValue {
                let orders = Array(written[(index + 4 + 20 + 14)..<(index + 4 + 20 + 14 + 32)])
                XCTAssertTrue(orders.allSatisfy { $0 == 0 },
                              "un ordre annoncé serait un ordre reçu : \(orders)")
                return
            }
            index += length
        }
        XCTFail("le jeu d'ordres manque")
    }

    /// **L'identifiant d'origine du Confirm Active n'est pas notre canal** mais
    /// la constante `0x03EA`, tandis que l'en-tête de contrôle qui l'enveloppe
    /// porte, lui, notre vrai canal. Les deux dans le même PDU, à six octets
    /// d'écart : c'est la confusion que ce test empêche.
    func testTheConfirmActiveUsesTheProtocolOriginatorNotOurChannel() throws {
        let confirm = [UInt8](RDPCapabilities.confirmActive(
            offer: try Self.offer(), source: 1007, width: 1024, height: 768, depth: 24))
        XCTAssertEqual(UInt16(confirm[4]) | UInt16(confirm[5]) << 8, 1007,
                       "l'en-tête de contrôle porte, lui, notre vrai canal")
        XCTAssertEqual(UInt16(confirm[10]) | UInt16(confirm[11]) << 8,
                       RDPShare.confirmOriginator)
    }

    /// Et il renvoie l'identifiant de partage que le serveur a donné.
    func testTheConfirmActiveEchoesTheShareIdentifier() throws {
        let confirm = [UInt8](RDPCapabilities.confirmActive(
            offer: try Self.offer(), source: 1007, width: 1024, height: 768, depth: 24))
        XCTAssertEqual(RDPStandardSecurity.le32(confirm, 6), 0x0001_03EA)
    }

    /// Le descripteur de source est `RDP` suivi d'un zéro, comme celui du
    /// serveur, et sa longueur annoncée est bien quatre.
    func testTheSourceDescriptorIsTheSameFourBytesTheServerSends() throws {
        let confirm = [UInt8](RDPCapabilities.confirmActive(
            offer: try Self.offer(), source: 1007, width: 1024, height: 768, depth: 24))
        XCTAssertEqual(Int(confirm[12]) | Int(confirm[13]) << 8, 4)
        XCTAssertEqual(Array(confirm[16..<20]), Array("RDP\u{0}".utf8))
        let demand = [UInt8](RDPServerFixtures.demandActive)
        XCTAssertEqual(Array(demand[14..<18]), Array("RDP\u{0}".utf8))
    }

    /// La longueur des capacités qu'on annonce est celle qu'on écrit.
    func testTheAnnouncedCapabilityLengthIsTheOneWeWrite() throws {
        let confirm = [UInt8](RDPCapabilities.confirmActive(
            offer: try Self.offer(), source: 1007, width: 1024, height: 768, depth: 24))
        let declared = Int(confirm[14]) | Int(confirm[15]) << 8
        XCTAssertEqual(declared, confirm.count - 20)
    }
}
#endif
