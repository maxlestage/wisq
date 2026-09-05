#if canImport(Glibc)
import XCTest

@testable import WisqCore
@testable import WisqNet
@testable import WisqRemote

/// **L'établissement complet, contre un vrai serveur** : licence, capacités,
/// et les quatre messages qui terminent — jusqu'à ce que le serveur envoie
/// des pixels.
///
/// C'est la seule mesure qui vaut pour cette partie du protocole. Chacun de
/// ces messages peut être accepté sans que rien ne le dise : un serveur qui
/// n'aime pas notre Confirm Active ne répond pas « non », il ne répond rien.
/// Le verdict n'est donc pas « le serveur n'a pas fermé » mais « le serveur a
/// envoyé la suite », et la suite se lit ici jusqu'à la première mise à jour.
///
/// **Ce que ce serveur-là vérifie, mesuré en sabotant chaque champ tour à
/// tour.** Deux seulement font taire xrdp : la demande de contrôle avec son
/// action 1, et la liste de polices. Six autres passent inaperçus — la
/// constante `0x03EA` du Confirm Active, les bits de version, l'identifiant de
/// partage qu'on y renvoie, le canal visé par la synchronisation, l'action de
/// la coopération, et la profondeur de couleur qu'on annonce. On les écrit
/// justes quand même, parce que la spécification les demande et qu'un serveur
/// qui les vérifierait ne dirait pas pourquoi il refuse — mais **personne ne
/// doit lire ce test comme une preuve qu'ils sont facultatifs** : il dit ce
/// qu'un xrdp 0.9 tolère, rien de plus.
///
///     apt-get install -y xrdp && /usr/sbin/xrdp --nodaemon &
///     WISQ_RDP_HOST=127.0.0.1 swift test --filter RDPLiveActivationTests
final class RDPLiveActivationTests: XCTestCase {
    /// Combien de PDU on lit avant d'abandonner. xrdp en envoie huit avant sa
    /// première mise à jour ; le double laisse de la marge à un serveur plus
    /// bavard sans faire attendre indéfiniment quand plus rien ne vient.
    static let rounds = 16

    func testARealServerFinishesTheSetupAndStartsSendingPictures() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let stream = try PosixByteStream(host: target.host, port: target.port)
        defer { Task { await stream.close() } }
        func pdu() async throws -> Data { try await RDPLiveHandshakeTests.readPDU(stream) }

        var session = try await RDPLiveHandshakeTests.establish(stream)
        func send(_ payload: Data, flags: RDPStandardSecurity.Flags = []) async throws {
            try await stream.write(RDPMCS.sendData(
                user: session.user, channel: session.server.ioChannel,
                session.security.seal(payload, flags: flags)))
        }

        var askedForALicence = false
        var licensingFinished = false
        var offer: RDPCapabilities.ServerOffer?
        var seen: [RDPShare.DataKind] = []

        for _ in 0..<Self.rounds {
            guard case .data(let indication) = try RDPMCS.readIncoming(await pdu()) else {
                return XCTFail("le serveur a raccroché après \(seen)")
            }
            let flags = UInt16(indication.payload[0]) | UInt16(indication.payload[1]) << 8
            let clear = try session.security.open(indication.payload)

            // **L'étape de licence d'abord.** Un client qui ne répond rien
            // reste là : le serveur attend, et la session ne finit jamais de
            // s'établir.
            if flags & 0x0080 != 0 {
                switch try RDPLicensing.read(clear) {
                case .wantsRequest:
                    askedForALicence = true
                    try await send(RDPLicensing.newLicenseRequest(user: "essai", machine: "wisq"),
                                   flags: [.licence])
                case .finished:
                    licensingFinished = true
                case .refused(let code):
                    return XCTFail("licence refusée, code \(code)")
                }
                continue
            }

            let received = try RDPShare.read(clear)
            if let kind = received.dataKind { seen.append(kind) }
            guard received.kind == .demandActive else { continue }

            // **Les capacités, puis les quatre messages de fin.**
            let it = try RDPCapabilities.readDemandActive(received.body, source: received.source)
            offer = it
            try await send(RDPCapabilities.confirmActive(
                offer: it, source: session.user,
                width: it.width, height: it.height, depth: it.colourDepth))
            for message in [
                RDPShare.synchronise(share: it.shareId, source: session.user, target: it.source),
                RDPShare.controlCooperate(share: it.shareId, source: session.user),
                RDPShare.controlRequest(share: it.shareId, source: session.user),
                RDPShare.fontList(share: it.shareId, source: session.user)
            ] {
                try await send(message)
            }
        }

