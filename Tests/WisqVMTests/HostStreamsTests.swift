import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import WisqVM

/// Le TCP de l'invité porté par l'hôte : voir `HostStreams`, et
/// `UserNetwork.inboundSegment` / `UserNetwork.frame(for:to:)`.
///
/// Les tests jouent l'invité segment par segment, contre de vrais serveurs
/// sur la boucle locale, joints par `10.0.2.2`.
final class HostStreamsTests: XCTestCase {
    typealias Flag = HostStreams.Flag

    /// Un serveur TCP sur `127.0.0.1`, qui fait `serve` de la première
    /// connexion puis la ferme.
    final class Server {
        let descriptor: Int32
        let port: UInt16
        private let thread: Thread

        init(_ serve: @escaping @Sendable (Int32) -> Void) throws {
            let listener = socket(AF_INET, HostStreams.streamType, 0)
            guard listener >= 0 else { throw POSIXError(.EMFILE) }
            var one: Int32 = 1
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = HostDatagrams.socketAddress([127, 0, 0, 1], port: 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                    guard bind(listener, pointer, length) == 0, startListening(listener) == 0 else { return -1 }
                    return getsockname(listener, pointer, &length)
                }
            }
            guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
            descriptor = listener
            port = UInt16(bigEndian: address.sin_port)
            thread = Thread {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                serve(client)
                _ = closeSocket(client)
            }
            thread.start()
        }

        deinit { _ = closeSocket(descriptor) }

        static func readAll(_ client: Int32, until count: Int) -> [UInt8] {
            var got: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while got.count < count {
                let read = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                guard read > 0 else { break }
                got += buffer[0..<read]
            }
            return got
        }

