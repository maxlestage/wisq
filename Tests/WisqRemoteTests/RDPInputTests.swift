#if canImport(Glibc)
import XCTest
import WisqCore

@testable import WisqRemote

/// Les entrées : ce que le téléphone envoie au serveur.
///
/// **Un événement mal formé ne donne pas d'erreur, il donne un autre
/// événement.** Le serveur prend le compte annoncé, découpe douze octets par
/// événement, et lit la suite comme si de rien n'était. Une touche devient un
/// clic quelque part. C'est la seule chose que ces tests surveillent vraiment :
/// que le compte, la taille et l'ordre des champs tombent juste.
final class RDPInputTests: XCTestCase {
    /// Chaque événement pèse exactement douze octets, quel qu'il soit.
    func testEveryEventIsTwelveBytes() {
        for event: RDPInput.Event in [.synchronise([.numLock]), .key(0x1E, []),
                                      .key(0x48, [.extended, .release]),
                                      .character(0x00E9, []),
                                      .pointer([.move], 10, 20),
                                      .extendedPointer([.down], 0, 0)] {
            XCTAssertEqual(RDPInput.encode(event).count, 12, "\(event)")
        }
    }

    /// **Le compte annoncé est le nombre d'événements écrits.** S'en écarter
    /// d'un fait lire au serveur douze octets qui ne sont pas là, ou en laisser
    /// douze pour le message suivant.
    func testTheAnnouncedCountIsTheNumberOfEventsWritten() throws {
        for count in [1, 2, 7, 64] {
            let events = Array(repeating: RDPInput.Event.key(0x1E, []), count: count)
            let pdu = try RDPInput.events(events, share: 1, source: 1007)
            let body = [UInt8](try RDPShare.read(pdu).body)
            XCTAssertEqual(Int(body[0]) | Int(body[1]) << 8, count)
            XCTAssertEqual(body.count, 4 + 12 * count)
        }
    }

    /// Un PDU d'entrées est bien un PDU d'entrées, et il porte l'identifiant de
    /// partage qu'on lui a donné.
    func testTheInputPDUIsWrappedAsOne() throws {
        let pdu = try RDPShare.read(
            try RDPInput.events([.key(0x1E, [])], share: 0x0001_03EA, source: 1007))
        XCTAssertEqual(pdu.kind, .data)
        XCTAssertEqual(pdu.dataKind, .input)
        XCTAssertEqual(pdu.source, 1007)
    }

    /// **Un appui n'a pas de drapeau ; c'est le relâchement qui en a un.**
    /// Inventer un drapeau « enfoncé » ferait rester la touche collée côté
    /// serveur, et le clavier ne répondrait plus.
    func testAPressHasNoFlagAndAReleaseDoes() {
        let press = [UInt8](RDPInput.encode(.key(0x1E, [])))
        let release = [UInt8](RDPInput.encode(.key(0x1E, .release)))
        XCTAssertEqual(UInt16(press[4]) | UInt16(press[5]) << 8, RDPInput.Kind.scancode.rawValue)
        XCTAssertEqual(UInt16(press[6]) | UInt16(press[7]) << 8, 0)
        XCTAssertEqual(UInt16(release[6]) | UInt16(release[7]) << 8, 0x8000)
        XCTAssertEqual(UInt16(press[8]) | UInt16(press[9]) << 8, 0x1E, "le code de touche")
    }

    /// Une touche étendue porte son préfixe, et peut le porter avec le
    /// relâchement.
    func testAnExtendedKeyCarriesItsPrefix() {
        let bytes = [UInt8](RDPInput.encode(.key(0x48, [.extended, .release])))
        XCTAssertEqual(UInt16(bytes[6]) | UInt16(bytes[7]) << 8, 0x8100)
    }