        // Ce que le serveur a fait de chaque étape.
        XCTAssertTrue(askedForALicence, "xrdp demande une licence avant tout le reste")
        XCTAssertTrue(licensingFinished, "et il doit clore l'étape après notre demande")

        let screen = try XCTUnwrap(offer, "le serveur n'a jamais envoyé son Demand Active")
        XCTAssertEqual(screen.width, 1024, "l'écran demandé au Connect Initial")
        XCTAssertEqual(screen.height, 768)
        XCTAssertGreaterThan(screen.colourDepth, 0)

        // **Et voici la preuve que le Confirm Active a été accepté** : le
        // serveur ne renvoie ces quatre-là qu'à un client qu'il a compris, et
        // la carte des polices est le dernier message de l'établissement.
        XCTAssertTrue(seen.contains(.synchronise), "pas de synchronisation : \(seen)")
        XCTAssertTrue(seen.contains(.control), "pas de contrôle : \(seen)")
        XCTAssertTrue(seen.contains(.fontMap), "pas de carte des polices : \(seen)")

        // **Puis les pixels.** C'est ce qui distingue un établissement accepté
        // d'un établissement terminé : le serveur s'est mis à peindre.
        XCTAssertTrue(seen.contains(.update), "aucune mise à jour d'écran : \(seen)")
        XCTAssertTrue(seen.contains(.pointer), "aucun curseur : \(seen)")
    }
}

/// Une session établie qu'un test peut piloter : envoyer, et lire jusqu'au
/// silence. Écrite ici plutôt que recopiée dans chaque test, parce que la
/// séquence d'installation fait vingt lignes et que les recopier est la façon
/// dont deux tests finissent par mesurer deux choses différentes.
final class LiveRDPSession {
    let stream: PosixByteStream
    var session: RDPLiveHandshakeTests.Established
    private(set) var offer: RDPCapabilities.ServerOffer?
    /// Vrai dès que le serveur a raccroché ou démonté le partage.
    private(set) var ended = false
    /// Combien de PDU on lit avant de conclure au silence.
    static let rounds = 40

    init(host: String, port: Int, readTimeout: Int = 2) async throws {
        stream = try PosixByteStream(host: host, port: port, readTimeout: readTimeout)
        session = try await RDPLiveHandshakeTests.establish(stream)
    }

    func send(_ payload: Data, flags: RDPStandardSecurity.Flags = []) async throws {
        try await stream.write(RDPMCS.sendData(
            user: session.user, channel: session.server.ioChannel,
            session.security.seal(payload, flags: flags)))
    }

    /// Lire jusqu'à ce que le serveur se taise, en répondant à ce qui demande
    /// une réponse, et rendre les rectangles peints entre-temps.
    @discardableResult
    func drain() async -> [RDPBitmapUpdate.Rectangle] {
        var painted: [RDPBitmapUpdate.Rectangle] = []
        for _ in 0..<Self.rounds {
            var frame = Data()
            do {
                frame = try await RDPLiveHandshakeTests.readPDU(stream)
            } catch is PosixByteStream.Quiet {
                return painted                       // le serveur s'est tu, il est vivant
            } catch {
                ended = true
                return painted
            }
            guard let incoming = try? RDPMCS.readIncoming(frame) else { return painted }
            guard case .data(let indication) = incoming else {
                ended = true
                return painted
            }
            guard let clear = try? session.security.open(indication.payload) else { return painted }
            let flags = UInt16(indication.payload[0]) | UInt16(indication.payload[1]) << 8
            if flags & 0x0080 != 0 {
                if (try? RDPLicensing.read(clear)) == .wantsRequest {
                    try? await send(RDPLicensing.newLicenseRequest(user: "essai", machine: "wisq"),
                                    flags: [.licence])
                }
                continue
            }
            guard let received = try? RDPShare.read(clear) else { return painted }
            if received.kind == .deactivateAll { ended = true }
            if received.kind == .demandActive,
               let offered = try? RDPCapabilities.readDemandActive(received.body,
                                                                   source: received.source) {
                offer = offered
                try? await send(RDPCapabilities.confirmActive(
                    offer: offered, source: session.user,
                    width: offered.width, height: offered.height, depth: offered.colourDepth))
                for message in [
                    RDPShare.synchronise(share: offered.shareId, source: session.user,
                                         target: offered.source),
                    RDPShare.controlCooperate(share: offered.shareId, source: session.user),
                    RDPShare.controlRequest(share: offered.shareId, source: session.user),
                    RDPShare.fontList(share: offered.shareId, source: session.user)
                ] {
                    try? await send(message)
                }
            }
            if received.dataKind == .update,
               (try? RDPBitmapUpdate.kind(of: received.body)) == .bitmap,
               let rectangles = try? RDPBitmapUpdate.rectangles(received.body) {
                painted += rectangles
            }
        }
        return painted
    }
}

