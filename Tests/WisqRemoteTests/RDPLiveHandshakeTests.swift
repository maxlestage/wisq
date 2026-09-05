#if canImport(Glibc)
import XCTest

@testable import WisqNet
@testable import WisqRemote

/// La poignée de main, contre un **vrai serveur**.
///
/// **C'est la mesure qui décide.** Des vecteurs recopiés d'une capture disent
/// qu'on écrit les mêmes octets que le client de référence ; ils ne disent pas
/// qu'un serveur les accepte. Ce test-ci ouvre une socket, parle, et lit la
/// réponse — la seule preuve qu'une session RDP fonctionne étant une session
/// RDP.
///
/// Il se saute quand aucun serveur n'écoute, comme le test de démarrage x86 se
/// saute sans noyau : la CI n'a pas de serveur RDP, et un test qui échoue là où
/// il n'y a rien à mesurer n'apprend rien à personne.
///
///     apt-get install -y xrdp && /usr/sbin/xrdp --nodaemon &
///     WISQ_RDP_HOST=127.0.0.1 swift test --filter RDPLiveHandshakeTests
final class RDPLiveHandshakeTests: XCTestCase {
    static func target() throws -> (host: String, port: Int) {
        guard let host = ProcessInfo.processInfo.environment["WISQ_RDP_HOST"] else {
            throw XCTSkip("aucun serveur RDP : définir WISQ_RDP_HOST pour ce test")
        }
        let port = ProcessInfo.processInfo.environment["WISQ_RDP_PORT"].flatMap(Int.init) ?? 3389
        return (host, port)
    }

    /// Lire une réponse entière : l'en-tête d'abord, puis ce qu'il annonce.
    static func readPDU(_ stream: PosixByteStream) async throws -> Data {
        let header = try await stream.read(exactly: RDPWire.tpktHeaderBytes)
        let length = try RDPWire.payloadLength(ofHeader: header)
        return try await stream.read(exactly: length)
    }

    /// **Le serveur accepte notre premier paquet et répond une confirmation.**
    func testARealServerConfirmsTheConnection() async throws {
        let target = try Self.target()
        let stream = try PosixByteStream(host: target.host, port: target.port)
        defer { Task { await stream.close() } }

        try await stream.write(RDPWire.connectionRequest(user: "essai", requesting: .standard))
        let confirm = try await RDPWire.readConnectionConfirm(Self.readPDU(stream))
        // xrdp répond « rien » à une demande sans négociation : c'est la
        // sécurité historique, et c'est une réponse.
        XCTAssertEqual(confirm, .standardSecurity)
    }

    /// **Et il choisit TLS quand on le lui demande.** C'est ce qui distingue un
    /// paquet bien formé d'un paquet compris : le serveur a lu la structure de
    /// négociation, pas seulement l'en-tête.
    func testARealServerSelectsTLSWhenAsked() async throws {
        let target = try Self.target()
        let stream = try PosixByteStream(host: target.host, port: target.port)
        defer { Task { await stream.close() } }

        try await stream.write(RDPWire.connectionRequest(user: "essai", requesting: .tls))
        let confirm = try await RDPWire.readConnectionConfirm(Self.readPDU(stream))
        guard case .selected(let protocols, _) = confirm else {
            return XCTFail("attendu un choix, obtenu \(confirm)")
        }
        XCTAssertTrue(protocols.contains(.tls), "le serveur a choisi \(protocols.rawValue)")
    }
}
#endif

/// Le domaine MCS, contre un **vrai serveur**.
///
/// **C'est la tranche entière qui se juge ici.** Trois encodages empilés — BER,
/// PER, des blocs à champs fixes — et rien d'autre qu'un serveur ne peut dire
/// si on les a empilés dans le bon ordre : un Connect Initial mal formé ne
/// donne pas d'erreur, il donne une socket qui se ferme.
final class RDPLiveMCSTests: XCTestCase {
    func testARealServerOpensItsDomainAndJoinsEveryChannel() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let stream = try PosixByteStream(host: target.host, port: target.port)
        defer { Task { await stream.close() } }

        // La négociation, puis la conférence.
        try await stream.write(RDPWire.connectionRequest(user: "essai", requesting: .standard))
        _ = try await RDPWire.readConnectionConfirm(RDPLiveHandshakeTests.readPDU(stream))

        let client = RDPConnect.ClientDescription(
            width: 1024, height: 768, name: "wisq",
            channels: [RDPConnect.Channel(name: "cliprdr", options: 0xC0A0_0000)])
        try await stream.write(RDPConnect.connectInitial(client))
        let response = try await RDPLiveHandshakeTests.readPDU(stream)
        let server = try RDPConnect.readConnectResponse(response)

