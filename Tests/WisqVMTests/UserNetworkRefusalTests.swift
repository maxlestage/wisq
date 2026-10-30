import XCTest
@testable import WisqVM

/// La passerelle d'un réseau coupé refuse tout de suite : voir
/// `UserNetwork.refusal`.
final class UserNetworkRefusalTests: XCTestCase {
    /// Une question DNS pour `example.org`, type A, avec l'option EDNS qu'un
    /// résolveur moderne ajoute.
    static let query: [UInt8] = [0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1]
        + [7] + Array("example".utf8) + [3] + Array("org".utf8) + [0, 0, 1, 0, 1]
        + [0, 0, 41, 0x04, 0xD0, 0, 0, 0, 0, 0, 0]

    static func udp(_ payload: [UInt8], to destination: [UInt8], port: UInt16) -> [UInt8] {
        let udp = UserNetwork.udpDatagram(sourcePort: 41_000, destinationPort: port, payload,
                                          from: UserNetwork.guest, to: destination)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: destination, protocol: 17, udp)
        return UserNetwork.routerMAC + UserNetworkTests.guestMAC + [0x08, 0x00] + ip
    }

    static func echo(to destination: [UInt8]) -> [UInt8] {
        var message: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0, 1] + Array("wisq".utf8)
        let sum = UserNetwork.checksum(message)
        message[2] = UInt8(sum >> 8)
        message[3] = UInt8(sum & 0xFF)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: destination, protocol: 1, message)
        return UserNetwork.routerMAC + UserNetworkTests.guestMAC + [0x08, 0x00] + ip
    }

    /// **Le nom cherché : « refusé », tout de suite** — même identifiant,
    /// même question, pas de réponse, et sans l'option EDNS de la demande.
    func testANameLookupIsRefusedAtOnce() throws {
        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        cut.send(Self.udp(Self.query, to: UserNetwork.nameServer, port: 53))
        let frame = try XCTUnwrap(cut.receive().first)
        let ip = Array(frame[14...])
        XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0)
        XCTAssertEqual(Array(ip[12..<16]), UserNetwork.nameServer)
        let udp = Array(ip[20...])
        XCTAssertEqual(UserNetwork.be16(udp, 0), 53)
        XCTAssertEqual(UserNetwork.be16(udp, 2), 41_000)
        let pseudo = Array(ip[12..<20]) + [0, 17] + UserNetwork.be16Bytes(UInt16(udp.count))
        XCTAssertEqual(UserNetwork.checksum(pseudo + udp), 0)
        let dns = Array(udp[8...])
        XCTAssertEqual(Array(dns[0..<2]), [0xAB, 0xCD], "le même identifiant")
        XCTAssertEqual(dns[2], 0x81, "une réponse, récursion demandée reprise")
        XCTAssertEqual(dns[3] & 0x0F, 5, "refusé")
        XCTAssertEqual(Array(dns[4..<12]), [0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(dns[12...]), Array(Self.query[12..<29]), "la question, et rien d'autre")
    }

    /// **Le reste : « réseau injoignable »**, de la passerelle, avec l'en-tête
    /// du paquet refusé et ses huit premiers octets.
    func testTheRestIsUnreachable() throws {
        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        for sent in [Self.udp(Array("bonjour".utf8), to: [93, 184, 215, 14], port: 9999),
                     Self.echo(to: [1, 1, 1, 1])] {
            cut.send(sent)
            let frame = try XCTUnwrap(cut.receive().first)
            let ip = Array(frame[14...])
            XCTAssertEqual(ip[9], 1, "ICMP")
            XCTAssertEqual(Array(ip[12..<16]), UserNetwork.gateway)
            let icmp = Array(ip[20...])
            XCTAssertEqual(Array(icmp[0..<2]), [3, 0], "réseau injoignable")
            XCTAssertEqual(UserNetwork.checksum(icmp), 0)
            XCTAssertEqual(Array(icmp[8...]), Array(sent[14..<(14 + 28)]))
        }
    }

    /// Rien en réponse à une diffusion, une multidiffusion, ou à la
    /// passerelle elle-même ; et rien d'un réseau qui n'est pas coupé.
    func testWhatIsNotRefused() {
        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        for silent in [Self.udp([1, 2, 3], to: [224, 0, 0, 251], port: 5353),
                       Self.udp([1, 2, 3], to: [255, 255, 255, 255], port: 9),
                       Self.udp([1, 2, 3], to: [10, 0, 2, 255], port: 137),
                       Self.udp([1, 2, 3], to: UserNetwork.gateway, port: 9)] {
            cut.send(silent)
            XCTAssertTrue(cut.receive().isEmpty)
        }
        let open = UserNetwork()
        open.send(Self.udp(Self.query, to: UserNetwork.nameServer, port: 53))
        open.send(Self.echo(to: [1, 1, 1, 1]))
        XCTAssertTrue(open.receive().isEmpty, "un réseau qui n'est pas coupé ne refuse rien")
    }

    /// Une question illisible n'a pas de réponse DNS : elle reçoit l'ICMP.
    func testAnUnreadableQuestion() throws {
        XCTAssertNil(UserNetwork.refusedQuestion([0, 1, 0x81, 0x80] + [UInt8](repeating: 0, count: 8)),
                     "une réponse n'est pas une question")
        XCTAssertNil(UserNetwork.refusedQuestion([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 0x65]),
                     "un nom coupé")
        // Assez d'octets derrière le pointeur pour qu'un lecteur qui le
        // prendrait pour une longueur trouve quand même une fin.
        XCTAssertNil(UserNetwork.refusedQuestion([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C]
                                                 + [UInt8](repeating: 0, count: 200)),
                     "un pointeur dans une question")
        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        cut.send(Self.udp([0, 1, 1, 0, 0, 2], to: UserNetwork.nameServer, port: 53))
        let frame = try XCTUnwrap(cut.receive().first)
        XCTAssertEqual(frame[14 + 9], 1, "ICMP")
    }
}
