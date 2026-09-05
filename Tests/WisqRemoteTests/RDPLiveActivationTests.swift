#if canImport(Glibc)
import XCTest

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
#endif