        // Le serveur a nommé son canal d'entrée-sortie et le nôtre.
        XCTAssertGreaterThanOrEqual(server.ioChannel, RDPMCS.userChannelBase)
        XCTAssertEqual(server.channels.count, client.channels.count,
                       "un identifiant par canal demandé")

        // Le domaine, puis l'utilisateur.
        try await stream.write(RDPMCS.erectDomainRequest())
        try await stream.write(RDPMCS.attachUserRequest())
        let user = try RDPMCS.readAttachUserConfirm(
            try await RDPLiveHandshakeTests.readPDU(stream))
        XCTAssertGreaterThanOrEqual(user, RDPMCS.userChannelBase)

        // **Et chaque canal se joint, celui de l'utilisateur compris.** C'est
        // la preuve que les identifiants lus dans la réponse sont les bons :
        // un serveur refuse net un canal qu'il n'a pas annoncé.
        for channel in [user, server.ioChannel] + server.channels {
            try await stream.write(RDPMCS.channelJoinRequest(user: user, channel: channel))
            let confirm = try await RDPLiveHandshakeTests.readPDU(stream)
            try RDPMCS.readChannelJoinConfirm(confirm, expecting: channel)
        }
    }
}

/// **L'échange de clés, contre un vrai serveur.**
///
/// C'est la mesure la plus dure de tout le lot. Si le module RSA est lu à
/// l'envers, si les clés sont dérivées d'une moitié d'aléa de trop, ou si la
/// signature porte sur le chiffré au lieu du clair, le serveur ne dit rien :
/// il ferme. Le seul verdict est qu'il continue à parler.
final class RDPLiveSecurityTests: XCTestCase {
    func testARealServerAcceptsOurKeysAndAnswersTheLogin() async throws {
        let target = try RDPLiveHandshakeTests.target()
        let stream = try PosixByteStream(host: target.host, port: target.port)
        defer { Task { await stream.close() } }
        func pdu() async throws -> Data { try await RDPLiveHandshakeTests.readPDU(stream) }

        try await stream.write(RDPWire.connectionRequest(user: "essai", requesting: .standard))
        guard try RDPWire.readConnectionConfirm(await pdu()) == .standardSecurity else {
            throw XCTSkip("ce serveur ne parle pas la sécurité historique")
        }

        let client = RDPConnect.ClientDescription(width: 1024, height: 768, name: "wisq")
        try await stream.write(RDPConnect.connectInitial(client))
        let server = try RDPConnect.readConnectResponse(await pdu())
        XCTAssertFalse(server.certificate.isEmpty, "un serveur en sécurité historique a un certificat")

        try await stream.write(RDPMCS.erectDomainRequest())
        try await stream.write(RDPMCS.attachUserRequest())
        let user = try RDPMCS.readAttachUserConfirm(await pdu())
        for channel in [user, server.ioChannel] {
            try await stream.write(RDPMCS.channelJoinRequest(user: user, channel: channel))
            try RDPMCS.readChannelJoinConfirm(await pdu(), expecting: channel)
        }

        // L'échange de clés. L'aléa est tiré une fois et ne ressort jamais.
        let key = try RDPStandardSecurity.publicKey(
            fromCertificate: [UInt8](server.certificate))
        XCTAssertEqual(key.usefulBytes * 8, 2048, "xrdp emploie une clé de 2048 bits")
        let clientRandom = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let exchange = try RDPStandardSecurity.securityExchange(clientRandom: clientRandom, key: key)
        try await stream.write(RDPMCS.sendData(user: user, channel: server.ioChannel, exchange))

        var security = RDPStandardSecurity(keys: try RDPStandardSecurity.deriveKeys(
            clientRandom: clientRandom, serverRandom: [UInt8](server.serverRandom),
            method: server.encryptionMethod))

        // **Et le premier message signé.** Un mot de passe faux est très bien :
        // ce qu'on mesure est que le serveur *comprend* le paquet, pas qu'il
        // ouvre une session.
        let info = RDPClientInfo.packet(user: "essai", password: "mauvais",
                                        flags: RDPClientInfo.defaultFlags.union(.forceEncryptedCSPDU))
        let sealed = security.seal(info, flags: [.info])
        try await stream.write(RDPMCS.sendData(user: user, channel: server.ioChannel, sealed))

        // Le serveur répond la licence — c'est la preuve qu'il a lu le paquet.
        // S'il n'avait pas su le déchiffrer, il aurait fermé sans un mot.
        guard case .data(let indication) = try RDPMCS.readIncoming(await pdu()) else {
            return XCTFail("le serveur a raccroché : la cryptographie ne va pas")
        }
        XCTAssertEqual(indication.channel, server.ioChannel)
        let flags = UInt16(indication.payload[0]) | UInt16(indication.payload[1]) << 8
        XCTAssertNotEqual(flags & 0x0080, 0,
                          "attendu un message de licence, drapeaux 0x\(String(flags, radix: 16))")
    }
}