/// **Ce que le serveur fait de ce qu'on lui envoie**, contre un vrai xrdp.
///
/// Les tests hors ligne d'`RDPInputTests` disent que les octets ont la forme
/// que la spécification décrit. Ils ne disent pas qu'un serveur en fait quelque
/// chose — et **un PDU d'entrées mal formé ne provoque aucune plainte** : le
/// serveur le lit de travers, ou l'ignore, et rien ne le signale. Sabotés tour
/// à tour, un compte d'événements faux et un ordre de champs mélangé laissent
/// xrdp parfaitement calme. « La session n'est pas morte » ne mesure donc rien.
///
/// La seule mesure qui décide ici est donc un **effet visible** : une demande
/// de rafraîchissement oblige le serveur à repeindre une zone qu'il n'avait
/// aucune raison de repeindre. Sabotée — un mauvais type de PDU, un octet de
/// garniture en moins — elle fait échouer le test.
///
/// **Ce qui reste sans mesure, et qu'il faut dire.** Les événements de touche
/// et de souris eux-mêmes ne sont tenus par rien de vivant. Un clic sur le
/// bouton « Cancel » de la fenêtre d'ouverture de session fait bien raccrocher
/// xrdp — c'est vérifié — mais le bouton n'est trouvé qu'à une coordonnée
/// relevée à la main sur un écran de 1024×768, et un test qui en dépend casse
/// au premier changement de thème ou de version. Il vaut mieux une lacune
/// annoncée qu'un test qui échouera un jour pour une raison qui n'est pas la
/// bonne. La forme des octets, elle, est tenue hors ligne par `RDPInputTests`.
final class RDPLiveInputTests: XCTestCase {
    /// **Le serveur repeint ce qu'on lui demande de repeindre.**
    func testARealServerRepaintsWhatWeAskItTo() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let live = try await LiveRDPSession(host: target.host, port: target.port)
        // L'acteur de socket se ferme tout seul ; on capture lui, et pas la
        // session, qui n'est pas partageable entre tâches.
        let socket = live.stream
        defer { Task { await socket.close() } }

        await live.drain()
        let offer = try XCTUnwrap(live.offer, "le serveur n'a jamais envoyé son Demand Active")

        // Les entrées d'abord, pour vérifier au moins qu'elles ne cassent rien.
        try await live.send(try RDPInput.events([
            .synchronise([]),
            .pointer([.move], offer.width / 2, offer.height / 2),
            .key(0x1E, []), .key(0x1E, .release),
            RDPInput.wheel(-1, at: (offer.width / 2, offer.height / 2))
        ], share: offer.shareId, source: live.session.user))
        await live.drain()
        XCTAssertFalse(live.ended, "les entrées ne doivent pas démonter la session")

        // Puis la mesure : une zone que rien n'a modifiée.
        let area = (left: 0, top: 0, right: offer.width - 1, bottom: offer.height - 1)
        try await live.send(try RDPInput.refreshRect([area], share: offer.shareId,
                                                     source: live.session.user))
        let painted = await live.drain()