        static func write(_ client: Int32, _ bytes: [UInt8]) {
            var sent = 0
            while sent < bytes.count {
                let wrote = bytes[sent...].withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                guard wrote > 0 else { return }
                sent += wrote
            }
        }
    }

    /// L'invité, côté segments.
    final class Guest {
        let streams: HostStreams
        let port: UInt16
        let remotePort: UInt16
        var next: UInt32 = 1000
        var acknowledged: UInt32 = 0
        var window: UInt16 = 65_535
        var received: [UInt8] = []

        init(_ streams: HostStreams, to remotePort: UInt16, from port: UInt16 = 40_001) {
            self.streams = streams
            self.remotePort = remotePort
            self.port = port
        }

        func segment(_ flags: UInt8, _ payload: [UInt8] = [], sequence: UInt32? = nil,
                     maximumSegment: UInt16? = nil) -> HostStreams.Segment {
            HostStreams.Segment(remote: UserNetwork.gateway, remotePort: remotePort, guestPort: port,
                                sequence: sequence ?? next, acknowledgment: acknowledged, flags: flags,
                                window: window, maximumSegment: maximumSegment, payload: payload)
        }

        func send(_ flags: UInt8, _ payload: [UInt8] = []) {
            streams.handle(segment(flags, payload))
            next &+= UInt32(payload.count) + (flags & (Flag.syn | Flag.fin) != 0 ? 1 : 0)
        }

        /// Les segments rendus, jusqu'à ce que `until` soit vrai ou cinq secondes.
        func wait(until done: ([HostStreams.Segment]) -> Bool) -> [HostStreams.Segment] {
            var all: [HostStreams.Segment] = []
            let deadline = Date().addingTimeInterval(5)
            while !done(all), Date() < deadline {
                let got = streams.receive()
                if got.isEmpty { usleep(2_000) } else { all += got }
            }
            return all
        }

        /// Ouvre la connexion : SYN, SYN-ACK, ACK.
        func connect() throws -> HostStreams.Segment {
            streams.handle(segment(Flag.syn, maximumSegment: 1460))
            next &+= 1
            let replies = wait { $0.contains { $0.flags & Flag.syn != 0 } }
            let synAck = try XCTUnwrap(replies.first { $0.flags & Flag.syn != 0 }, "pas de SYN-ACK")
            acknowledged = synAck.sequence &+ 1
            send(Flag.ack)
            return synAck
        }

        /// Prend les données dans l'ordre, et les accuse.
        func take(_ segments: [HostStreams.Segment]) {
            for segment in segments where segment.sequence == acknowledged {
                received += segment.payload
                acknowledged &+= UInt32(segment.payload.count) + (segment.flags & Flag.fin != 0 ? 1 : 0)
            }
            send(Flag.ack)
        }
    }

    /// **Un échange complet** : poignée de main, données dans les deux sens,
    /// fermeture des deux côtés, et la connexion qui disparaît.
    func testAConversationFromHandshakeToClose() throws {
        let server = try Server { client in
            let question = Server.readAll(client, until: 7)
            Server.write(client, Array(String(decoding: question, as: UTF8.self).uppercased().utf8))
        }
        let streams = HostStreams()
        defer { streams.close() }
        let guest = Guest(streams, to: server.port)
        let synAck = try guest.connect()
        XCTAssertEqual(synAck.flags, Flag.syn | Flag.ack)
        XCTAssertEqual(synAck.acknowledgment, 1001, "le SYN de l'invité compte pour un")
        XCTAssertEqual(synAck.maximumSegment, HostStreams.segmentSize)
        XCTAssertEqual(synAck.remote, UserNetwork.gateway)
        XCTAssertEqual(synAck.remotePort, server.port)

        guest.send(Flag.ack | Flag.psh, Array("bonjour".utf8))
        var segments = guest.wait { all in all.contains { $0.flags & Flag.fin != 0 } }
        XCTAssertTrue(segments.contains { $0.payload.isEmpty && $0.acknowledgment == 1008 }, "les données sont accusées")
        guest.take(segments)
        XCTAssertEqual(guest.received, Array("BONJOUR".utf8))
        XCTAssertEqual(streams.openConnections, 1, "l'invité n'a pas encore fermé")

        guest.send(Flag.fin | Flag.ack)
        segments = guest.wait { all in all.contains { $0.acknowledgment == guest.next } }
        XCTAssertTrue(segments.contains { $0.acknowledgment == guest.next }, "la fin de l'invité est accusée")
        XCTAssertEqual(streams.openConnections, 0)
    }

    /// **La fenêtre de l'invité est tenue** : jamais plus en vol que ce qu'il
    /// a annoncé, et tout arrive, dans l'ordre, intact.
    func testTheGuestWindowIsRespected() throws {
        let size = 200_000
        let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) }
        let server = try Server { client in Server.write(client, data) }
        let streams = HostStreams()
        defer { streams.close() }
        let guest = Guest(streams, to: server.port)
        guest.window = 4000
        _ = try guest.connect()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let segments = guest.wait { !$0.isEmpty }
            let ahead = segments.map { Int(Int32(bitPattern: $0.sequence &- guest.acknowledged)) + $0.payload.count }
            XCTAssertLessThanOrEqual(ahead.max() ?? 0, 4000, "au-delà de la fenêtre")
            XCTAssertTrue(segments.allSatisfy { $0.payload.count <= 1460 })
            guest.take(segments)
            if guest.received.count == size, segments.contains(where: { $0.flags & Flag.fin != 0 }) { break }
        }
        XCTAssertEqual(guest.received.count, size)
        XCTAssertTrue(guest.received == data, "intact et dans l'ordre")
    }

    /// **Ce qui n'est pas accusé est réémis**, à la même place.
    func testWhatIsNotAcknowledgedIsSentAgain() throws {
        let server = try Server { client in
            Server.write(client, Array("une fois".utf8))
            _ = Server.readAll(client, until: 1)
        }
        let streams = HostStreams()
        defer { streams.close() }
        let guest = Guest(streams, to: server.port)
        _ = try guest.connect()
        let first = guest.wait { $0.contains { !$0.payload.isEmpty } }.first { !$0.payload.isEmpty }
        let lost = try XCTUnwrap(first)
        // L'invité ne l'accuse pas : comme si la carte l'avait jeté.
        let again = guest.wait { $0.contains { !$0.payload.isEmpty } }.first { !$0.payload.isEmpty }
        XCTAssertEqual(again?.sequence, lost.sequence)
        XCTAssertEqual(again?.payload, lost.payload)
    }

    /// **Données en avance** : laissées, et l'invité apprend ce qu'on attend.
    /// Une réémission en partie déjà reçue ne livre que le neuf.
    func testOutOfOrderAndOverlappingData() throws {
        let server = try Server { client in
            let got = Server.readAll(client, until: 6)
            Server.write(client, got)
        }
        let streams = HostStreams()
        defer { streams.close() }
        let guest = Guest(streams, to: server.port)
        _ = try guest.connect()
        streams.handle(guest.segment(Flag.ack, Array("zz".utf8), sequence: guest.next &+ 10))
        let duplicate = guest.wait { !$0.isEmpty }
        XCTAssertEqual(duplicate.first?.acknowledgment, guest.next, "on attend toujours le même octet")
        guest.send(Flag.ack, Array("abc".utf8))
        // « bcdef » repart depuis b : seul « def » est neuf.
        streams.handle(guest.segment(Flag.ack, Array("bcdef".utf8), sequence: guest.next &- 2))
        guest.next &+= 3
        let echoed = guest.wait { all in all.reduce(0) { $0 + $1.payload.count } >= 6 }
        guest.take(echoed)
        XCTAssertEqual(guest.received, Array("abcdef".utf8))
    }

    /// **Un port fermé est un refus** : l'invité reçoit une remise à zéro qui
    /// accuse son SYN, et rien ne reste ouvert.
    func testARefusedConnectionIsReset() throws {
        let server = try Server { _ in }
        let port = server.port
        _ = closeSocket(server.descriptor)
        let streams = HostStreams()
        defer { streams.close() }
        streams.handle(HostStreams.Segment(remote: UserNetwork.gateway, remotePort: port, guestPort: 40_002,
                                           sequence: 77, acknowledgment: 0, flags: Flag.syn, window: 1000,
                                           maximumSegment: nil, payload: []))
        let guest = Guest(streams, to: port, from: 40_002)
        let replies = guest.wait { !$0.isEmpty }
        XCTAssertEqual(replies.first?.flags, Flag.rst | Flag.ack)
        XCTAssertEqual(replies.first?.acknowledgment, 78)
        XCTAssertEqual(streams.openConnections, 0)
    }

    /// **Un segment sans connexion** reçoit une remise à zéro à sa place ;
    /// une remise à zéro sans connexion, rien.
    func testASegmentWithoutAConnection() {
        let streams = HostStreams()
        defer { streams.close() }
        streams.handle(HostStreams.Segment(remote: [93, 184, 215, 14], remotePort: 80, guestPort: 40_003,
                                           sequence: 5, acknowledgment: 1234, flags: Flag.ack, window: 1000,
                                           maximumSegment: nil, payload: [1, 2]))
        XCTAssertEqual(streams.receive().first, HostStreams.Segment(
            remote: [93, 184, 215, 14], remotePort: 80, guestPort: 40_003, sequence: 1234, acknowledgment: 0,
            flags: Flag.rst, window: 0, maximumSegment: nil, payload: []))
        streams.handle(HostStreams.Segment(remote: [93, 184, 215, 14], remotePort: 80, guestPort: 40_003,
                                           sequence: 5, acknowledgment: 0, flags: Flag.rst, window: 0,
                                           maximumSegment: nil, payload: []))
        XCTAssertTrue(streams.receive().isEmpty)
        // Vers une adresse du petit réseau qui n'existe pas : refusé tout de suite.
        streams.handle(HostStreams.Segment(remote: [10, 0, 2, 77], remotePort: 80, guestPort: 40_004,
                                           sequence: 9, acknowledgment: 0, flags: Flag.syn, window: 1000,
                                           maximumSegment: nil, payload: []))
        XCTAssertEqual(streams.receive().first?.flags, Flag.rst | Flag.ack)
        XCTAssertEqual(streams.openConnections, 0)
    }

    /// **La remise à zéro de l'invité** ferme la connexion de l'hôte.
    func testTheGuestResetClosesTheHostConnection() throws {
        let server = try Server { client in
            var byte: UInt8 = 0
            // Le serveur voit la fin de la connexion : zéro ou une erreur.
            XCTAssertLessThanOrEqual(recv(client, &byte, 1, 0), 0)
        }
        let streams = HostStreams()
        defer { streams.close() }
        let guest = Guest(streams, to: server.port)
        _ = try guest.connect()
        XCTAssertEqual(streams.openConnections, 1)
        guest.send(Flag.rst)
        XCTAssertEqual(streams.openConnections, 0)
    }

    /// **Par les trames** : un SYN posé sur le câble ressort en SYN-ACK de
    /// `10.0.2.2`, sommes justes, avec sa taille de segment.
    func testThroughTheFrames() throws {
        let server = try Server { _ in }
        let streams = HostStreams()
        defer { streams.close() }
        let network = UserNetwork(streams: streams)
        let syn = HostStreams.Segment(remote: UserNetwork.gateway, remotePort: server.port, guestPort: 40_005,
                                      sequence: 500, acknowledgment: 0, flags: Flag.syn, window: 29_200,
                                      maximumSegment: 1460, payload: [])
        let parsedOwn = try XCTUnwrap(UserNetwork.inboundSegment(Self.fromGuest(syn)))
        XCTAssertEqual(parsedOwn, syn, "lu tel qu'écrit")
        network.send(Self.fromGuest(syn))
        var frames: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(5)
        while frames.isEmpty, Date() < deadline {
            frames = network.receive()
            if frames.isEmpty { usleep(2_000) }
        }
        let reply = try XCTUnwrap(frames.first)
        XCTAssertEqual(Array(reply[0..<6]), UserNetworkUDPTests.guestMAC)
        let ip = Array(reply[14...])
        XCTAssertEqual(UserNetwork.checksum(Array(ip[0..<20])), 0)
        XCTAssertEqual(Array(ip[12..<16]), UserNetwork.gateway)
        let tcp = Array(ip[20...])
        let pseudo = Array(ip[12..<20]) + [0, 6] + UserNetwork.be16Bytes(UInt16(tcp.count))
        XCTAssertEqual(UserNetwork.checksum(pseudo + tcp), 0)
        XCTAssertEqual(tcp[13], Flag.syn | Flag.ack)
        XCTAssertEqual(UserNetwork.be32(tcp, 8), 501)
        XCTAssertEqual(Array(tcp[20..<24]), [2, 4, 0x05, 0xB4], "MSS 1460")
    }

    /// Une trame abîmée n'atteint pas la pile.
    func testABrokenSegmentIsIgnored() {
        let syn = HostStreams.Segment(remote: UserNetwork.gateway, remotePort: 80, guestPort: 40_006,
                                      sequence: 1, acknowledgment: 0, flags: Flag.syn, window: 100,
                                      maximumSegment: nil, payload: [1, 2, 3])
        var frame = Self.fromGuest(syn)
        XCTAssertNotNil(UserNetwork.inboundSegment(frame))
        frame[frame.count - 1] ^= 0xFF
        XCTAssertNil(UserNetwork.inboundSegment(frame), "somme TCP fausse")
    }

    /// La trame que l'invité enverrait pour `segment`.
    static func fromGuest(_ segment: HostStreams.Segment) -> [UInt8] {
        let options: [UInt8] = segment.maximumSegment.map { [2, 4] + UserNetwork.be16Bytes($0) } ?? []
        var tcp = UserNetwork.be16Bytes(segment.guestPort) + UserNetwork.be16Bytes(segment.remotePort)
            + UserNetwork.be32Bytes(segment.sequence) + UserNetwork.be32Bytes(segment.acknowledgment)
            + [UInt8((20 + options.count) / 4) << 4, segment.flags] + UserNetwork.be16Bytes(segment.window)
            + [0, 0, 0, 0] + options + segment.payload
        let pseudo = UserNetwork.guest + segment.remote + [0, 6] + UserNetwork.be16Bytes(UInt16(tcp.count))
        let sum = UserNetwork.checksum(pseudo + tcp)
        tcp[16] = UInt8(sum >> 8)
        tcp[17] = UInt8(sum & 0xFF)
        let ip = UserNetwork.ipv4Packet(from: UserNetwork.guest, to: segment.remote, protocol: 6, tcp)
        return UserNetwork.routerMAC + UserNetworkUDPTests.guestMAC + [0x08, 0x00] + ip
    }
}

private func startListening(_ descriptor: Int32) -> Int32 { listen(descriptor, 4) }