    /// Les verrous du clavier tiennent sur quatre octets, pas deux.
    func testTheKeyboardTogglesUseFourBytes() {
        let bytes = [UInt8](RDPInput.encode(.synchronise([.numLock, .capsLock])))
        XCTAssertEqual(UInt16(bytes[4]) | UInt16(bytes[5]) << 8,
                       RDPInput.Kind.synchronise.rawValue)
        XCTAssertEqual(UInt16(bytes[6]) | UInt16(bytes[7]) << 8, 0, "deux octets de garniture")
        let toggles = UInt32(bytes[8]) | UInt32(bytes[9]) << 8
            | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        XCTAssertEqual(toggles, 0x06)
    }

    /// Un clic est un enfoncement **plus** un bouton, dans le même événement.
    func testAClickIsTheButtonAndTheDownFlagTogether() {
        let bytes = [UInt8](RDPInput.encode(.pointer([.left, .down], 100, 200)))
        XCTAssertEqual(UInt16(bytes[4]) | UInt16(bytes[5]) << 8, RDPInput.Kind.mouse.rawValue)
        XCTAssertEqual(UInt16(bytes[6]) | UInt16(bytes[7]) << 8, 0x9000)
        XCTAssertEqual(UInt16(bytes[8]) | UInt16(bytes[9]) << 8, 100)
        XCTAssertEqual(UInt16(bytes[10]) | UInt16(bytes[11]) << 8, 200)
    }

    /// **Une coordonnée hors de l'écran est bornée, pas repliée.** Sur seize
    /// bits non signés, un x de −1 devient 65535 : le clic partirait à l'autre
    /// bout de l'écran, et personne ne saurait pourquoi.
    func testACoordinateOutsideTheScreenIsClampedNotWrapped() {
        for (given, expected) in [(-1, 0), (-40000, 0), (70000, 65535), (0, 0), (1023, 1023)] {
            let bytes = [UInt8](RDPInput.encode(.pointer([.move], given, given)))
            XCTAssertEqual(Int(UInt16(bytes[8]) | UInt16(bytes[9]) << 8), expected,
                           "x de \(given)")
        }
    }

    /// **La molette porte sa quantité dans les neuf bits bas**, en complément à
    /// deux sur ces neuf bits seulement : les bits hauts appartiennent aux
    /// drapeaux, et un nombre négatif ordinaire les écraserait.
    func testTheWheelKeepsItsAmountInTheLowNineBits() {
        let forward = [UInt8](RDPInput.encode(RDPInput.wheel(1, at: (0, 0))))
        let flagsForward = UInt16(forward[6]) | UInt16(forward[7]) << 8
        XCTAssertNotEqual(flagsForward & RDPInput.Pointer.wheel.rawValue, 0)
        XCTAssertEqual(flagsForward & RDPInput.Pointer.wheelNegative.rawValue, 0)
        XCTAssertEqual(flagsForward & 0x00FF, 120)

        let backward = [UInt8](RDPInput.encode(RDPInput.wheel(-1, at: (0, 0))))
        let flagsBackward = UInt16(backward[6]) | UInt16(backward[7]) << 8
        XCTAssertNotEqual(flagsBackward & RDPInput.Pointer.wheelNegative.rawValue, 0)
        XCTAssertEqual(flagsBackward & 0xFE00, RDPInput.Pointer.wheel.rawValue,
                       "rien ne doit déborder au-delà des neuf bits")
        // −120 sur neuf bits.
        XCTAssertEqual(flagsBackward & 0x01FF, (~UInt16(120) &+ 1) & 0x01FF)
    }

    /// Une molette horizontale n'est pas une molette verticale.
    func testTheHorizontalWheelIsItsOwnFlag() {
        let sideways = [UInt8](RDPInput.encode(RDPInput.wheel(1, at: (0, 0), horizontal: true)))
        let flags = UInt16(sideways[6]) | UInt16(sideways[7]) << 8
        XCTAssertNotEqual(flags & RDPInput.Pointer.horizontalWheel.rawValue, 0)
        XCTAssertEqual(flags & RDPInput.Pointer.wheel.rawValue, 0)
    }