        XCTAssertFalse(painted.isEmpty,
                       "le serveur n'a rien repeint : la demande n'a pas été comprise")
        let covered = painted.reduce(0) {
            $0 + ($1.right - $1.left + 1) * ($1.bottom - $1.top + 1)
        }
        XCTAssertGreaterThan(covered, offer.width * offer.height / 4,
                             "seulement \(covered) pixels repeints sur un écran de "
                                + "\(offer.width * offer.height)")
    }

    /// **Mesuré : xrdp 0.9 ignore l'ordre d'arrêter de peindre.**
    ///
    /// La demande de suppression est le moyen prévu pour qu'un téléphone dont
    /// l'écran s'éteint cesse de recevoir des images qu'il ne montre pas. Elle
    /// a été essayée ici, peinture coupée puis rafraîchissement de tout
    /// l'écran : **cent quatre-vingt-neuf rectangles sont arrivés quand même**.
    /// Ce serveur-là ne l'applique pas.
    ///
    /// Le test n'affirme donc pas qu'elle marche — ce serait affirmer le
    /// contraire de ce qu'on a mesuré — ni qu'elle ne marche pas, ce qui
    /// figerait le défaut d'un serveur dans la suite de tests de wisq. Il tient
    /// ce qui est vrai des deux côtés : les deux PDU sont assez bien formés
    /// pour que la session leur survive et continue de peindre. **L'économie de
    /// batterie qu'ils promettent n'est pas acquise**, et l'application ne doit
    /// pas compter dessus tant qu'un serveur qui l'honore n'a pas été trouvé.
    func testTheSuppressRequestsLeaveTheSessionWorking() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let live = try await LiveRDPSession(host: target.host, port: target.port)
        let socket = live.stream
        defer { Task { await socket.close() } }
        await live.drain()
        let offer = try XCTUnwrap(live.offer)
        let whole = (left: 0, top: 0, right: offer.width - 1, bottom: offer.height - 1)

        for painting in [false, true] {
            try await live.send(RDPInput.suppressOutput(painting, width: offer.width,
                                                        height: offer.height,
                                                        share: offer.shareId,
                                                        source: live.session.user))
            await live.drain()
            XCTAssertFalse(live.ended,
                           "la demande de suppression (\(painting)) a démonté la session")
        }

        // Et après les deux, le serveur peint toujours ce qu'on lui demande.
        try await live.send(try RDPInput.refreshRect([whole], share: offer.shareId,
                                                     source: live.session.user))
        let painted = await live.drain()
        XCTAssertFalse(painted.isEmpty, "plus rien ne se peint")
    }
}

/// **La session entière, de la socket aux pixels**, contre un vrai xrdp.
///
/// Tout le reste de ce lot mesure une couche à la fois. Celui-ci mesure
/// `RDPSession` comme l'application l'emploie : on l'ouvre, on écoute ses
/// événements, et on regarde la trame. C'est la seule preuve que les morceaux
/// sont branchés les uns aux autres — chacun peut être juste pendant que le
/// tout ne peint rien.
final class RDPLiveSessionTests: XCTestCase {
    func testTheSessionReachesAReadyDesktopAndPaintsIt() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let configuration = SessionConfiguration(
            host: target.host, port: target.port, security: .none,
            username: "essai", password: "mauvais")
        let session = RDPSession(configuration: configuration) { _ in
            try PosixByteStream(host: target.host, port: target.port, readTimeout: 5)
        }

        await session.start()
        var ready: (width: Int, height: Int)?
        var painted = 0
        var failure: WisqError?

        // On s'arrête dès qu'il y a de quoi juger : le bureau est annoncé et
        // quelques régions ont été peintes.
        for await event in session.events {
            switch event {
            case .ready(_, let width, let height):
                ready = (width, height)
            case .framebufferChanged(let rectangles):
                painted += rectangles.count
            case .disconnected(let error):
                failure = error
            default:
                break
            }
            if painted >= 8 { break }
            if failure != nil { break }
        }
        await session.stop()

        XCTAssertNil(failure, "la session s'est fermée : \(String(describing: failure))")
        let desktop = try XCTUnwrap(ready, "aucun bureau annoncé")
        XCTAssertEqual(desktop.width, 1024)
        XCTAssertEqual(desktop.height, 768)
        XCTAssertGreaterThanOrEqual(painted, 8)

        // **Et la trame porte vraiment des pixels.** Un décodeur branché de
        // travers annonce des régions repeintes et laisse l'écran noir ; c'est
        // le défaut qu'aucune des couches d'en dessous ne peut voir.
        let (width, height, pixels) = session.framebuffer.snapshot()
        XCTAssertEqual(width, desktop.width)
        XCTAssertEqual(height, desktop.height)
        var lit = 0
        for at in stride(from: 0, to: pixels.count, by: 4) where pixels[at] != 0 {
            lit += 1
        }
        XCTAssertGreaterThan(lit, 1000,
                             "seulement \(lit) pixels non noirs sur \(width * height)")
    }
}
#endif
