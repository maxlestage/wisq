import XCTest
@testable import WisqVM

/// L'heure servie par la passerelle : voir `UserNetwork.ntp`.
final class UserNetworkTimeTests: XCTestCase {
    /// Une demande de client, version `version`, envoyée à `sent`.
    static func request(version: UInt8 = 4, mode: UInt8 = 3, poll: UInt8 = 6, sent: [UInt8]) -> [UInt8] {
        [version << 3 | mode, 0, poll, 0] + [UInt8](repeating: 0, count: 36) + sent
    }

    /// La trame qu'un client enverrait à `destination`:123.
    static func frame(_ payload: [UInt8], to destination: [UInt8] = UserNetwork.gateway) -> [UInt8] {
        let udp = UserNetwork.udpDatagram(sourcePort: 40_123, destinationPort: 123, payload,
                                          from: UserNetwork.guest, to: destination)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: destination, protocol: 17, udp)
        return UserNetwork.routerMAC + UserNetworkTests.guestMAC + [0x08, 0x00] + ip
    }

    /// **Un horodatage NTP** compte depuis 1900, la fraction en deux cent
    /// trente-deuxièmes.
    func testTimestamps() {
        XCTAssertEqual(UserNetwork.ntpTimestamp(Date(timeIntervalSince1970: 0)),
                       UserNetwork.be32Bytes(2_208_988_800) + [0, 0, 0, 0])
        XCTAssertEqual(UserNetwork.ntpTimestamp(Date(timeIntervalSince1970: 1.5)),
                       UserNetwork.be32Bytes(2_208_988_801) + [0x80, 0, 0, 0])
    }

    /// **La réponse** : un serveur (mode quatre) de strate un, de la version
    /// du client, son intervalle repris, son heure d'envoi rendue, et
    /// l'heure du téléphone en réception et en envoi.
    func testTheReplyIsWhatTheClientExpects() throws {
        let now = Date(timeIntervalSince1970: 1_793_386_270.25)
        let sent: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let reply = try XCTUnwrap(UserNetwork.ntp(Self.request(version: 3, poll: 10, sent: sent), now: now))
        XCTAssertEqual(reply.count, 48)
        XCTAssertEqual(reply[0], 3 << 3 | 4, "pas d'avertissement, version trois, serveur")
        XCTAssertEqual(reply[1], 1, "strate un")
        XCTAssertEqual(reply[2], 10, "l'intervalle du client")
        XCTAssertEqual(Array(reply[12..<16]), Array("WISQ".utf8))
        XCTAssertEqual(Array(reply[24..<32]), sent, "l'envoi du client, pour qu'il reconnaisse sa réponse")
        let stamp = UserNetwork.ntpTimestamp(now)
        XCTAssertEqual(Array(reply[32..<40]), stamp)
        XCTAssertEqual(Array(reply[40..<48]), stamp)
        XCTAssertEqual(UserNetwork.be32(reply, 40), UInt32(1_793_386_270 + 2_208_988_800))
    }

    /// Seul un client est servi : ni un serveur, ni une diffusion, ni un
    /// paquet trop court.
    func testOnlyAClientIsAnswered() {
        let now = Date()
        XCTAssertNil(UserNetwork.ntp(Self.request(mode: 4, sent: [0, 0, 0, 0, 0, 0, 0, 1]), now: now))
        XCTAssertNil(UserNetwork.ntp(Self.request(mode: 5, sent: [0, 0, 0, 0, 0, 0, 0, 1]), now: now))
        XCTAssertNil(UserNetwork.ntp([0x23] + [UInt8](repeating: 0, count: 40), now: now))
    }

    /// **Par les trames** : la passerelle répond de son port 123 au port du
    /// client, sommes justes, avec l'heure de maintenant.
    func testThroughTheFrames() throws {
        let before = Date()
        let replies = UserNetwork.answer(Self.frame(Self.request(sent: [9, 9, 9, 9, 9, 9, 9, 9])))
        let reply = try XCTUnwrap(replies.first)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(Array(reply[0..<6]), UserNetworkTests.guestMAC)
        let ip = Array(reply[14...])
        XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0)
        XCTAssertEqual(Array(ip[12..<16]), UserNetwork.gateway)
        XCTAssertEqual(Array(ip[16..<20]), UserNetwork.guest)
        let udp = Array(ip[20...])
        XCTAssertEqual(UserNetwork.be16(udp, 0), 123)
        XCTAssertEqual(UserNetwork.be16(udp, 2), 40_123)
        let pseudo = Array(ip[12..<20]) + [0, 17] + UserNetwork.be16Bytes(UInt16(udp.count))
        XCTAssertEqual(UserNetwork.checksum(pseudo + udp), 0)
        let seconds = TimeInterval(UserNetwork.be32(Array(udp[8...]), 40)) - UserNetwork.ntpEpochOffset
        XCTAssertEqual(seconds, before.timeIntervalSince1970, accuracy: 2)
    }

    /// **Réseau coupé, l'heure reste** : la passerelle répond d'elle-même,
    /// et une demande vers un serveur du dehors est refusée (voir
    /// `UserNetwork.refusal`), pas servie.
    func testTimeSurvivesACutNetwork() throws {
        let cut = UserNetwork.isolated()
        defer { cut.streams?.close() }
        cut.send(Self.frame(Self.request(sent: [1, 1, 1, 1, 1, 1, 1, 1])))
        let served = try XCTUnwrap(cut.receive().first)
        XCTAssertEqual(served[14 + 9], 17, "une réponse NTP")
        cut.send(Self.frame(Self.request(sent: [1, 1, 1, 1, 1, 1, 1, 1]), to: [162, 159, 200, 1]))
        let refused = try XCTUnwrap(cut.receive().first)
        XCTAssertEqual(refused[14 + 9], 1, "un ICMP « injoignable », pas une heure")
    }
}