    /// Un PDU sans événement, ou avec trop, est refusé plutôt qu'envoyé.
    func testAnEmptyOrOverfullPDUIsRefused() {
        XCTAssertThrowsError(try RDPInput.events([], share: 1, source: 1007))
        let far = Array(repeating: RDPInput.Event.key(0x1E, []),
                        count: RDPInput.eventLimit + 1)
        XCTAssertThrowsError(try RDPInput.events(far, share: 1, source: 1007)) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("\(RDPInput.eventLimit + 1)"), why)
        }
    }

    // MARK: - Les deux demandes

    /// La demande de rafraîchissement compte ses zones sur **un** octet, et
    /// chaque zone tient sur huit.
    func testTheRefreshRequestCountsItsAreasInOneByte() throws {
        let pdu = try RDPInput.refreshRect([(left: 10, top: 20, right: 30, bottom: 40),
                                            (left: 0, top: 0, right: 1, bottom: 1)],
                                           share: 1, source: 1007)
        let received = try RDPShare.read(pdu)
        XCTAssertEqual(received.dataKind, .refreshRect)
        let body = [UInt8](received.body)
        XCTAssertEqual(body[0], 2)
        XCTAssertEqual(Array(body[1..<4]), [0, 0, 0], "trois octets de garniture")
        XCTAssertEqual(body.count, 4 + 16)
        XCTAssertEqual(UInt16(body[4]) | UInt16(body[5]) << 8, 10)
        XCTAssertEqual(UInt16(body[10]) | UInt16(body[11]) << 8, 40)
    }

    /// Et elle refuse plus de zones que son octet n'en compte.
    func testTheRefreshRequestRefusesMoreAreasThanItCanCount() {
        let many = Array(repeating: (left: 0, top: 0, right: 1, bottom: 1),
                         count: RDPInput.areaLimit + 1)
        XCTAssertThrowsError(try RDPInput.refreshRect(many, share: 1, source: 1007))
        XCTAssertThrowsError(try RDPInput.refreshRect([], share: 1, source: 1007))
    }

    /// **Le rectangle n'accompagne que la reprise.** L'ajouter à l'arrêt ferait
    /// lire au serveur quatre nombres qui n'ont pas de sens là.
    func testTheSuppressRequestOnlyCarriesARectangleWhenPaintingResumes() throws {
        let stop = try RDPShare.read(RDPInput.suppressOutput(
            false, width: 1024, height: 768, share: 1, source: 1007))
        XCTAssertEqual(stop.dataKind, .suppressOutput)
        XCTAssertEqual([UInt8](stop.body), [0, 0, 0, 0])

        let resume = try RDPShare.read(RDPInput.suppressOutput(
            true, width: 1024, height: 768, share: 1, source: 1007))
        let body = [UInt8](resume.body)
        XCTAssertEqual(body.count, 12)
        XCTAssertEqual(body[0], 1)
        // **Le rectangle est inclusif** : la dernière colonne d'un écran de
        // 1024 est la 1023e. Y mettre la largeur demanderait une colonne de
        // plus que l'écran n'en a.
        XCTAssertEqual(UInt16(body[8]) | UInt16(body[9]) << 8, 1023)
        XCTAssertEqual(UInt16(body[10]) | UInt16(body[11]) << 8, 767)
    }

    /// Un écran de taille nulle ne fait pas déborder le rectangle vers −1.
    func testAZeroSizedScreenDoesNotUnderflowTheRectangle() throws {
        let body = [UInt8](try RDPShare.read(
            RDPInput.suppressOutput(true, width: 0, height: 0, share: 1, source: 1007)).body)
        XCTAssertEqual(UInt16(body[8]) | UInt16(body[9]) << 8, 0)
        XCTAssertEqual(UInt16(body[10]) | UInt16(body[11]) << 8, 0)
    }
}
#endif
