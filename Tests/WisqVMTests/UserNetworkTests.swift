import XCTest
@testable import WisqVM

/// Le réseau en mode utilisateur, première tranche : ARP, DHCP et l'écho de
/// la passerelle. Voir `UserNetwork`.
final class UserNetworkTests: XCTestCase {
    static let guestMAC = VirtioNet.defaultMAC

    /// Ce qu'un client DHCP diffuse : une découverte ou une demande.
    static func dhcpMessage(kind: UInt8, xid: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 240)
        message[0] = 1
        message[1] = 1
        message[2] = 6
        message.replaceSubrange(4..<8, with: xid)
        message.replaceSubrange(28..<34, with: guestMAC)
        message.replaceSubrange(236..<240, with: UserNetwork.dhcpMagic)
        message += [53, 1, kind, 255]
        let udp = UserNetwork.udpDatagram(sourcePort: 68, destinationPort: 67, message,
                                          from: [0, 0, 0, 0], to: [255, 255, 255, 255])
        let ip = UserNetwork.ipv4Packet(from: [0, 0, 0, 0], to: [255, 255, 255, 255], protocol: 17, udp)
        return UserNetwork.broadcastMAC + guestMAC + [0x08, 0x00] + ip
    }

    /// Les options d'une réponse DHCP, par code.
    static func options(_ reply: [UInt8]) -> [UInt8: [UInt8]] {
        let ip = Array(reply[14...])
        let udp = Array(ip[20...])
        let dhcp = Array(udp[8...])
        var found: [UInt8: [UInt8]] = [:]
        var at = 240
        while at < dhcp.count, dhcp[at] != 255 {
            let length = Int(dhcp[at + 1])
            found[dhcp[at]] = Array(dhcp[(at + 2)..<(at + 2 + length)])
            at += 2 + length
        }
        return found
    }

    /// **Le bail** : une offre à la découverte, puis un accord à la demande,
    /// pour 10.0.2.15, avec la passerelle, le masque et le serveur de noms.
    func testTheGuestGetsItsLease() throws {
        for (asked, answered) in [(UInt8(1), UInt8(2)), (3, 5)] {
            let replies = UserNetwork.answer(Self.dhcpMessage(kind: asked))
            XCTAssertEqual(replies.count, 1)
            let reply = try XCTUnwrap(replies.first)
            XCTAssertEqual(Array(reply[0..<6]), UserNetwork.broadcastMAC)
            XCTAssertEqual(Array(reply[6..<12]), UserNetwork.routerMAC)
            let ip = Array(reply[14...])
            XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0, "en-tête IPv4 juste")
            let dhcp = Array(ip[28...])
            XCTAssertEqual(dhcp[0], 2)
            XCTAssertEqual(Array(dhcp[4..<8]), [0xDE, 0xAD, 0xBE, 0xEF], "le même xid")
            XCTAssertEqual(Array(dhcp[16..<20]), UserNetwork.guest)
            XCTAssertEqual(Array(dhcp[28..<34]), Self.guestMAC)
            let options = Self.options(reply)
            XCTAssertEqual(options[53], [answered])
            XCTAssertEqual(options[1], UserNetwork.netmask)
            XCTAssertEqual(options[3], UserNetwork.gateway)
            XCTAssertEqual(options[6], UserNetwork.nameServer)
            XCTAssertEqual(options[54], UserNetwork.gateway)
            // La somme UDP, avec le pseudo-en-tête : nulle sur un datagramme juste.
            let udp = Array(ip[20...])
            let pseudo = Array(ip[12..<20]) + [0, 17] + UserNetwork.be16Bytes(UInt16(udp.count))
            XCTAssertEqual(UserNetwork.checksum(pseudo + udp), 0)
        }
        XCTAssertTrue(UserNetwork.answer(Self.dhcpMessage(kind: 7)).isEmpty, "une libération n'appelle pas de réponse")
    }

    /// **ARP** : la passerelle et le serveur de noms répondent, sous l'adresse
    /// de la passerelle ; une autre adresse, personne.
    func testTheGatewayAnswersARP() throws {
        func request(_ target: [UInt8]) -> [UInt8] {
            let arp: [UInt8] = [0, 1, 0x08, 0x00, 6, 4, 0, 1] + Self.guestMAC + UserNetwork.guest
                + [UInt8](repeating: 0, count: 6) + target
            return UserNetwork.broadcastMAC + Self.guestMAC + [0x08, 0x06] + arp
        }
        for target in [UserNetwork.gateway, UserNetwork.nameServer] {
            let reply = try XCTUnwrap(UserNetwork.answer(request(target)).first)
            XCTAssertEqual(Array(reply[0..<6]), Self.guestMAC)
            let arp = Array(reply[14...])
            XCTAssertEqual(Array(arp[6..<8]), [0, 2], "une réponse")
            XCTAssertEqual(Array(arp[8..<14]), UserNetwork.routerMAC)
            XCTAssertEqual(Array(arp[14..<18]), target)
            XCTAssertEqual(Array(arp[24..<28]), UserNetwork.guest)
        }
        XCTAssertTrue(UserNetwork.answer(request([10, 0, 2, 99])).isEmpty)
    }

    /// **L'écho de la passerelle** : mêmes identifiant, séquence et données,
    /// type zéro, sommes justes.
    func testThePingOfTheGatewayIsAnswered() throws {
        var echo: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0, 1] + Array("wisq".utf8)
        let sum = UserNetwork.checksum(echo)
        echo[2] = UInt8(sum >> 8)
        echo[3] = UInt8(sum & 0xFF)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: UserNetwork.gateway, protocol: 1, echo)
        let frame = UserNetwork.routerMAC + Self.guestMAC + [0x08, 0x00] + ip
        let reply = try XCTUnwrap(UserNetwork.answer(frame).first)
        let answer = Array(reply[14...])
        XCTAssertEqual(Array(answer[12..<16]), UserNetwork.gateway)
        XCTAssertEqual(Array(answer[16..<20]), UserNetwork.guest)
        let icmp = Array(answer[20...])
        XCTAssertEqual(icmp[0], 0)
        XCTAssertEqual(Array(icmp[4...]), Array(echo[4...]))
        XCTAssertEqual(UserNetwork.checksum(icmp), 0)
        // Un écho vers une autre adresse n'a personne pour y répondre.
        let elsewhere = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: [1, 1, 1, 1], protocol: 1, echo)
        XCTAssertTrue(UserNetwork.answer(UserNetwork.routerMAC + Self.guestMAC + [0x08, 0x00] + elsewhere).isEmpty)
    }

    /// Un en-tête IPv4 abîmé est ignoré, pas répondu.
    func testABrokenHeaderIsIgnored() {
        var frame = Self.dhcpMessage(kind: 1)
        frame[14 + 10] ^= 0xFF
        XCTAssertTrue(UserNetwork.answer(frame).isEmpty)
        XCTAssertTrue(UserNetwork.answer([1, 2, 3]).isEmpty)
    }

    /// Par la carte : ce que l'invité envoie produit ce qu'il reçoit.
    func testTheBackendHandsItsRepliesToTheCard() {
        let network = UserNetwork()
        network.send(Self.dhcpMessage(kind: 1))
        XCTAssertEqual(network.receive().count, 1)
        XCTAssertTrue(network.receive().isEmpty, "rendues une seule fois")
    }
}
