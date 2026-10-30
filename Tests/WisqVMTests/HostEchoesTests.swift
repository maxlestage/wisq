import XCTest
@testable import WisqVM

/// Le ping de l'invité vers le dehors : voir `HostEchoes` et
/// `UserNetwork.outboundEcho`.
final class HostEchoesTests: XCTestCase {
    static func echo(identifier: UInt16, sequence: UInt16, type: UInt8 = 8) -> [UInt8] {
        var message: [UInt8] = [type, 0, 0, 0] + UserNetwork.be16Bytes(identifier) + UserNetwork.be16Bytes(sequence)
            + Array("wisq-ping".utf8)
        let sum = UserNetwork.checksum(message)
        message[2] = UInt8(sum >> 8)
        message[3] = UInt8(sum & 0xFF)
        return message
    }

    static func frame(to destination: [UInt8], _ message: [UInt8]) -> [UInt8] {
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: destination, protocol: 1, message)
        return UserNetwork.routerMAC + UserNetworkUDPTests.guestMAC + [0x08, 0x00] + ip
    }

    /// **La réponse reprend l'identifiant de l'invité** — le noyau y avait mis
    /// le sien —, sa somme refaite ; l'en-tête IPv4 que rend Darwin est ôté.
    func testTheReplyGetsTheGuestIdentifierBack() throws {
        let fromKernel = Self.echo(identifier: 0x406F, sequence: 7, type: 0)
        var asked: [HostEchoes.Pending] = []
        let restore: (HostEchoes.Pending) -> UInt16? = { asked.append($0); return 0x1234 }
        let linux = try XCTUnwrap(HostEchoes.reply(fromKernel, from: [1, 1, 1, 1], restoring: restore))
        XCTAssertEqual(UserNetwork.be16(linux.message, 4), 0x1234)
        XCTAssertEqual(UserNetwork.be16(linux.message, 6), 7)
        XCTAssertEqual(UserNetwork.checksum(linux.message), 0)
        XCTAssertEqual(Array(linux.message[8...]), Array("wisq-ping".utf8))
        XCTAssertEqual(asked, [.init(destination: [1, 1, 1, 1], sequence: 7)], "par la source et la séquence")

        let darwin = UserNetwork.ipv4Packet(from: [1, 1, 1, 1], to: [192, 168, 1, 9], protocol: 1, fromKernel)
        XCTAssertEqual(HostEchoes.reply(darwin, from: [1, 1, 1, 1], restoring: restore), linux)

        XCTAssertNil(HostEchoes.reply(fromKernel, from: [1, 1, 1, 1], restoring: { _ in nil }),
                     "une réponse que personne n'attend")
        XCTAssertNil(HostEchoes.reply(Self.echo(identifier: 1, sequence: 7, type: 8), from: [1, 1, 1, 1],
                                      restoring: restore), "une demande n'est pas une réponse")
        XCTAssertNil(HostEchoes.reply([0, 0, 0], from: [1, 1, 1, 1], restoring: restore))
    }

    /// L'écho qui part : entier, juste, une demande. Le serveur de noms, comme
    /// la passerelle, répond d'ici.
    func testWhatLeavesAndWhatIsAnsweredHere() throws {
        let message = Self.echo(identifier: 9, sequence: 1)
        let echo = try XCTUnwrap(UserNetwork.outboundEcho(Self.frame(to: [9, 9, 9, 9], message)))
        XCTAssertEqual(echo.destination, [9, 9, 9, 9])
        XCTAssertEqual(echo.message, message)
        var broken = message
        broken[9] ^= 1
        XCTAssertNil(UserNetwork.outboundEcho(Self.frame(to: [9, 9, 9, 9], broken)), "somme fausse")
        XCTAssertNil(UserNetwork.outboundEcho(Self.frame(to: [9, 9, 9, 9], Self.echo(identifier: 9, sequence: 1,
                                                                                      type: 0))),
                     "une réponse ne part pas")
        let local = try XCTUnwrap(UserNetwork.answer(Self.frame(to: UserNetwork.nameServer, message)).first)
        XCTAssertEqual(Array(local[14 + 12..<14 + 16]), UserNetwork.nameServer, "répond sous sa propre adresse")
        XCTAssertTrue(UserNetwork.answer(Self.frame(to: [9, 9, 9, 9], message)).isEmpty)
    }

    /// **Par une vraie socket**, vers la boucle locale de l'hôte, quand le
    /// système l'ouvre sans privilège : l'écho revient à l'invité, sous
    /// l'adresse jointe, avec son identifiant.
    func testARealEchoMakesTheRoundTrip() throws {
        guard let echoes = HostEchoes.make() else {
            throw XCTSkip("le système refuse la socket ICMP sans privilège (net.ipv4.ping_group_range)")
        }
        defer { echoes.close() }
        let network = UserNetwork(echoes: echoes)
        network.send(Self.frame(to: [127, 0, 0, 1], Self.echo(identifier: 0xBEEF, sequence: 3)))
        var frames: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(5)
        while frames.isEmpty, Date() < deadline {
            frames = network.receive()
            if frames.isEmpty { usleep(2_000) }
        }
        let frame = try XCTUnwrap(frames.first, "pas de réponse en cinq secondes")
        let ip = Array(frame[14...])
        XCTAssertEqual(Array(ip[12..<16]), [127, 0, 0, 1])
        XCTAssertEqual(Array(ip[16..<20]), UserNetwork.guest)
        let icmp = Array(ip[20...])
        XCTAssertEqual(icmp[0], 0, "une réponse")
        XCTAssertEqual(UserNetwork.be16(icmp, 4), 0xBEEF)
        XCTAssertEqual(UserNetwork.be16(icmp, 6), 3)
        XCTAssertEqual(UserNetwork.checksum(icmp), 0)
    }
}
