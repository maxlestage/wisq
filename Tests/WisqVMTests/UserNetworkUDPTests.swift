import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import WisqVM

/// L'UDP de l'invité vers le dehors : voir `UserNetwork.outboundDatagram`,
/// `UserNetwork.frames(for:to:identification:)` et `HostDatagrams`.
final class UserNetworkUDPTests: XCTestCase {
    static let guestMAC: [UInt8] = [0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC]

    static func udpFrame(to destination: [UInt8], port: UInt16, from sourcePort: UInt16,
                         _ payload: [UInt8]) -> [UInt8] {
        let udp = UserNetwork.udpDatagram(sourcePort: sourcePort, destinationPort: port, payload,
                                          from: UserNetwork.guest, to: destination)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: destination, protocol: 17, udp)
        return UserNetwork.routerMAC + guestMAC + [0x08, 0x00] + ip
    }

    final class Recorder: DatagramRelay {
        var sent: [(payload: [UInt8], destination: [UInt8], port: UInt16, guestPort: UInt16)] = []
        var waiting: [UserNetwork.Datagram] = []

        func send(_ payload: [UInt8], to destination: [UInt8], port: UInt16, fromGuestPort guestPort: UInt16) {
            sent.append((payload, destination, port, guestPort))
        }

        func receive() -> [UserNetwork.Datagram] {
            defer { waiting.removeAll() }
            return waiting
        }
    }

    /// **Une requête DNS part au relais** telle que l'invité l'a adressée, et
    /// la réponse revient à son port, à son adresse matérielle, sous
    /// `10.0.2.3:53`, sommes justes.
    func testADNSQueryGoesOutAndItsAnswerComesBack() throws {
        let recorder = Recorder()
        let network = UserNetwork(relay: recorder)
        network.send(Self.udpFrame(to: UserNetwork.nameServer, port: 53, from: 40_000, Array("question".utf8)))
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertEqual(recorder.sent.first?.payload, Array("question".utf8))
        XCTAssertEqual(recorder.sent.first?.destination, UserNetwork.nameServer)
        XCTAssertEqual(recorder.sent.first?.port, 53)
        XCTAssertEqual(recorder.sent.first?.guestPort, 40_000)
        XCTAssertTrue(network.receive().isEmpty)

        recorder.waiting = [.init(source: UserNetwork.nameServer, sourcePort: 53, guestPort: 40_000,
                                  payload: Array("réponse".utf8))]
        let frame = try XCTUnwrap(network.receive().first)
        XCTAssertEqual(Array(frame[0..<6]), Self.guestMAC, "à l'adresse apprise, pas à celle par défaut")
        let ip = Array(frame[14...])
        XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0)
        XCTAssertEqual(Array(ip[12..<16]), UserNetwork.nameServer)
        XCTAssertEqual(Array(ip[16..<20]), UserNetwork.guest)
        let udp = Array(ip[20...])
        XCTAssertEqual(UserNetwork.be16(udp, 0), 53)
        XCTAssertEqual(UserNetwork.be16(udp, 2), 40_000)
        XCTAssertEqual(Array(udp[8...]), Array("réponse".utf8))
        let pseudo = Array(ip[12..<20]) + [0, 17] + UserNetwork.be16Bytes(UInt16(udp.count))
        XCTAssertEqual(UserNetwork.checksum(pseudo + udp), 0)
    }

    /// Le DHCP reste local, et un fragment ou un en-tête abîmé ne part pas.
    func testWhatStaysHome() {
        let recorder = Recorder()
        let network = UserNetwork(relay: recorder)
        network.send(UserNetworkTests.dhcpMessage(kind: 1))
        XCTAssertTrue(recorder.sent.isEmpty, "le bail est servi ici")
        var fragment = Self.udpFrame(to: [8, 8, 8, 8], port: 53, from: 1000, [1, 2, 3])
        fragment[14 + 6] = 0x20  // « d'autres fragments suivent »
        fragment[14 + 10] = 0
        fragment[14 + 11] = 0
        let sum = UserNetwork.checksum(Array(fragment[14..<34]))
        fragment[14 + 10] = UInt8(sum >> 8)
        fragment[14 + 11] = UInt8(sum & 0xFF)
        XCTAssertNil(UserNetwork.outboundDatagram(fragment))
        var broken = Self.udpFrame(to: [8, 8, 8, 8], port: 53, from: 1000, [1, 2, 3])
        broken[14 + 8] ^= 1
        XCTAssertNil(UserNetwork.outboundDatagram(broken))
        XCTAssertNotNil(UserNetwork.outboundDatagram(Self.udpFrame(to: [8, 8, 8, 8], port: 53, from: 1000, [1])))
    }

    /// **Une réponse plus grande qu'une trame est fragmentée** : des morceaux
    /// multiples de huit, le même identifiant, « d'autres suivent » sauf sur
    /// le dernier, et rien de perdu.
    func testALargeAnswerIsFragmented() {
        let payload = (0..<3000).map { UInt8($0 & 0xFF) }
        let frames = UserNetwork.frames(for: .init(source: [1, 1, 1, 1], sourcePort: 53, guestPort: 999,
                                                   payload: payload),
                                        to: Self.guestMAC, identification: 0x4242)
        XCTAssertEqual(frames.count, 3)
        var joined: [UInt8] = []
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(frame.count, VirtioNet.largestFrame)
            let ip = Array(frame[14...])
            XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0)
            XCTAssertEqual(UserNetwork.be16(ip, 4), 0x4242)
            let field = UserNetwork.be16(ip, 6)
            XCTAssertEqual(Int(field & 0x1FFF) * 8, joined.count)
            XCTAssertEqual(field & 0x2000 != 0, index < frames.count - 1)
            XCTAssertEqual(Int(UserNetwork.be16(ip, 2)), ip.count)
            joined += ip[20...]
        }
        XCTAssertEqual(Array(joined[8...]), payload)
        let small = UserNetwork.frames(for: .init(source: [1, 1, 1, 1], sourcePort: 53, guestPort: 999,
                                                  payload: [1]), to: Self.guestMAC, identification: 1)
        XCTAssertEqual(small.count, 1)
        XCTAssertEqual(UserNetwork.be16(Array(small[0][14...]), 6), 0x4000, "entier : ne pas fragmenter")
    }

    func testTheTranslatedAddresses() {
        let resolver: [UInt8] = [9, 9, 9, 9]
        XCTAssertEqual(HostDatagrams.hostEndpoint(for: UserNetwork.nameServer, port: 53, resolver: resolver), resolver)
        XCTAssertNil(HostDatagrams.hostEndpoint(for: UserNetwork.nameServer, port: 123, resolver: resolver))
        XCTAssertEqual(HostDatagrams.hostEndpoint(for: UserNetwork.gateway, port: 7, resolver: resolver),
                       [127, 0, 0, 1])
        XCTAssertEqual(HostDatagrams.hostEndpoint(for: [8, 8, 4, 4], port: 53, resolver: resolver), [8, 8, 4, 4])
        XCTAssertNil(HostDatagrams.hostEndpoint(for: [10, 0, 2, 99], port: 53, resolver: resolver))
        XCTAssertNil(HostDatagrams.hostEndpoint(for: [255, 255, 255, 255], port: 67, resolver: resolver))
        XCTAssertNil(HostDatagrams.hostEndpoint(for: [224, 0, 0, 251], port: 5353, resolver: resolver))

        XCTAssertEqual(HostDatagrams.hostResolver("# x\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n"), [8, 8, 8, 8])
        XCTAssertEqual(HostDatagrams.hostResolver("nameserver\t192.168.1.1"), [192, 168, 1, 1])
        XCTAssertEqual(HostDatagrams.hostResolver("nameserver fe80::1\nnameserver 10.1.2.3"), [10, 1, 2, 3])
        // Le relais tourne sur l'hôte : le résolveur local de systemd lui répond.
        XCTAssertEqual(HostDatagrams.hostResolver("nameserver 127.0.0.53"), [127, 0, 0, 53])
        XCTAssertEqual(HostDatagrams.hostResolver("nameserver 1.2.3.4.5"), [1, 1, 1, 1])
        XCTAssertEqual(HostDatagrams.hostResolver("nameserver 1.2.3.x.4"), [1, 1, 1, 1], "quatre nombres, pas une adresse")
        XCTAssertEqual(HostDatagrams.hostResolver(nil), [1, 1, 1, 1])
    }

    /// **Par de vraies sockets** : un serveur d'écho UDP sur l'hôte, joint à
    /// `10.0.2.2`, répond, et la réponse revient sous `10.0.2.2`.
    func testARealDatagramMakesTheRoundTrip() throws {
        let server = socket(AF_INET, HostDatagrams.datagramType, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { _ = close(server) }
        var address = HostDatagrams.socketAddress([127, 0, 0, 1], port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(server, pointer, length) == 0 else { return -1 }
                return getsockname(server, pointer, &length)
            }
        }
        XCTAssertEqual(bound, 0)
        let port = UInt16(bigEndian: address.sin_port)
        let echo = Thread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(server, bytes.baseAddress, bytes.count, 0, $0, &peerLength)
                    }
                }
            }
            guard count > 0 else { return }
            let reply = Array("écho:".utf8) + buffer[0..<count]
            _ = reply.withUnsafeBytes { bytes in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(server, bytes.baseAddress, bytes.count, 0, $0, peerLength)
                    }
                }
            }
        }
        echo.start()

        let relay = HostDatagrams(resolver: [127, 0, 0, 1])
        defer { relay.close() }
        let network = UserNetwork(relay: relay)
        network.send(Self.udpFrame(to: UserNetwork.gateway, port: port, from: 5555, Array("wisq".utf8)))
        XCTAssertEqual(relay.openSockets, 1)
        var frames: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(5)
        while frames.isEmpty, Date() < deadline {
            frames = network.receive()
            if frames.isEmpty { usleep(5_000) }
        }
        let frame = try XCTUnwrap(frames.first, "aucune réponse en cinq secondes")
        let ip = Array(frame[14...])
        XCTAssertEqual(Array(ip[12..<16]), UserNetwork.gateway, "sous l'adresse que l'invité avait jointe")
        let udp = Array(ip[20...])
        XCTAssertEqual(UserNetwork.be16(udp, 0), port)
        XCTAssertEqual(UserNetwork.be16(udp, 2), 5555)
        XCTAssertEqual(Array(udp[8...]), Array("écho:wisq".utf8))
    }

    /// Un relais arrêté n'envoie plus rien et ne rend plus rien.
    func testAClosedRelayIsSilent() {
        let relay = HostDatagrams(resolver: [127, 0, 0, 1])
        relay.close()
        relay.send([1], to: UserNetwork.gateway, port: 9, fromGuestPort: 1)
        XCTAssertEqual(relay.openSockets, 0, "aucune socket rouverte")
        XCTAssertTrue(relay.receive().isEmpty)
    }
}
