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
