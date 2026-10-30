import Foundation

/// **Un réseau en mode utilisateur**, à la manière de « slirp » chez QEMU : la
/// machine se croit sur un petit réseau local, et c'est wisq qui y joue la
/// passerelle, le serveur DHCP et — dans les tranches suivantes — le serveur
/// de noms et la sortie vers l'extérieur.
///
/// **Les adresses sont celles de QEMU**, parce que des années de
/// documentation, de scripts et d'habitudes les supposent : l'invité est
/// `10.0.2.15/24`, la passerelle `10.0.2.2`, le serveur de noms `10.0.2.3`.
///
/// **Ce qu'il fait** : répondre aux demandes ARP pour la passerelle et le
/// serveur de noms, servir un bail DHCP, répondre aux échos ICMP adressés à
/// la passerelle, et confier l'UDP — le DNS d'abord — à un `DatagramRelay`
/// qui le porte au-dehors. Le reste est ignoré sans bruit, comme un réseau où
/// personne n'écoute.
public final class UserNetwork: NetworkBackend, @unchecked Sendable {
    public static let guest: [UInt8] = [10, 0, 2, 15]
    public static let gateway: [UInt8] = [10, 0, 2, 2]
    public static let nameServer: [UInt8] = [10, 0, 2, 3]
    public static let netmask: [UInt8] = [255, 255, 255, 0]
    /// L'adresse matérielle de la passerelle : locale, individuelle, et pas
    /// celle de la carte.
    public static let routerMAC: [UInt8] = [0x02, 0x77, 0x69, 0x73, 0x71, 0x02]
    /// Un jour : assez pour qu'aucun client ne renouvelle pendant une
    /// session, et le renouvellement est servi de toute façon.
    public static let leaseSeconds: UInt32 = 86_400

    /// Un datagramme UDP pour l'invité, sous l'adresse qu'il attend.
    public struct Datagram: Equatable, Sendable {
        public let source: [UInt8]
        public let sourcePort: UInt16
        public let guestPort: UInt16
        public let payload: [UInt8]

        public init(source: [UInt8], sourcePort: UInt16, guestPort: UInt16, payload: [UInt8]) {
            self.source = source
            self.sourcePort = sourcePort
            self.guestPort = guestPort
            self.payload = payload
        }
    }

    private let lock = NSLock()
    private var outgoing: [[UInt8]] = []
    /// L'adresse matérielle de l'invité, apprise de ses trames : c'est à elle
    /// que vont les réponses du dehors.
    private var guestMAC: [UInt8] = VirtioNet.defaultMAC
    private var identification: UInt16 = 0
    public let relay: DatagramRelay?
    public let streams: HostStreams?
    public let echoes: HostEchoes?

    /// Sans `relay`, l'UDP vers le dehors se perd ; sans `streams`, le TCP ;
    /// sans `echoes`, le ping — comme sur un réseau isolé.
    public init(relay: DatagramRelay? = nil, streams: HostStreams? = nil, echoes: HostEchoes? = nil) {
        self.relay = relay
        self.streams = streams
        self.echoes = echoes
    }

    /// Le réseau complet : l'UDP et le TCP de l'invité sortent par l'hôte.
    public static func throughHost() -> UserNetwork {
        // Le ping, si le système ouvre la socket ICMP sans privilège.
        UserNetwork(relay: HostDatagrams(), streams: HostStreams(), echoes: HostEchoes.make())
    }

    /// **Le réseau coupé** (`MachineNetwork`) : la passerelle répond encore
    /// — ARP, bail, ping de `10.0.2.2` —, mais rien ne sort. Le TCP reste
    /// pour les ports relayés vers l'invité, et lui seul : ce que l'invité
    /// ouvre vers le dehors est refusé tout de suite, sans attendre.
    public static func isolated() -> UserNetwork {
        UserNetwork(streams: HostStreams(reachesOutside: false))
    }

    public func send(_ frame: [UInt8]) {
        guard frame.count >= 14 else { return }
        let replies = Self.answer(frame)
        lock.lock()
        guestMAC = Array(frame[6..<12])
        outgoing += replies
        lock.unlock()
        guard replies.isEmpty else { return }
        if let relay, let datagram = Self.outboundDatagram(frame) {
            relay.send(datagram.payload, to: datagram.destination, port: datagram.destinationPort,
                       fromGuestPort: datagram.sourcePort)
        } else if let streams, let segment = Self.inboundSegment(frame) {
            streams.handle(segment)
        } else if let echoes, let echo = Self.outboundEcho(frame),
                  let host = HostDatagrams.hostEndpoint(for: echo.destination, port: 0, resolver: [0, 0, 0, 0]) {
            echoes.send(echo.message, to: host)
        }
    }

    public func receive() -> [[UInt8]] {
        let arrived = relay?.receive() ?? []
        let segments = streams?.receive() ?? []
        let echoed = echoes?.receive() ?? []
        lock.lock()
        defer { lock.unlock() }
        for datagram in arrived {
            identification &+= 1
            outgoing += Self.frames(for: datagram, to: guestMAC, identification: identification)
        }
        for segment in segments {
            outgoing.append(Self.frame(for: segment, to: guestMAC))
        }
        for reply in echoed {
            outgoing.append(Self.ethernet(to: guestMAC, type: Self.ipv4Type,
                                     Self.ipv4Packet(from: reply.source, to: Self.guest, protocol: 1, reply.message)))
        }
        guard !outgoing.isEmpty else { return [] }
        let taken = outgoing
        outgoing.removeAll()
        return taken
    }

    // MARK: - L'UDP du dehors

    /// Un datagramme que l'invité envoie au-delà de la passerelle.
    struct Outbound: Equatable {
        let destination: [UInt8]
        let sourcePort: UInt16
        let destinationPort: UInt16
        let payload: [UInt8]
    }

    /// Le datagramme UDP que porte `frame`, s'il en porte un entier. Un
    /// fragment est laissé de côté : un client DNS n'en envoie pas.
    static func outboundDatagram(_ frame: [UInt8]) -> Outbound? {
        guard frame.count >= 34, be16(frame, 12) == ipv4Type else { return nil }
        let packet = Array(frame[14...])
        guard packet[0] >> 4 == 4, packet[9] == 17 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let total = Int(be16(packet, 2))
        guard headerLength >= 20, total >= headerLength + 8, total <= packet.count,
              checksum(Array(packet[0..<headerLength])) == 0,
              be16(packet, 6) & 0x3FFF == 0 else { return nil }
        let udp = Array(packet[headerLength..<total])
        let length = Int(be16(udp, 4))
        guard length >= 8, length <= udp.count else { return nil }
        return Outbound(destination: Array(packet[16..<20]), sourcePort: be16(udp, 0),
                        destinationPort: be16(udp, 2), payload: Array(udp[8..<length]))
    }

    // MARK: - Le ping du dehors

    /// L'écho que porte `frame`, s'il en porte un entier et juste : sa
    /// destination et le message ICMP.
    static func outboundEcho(_ frame: [UInt8]) -> (destination: [UInt8], message: [UInt8])? {
        guard frame.count >= 42, be16(frame, 12) == ipv4Type else { return nil }
        let packet = Array(frame[14...])
        guard packet[0] >> 4 == 4, packet[9] == 1 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let total = Int(be16(packet, 2))
        guard headerLength >= 20, total >= headerLength + 8, total <= packet.count,
              checksum(Array(packet[0..<headerLength])) == 0,
              be16(packet, 6) & 0x3FFF == 0 else { return nil }
        let message = Array(packet[headerLength..<total])
        guard message[0] == 8, message[1] == 0, checksum(message) == 0 else { return nil }
        return (Array(packet[16..<20]), message)
    }

    // MARK: - Le TCP

    /// Le segment TCP que porte `frame`, sous les adresses de l'invité.
    static func inboundSegment(_ frame: [UInt8]) -> HostStreams.Segment? {
        guard frame.count >= 54, be16(frame, 12) == ipv4Type else { return nil }
        let packet = Array(frame[14...])
        guard packet[0] >> 4 == 4, packet[9] == 6 else { return nil }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let total = Int(be16(packet, 2))
        guard headerLength >= 20, total >= headerLength + 20, total <= packet.count,
              checksum(Array(packet[0..<headerLength])) == 0,
              be16(packet, 6) & 0x3FFF == 0 else { return nil }
        let tcp = Array(packet[headerLength..<total])
        let pseudo = Array(packet[12..<20]) + [0, 6] + be16Bytes(UInt16(tcp.count))
        guard checksum(pseudo + tcp) == 0 else { return nil }
        let offset = Int(tcp[12] >> 4) * 4
        guard offset >= 20, offset <= tcp.count else { return nil }
        var maximumSegment: UInt16?
        var at = 20
        while at < offset {
            let kind = tcp[at]
            if kind == 0 { break }
            if kind == 1 { at += 1; continue }
            guard at + 1 < offset, tcp[at + 1] >= 2, at + Int(tcp[at + 1]) <= offset else { break }
            if kind == 2, tcp[at + 1] == 4 { maximumSegment = be16(tcp, at + 2) }
            at += Int(tcp[at + 1])
        }
        return HostStreams.Segment(remote: Array(packet[16..<20]), remotePort: be16(tcp, 2),
                                   guestPort: be16(tcp, 0), sequence: be32(tcp, 4),
                                   acknowledgment: be32(tcp, 8), flags: tcp[13] & 0x3F,
                                   window: be16(tcp, 14), maximumSegment: maximumSegment,
                                   payload: Array(tcp[offset...]))
    }

    /// La trame qui porte `segment` à l'invité.
    static func frame(for segment: HostStreams.Segment, to mac: [UInt8]) -> [UInt8] {
        let options: [UInt8] = segment.maximumSegment.map { [2, 4] + be16Bytes($0) } ?? []
        var tcp = be16Bytes(segment.remotePort) + be16Bytes(segment.guestPort)
            + be32Bytes(segment.sequence) + be32Bytes(segment.acknowledgment)
            + [UInt8((20 + options.count) / 4) << 4, segment.flags] + be16Bytes(segment.window)
            + [0, 0, 0, 0] + options + segment.payload
        let pseudo = segment.remote + guest + [0, 6] + be16Bytes(UInt16(tcp.count))
        let sum = checksum(pseudo + tcp)
        tcp[16] = UInt8(sum >> 8)
        tcp[17] = UInt8(sum & 0xFF)
        return ethernet(to: mac, type: ipv4Type, ipv4Packet(from: segment.remote, to: guest, protocol: 6, tcp))
    }

    /// La charge la plus grande d'un fragment : une trame de 1514 octets, moins
    /// les en-têtes Ethernet et IPv4, arrondie au multiple de huit.
    static let fragmentPayload = 1480

    /// Les trames qui portent `datagram` à l'invité, fragmentées s'il dépasse
    /// une trame — une réponse DNS avec EDNS le peut.
    static func frames(for datagram: Datagram, to mac: [UInt8], identification: UInt16) -> [[UInt8]] {
        let udp = udpDatagram(sourcePort: datagram.sourcePort, destinationPort: datagram.guestPort,
                              datagram.payload, from: datagram.source, to: guest)
        guard udp.count > fragmentPayload else {
            return [ethernet(to: mac, type: ipv4Type, ipv4Packet(from: datagram.source, to: guest, protocol: 17, udp))]
        }
        var frames: [[UInt8]] = []
        var offset = 0
        while offset < udp.count {
            let end = min(offset + fragmentPayload, udp.count)
            let more = end < udp.count
            let field = UInt16(offset / 8) | (more ? 0x2000 : 0)
            frames.append(ethernet(to: mac, type: ipv4Type,
                                   ipv4Packet(from: datagram.source, to: guest, protocol: 17,
                                              Array(udp[offset..<end]), identification: identification,
                                              fragment: field)))
            offset = end
        }
        return frames
    }

    // MARK: - Ce qu'on répond

    static let arpType: UInt16 = 0x0806
    static let ipv4Type: UInt16 = 0x0800
    static let broadcastMAC: [UInt8] = [UInt8](repeating: 0xFF, count: 6)

    /// Les trames à rendre pour une trame reçue de l'invité, peut-être aucune.
    static func answer(_ frame: [UInt8]) -> [[UInt8]] {
        guard frame.count >= 14 else { return [] }
        let source = Array(frame[6..<12])
        let payload = Array(frame[14...])
        switch be16(frame, 12) {
        case arpType: return arp(payload).map { [ethernet(to: source, type: arpType, $0)] } ?? []
        case ipv4Type: return ipv4(payload, from: source)
        default: return []
        }
    }

    /// **ARP** : une demande pour la passerelle ou le serveur de noms reçoit
    /// l'adresse matérielle de la passerelle — c'est elle qui porte les deux.
    static func arp(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 28, be16(packet, 0) == 1, be16(packet, 2) == ipv4Type,
              packet[4] == 6, packet[5] == 4, be16(packet, 6) == 1 else { return nil }
        let senderMAC = Array(packet[8..<14])
        let senderIP = Array(packet[14..<18])
        let targetIP = Array(packet[24..<28])
        guard targetIP == gateway || targetIP == nameServer else { return nil }
        var reply: [UInt8] = [0, 1, 0x08, 0x00, 6, 4, 0, 2]
        reply += routerMAC + targetIP + senderMAC + senderIP
        return reply
    }

    static func ipv4(_ packet: [UInt8], from source: [UInt8]) -> [[UInt8]] {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return [] }
        let headerLength = Int(packet[0] & 0x0F) * 4
        let total = Int(be16(packet, 2))
        guard headerLength >= 20, total >= headerLength, total <= packet.count,
              checksum(Array(packet[0..<headerLength])) == 0 else { return [] }
        let sourceIP = Array(packet[12..<16])
        let destination = Array(packet[16..<20])
        let body = Array(packet[headerLength..<total])
        switch packet[9] {
        case 1:  // ICMP
            // La passerelle et le serveur de noms répondent d'ici ; le reste
            // part par `HostEchoes`, s'il y en a.
            guard destination == gateway || destination == nameServer, let reply = echoReply(body) else { return [] }
            return [ethernet(to: source, type: ipv4Type,
                             ipv4Packet(from: destination, to: sourceIP, protocol: 1, reply))]
        case 17:  // UDP
            guard body.count >= 8 else { return [] }
            let destinationPort = be16(body, 2)
            let length = Int(be16(body, 4))
            guard length >= 8, length <= body.count else { return [] }
            if destinationPort == 67, let reply = dhcp(Array(body[8..<length])) {
                // Au client, qui n'a pas encore d'adresse : en diffusion.
                let udp = udpDatagram(sourcePort: 67, destinationPort: 68, reply,
                                      from: gateway, to: [255, 255, 255, 255])
                return [ethernet(to: broadcastMAC, type: ipv4Type,
                                 ipv4Packet(from: gateway, to: [255, 255, 255, 255], protocol: 17, udp))]
            }
            // L'heure, servie par la passerelle elle-même : voir `ntp`.
            if destination == gateway, destinationPort == ntpPort, let reply = ntp(Array(body[8..<length]), now: Date()) {
                let udp = udpDatagram(sourcePort: ntpPort, destinationPort: be16(body, 0), reply,
                                      from: gateway, to: sourceIP)
                return [ethernet(to: source, type: ipv4Type,
                                 ipv4Packet(from: gateway, to: sourceIP, protocol: 17, udp))]
            }
            return []
        default:
            return []
        }
    }

    /// **L'écho** : le même identifiant, la même séquence, les mêmes données.
    static func echoReply(_ message: [UInt8]) -> [UInt8]? {
        guard message.count >= 8, message[0] == 8, message[1] == 0, checksum(message) == 0 else { return nil }
        var reply = message
        reply[0] = 0
        reply[2] = 0
        reply[3] = 0
        let sum = checksum(reply)
        reply[2] = UInt8(sum >> 8)
        reply[3] = UInt8(sum & 0xFF)
        return reply
    }

    // MARK: - DHCP

    static let dhcpMagic: [UInt8] = [99, 130, 83, 99]

    /// **Le bail** : une offre à la découverte, un accord à la demande, et
    /// toujours la même adresse — il n'y a qu'un invité sur ce réseau.
    static func dhcp(_ message: [UInt8]) -> [UInt8]? {
        guard message.count >= 240, message[0] == 1, message[1] == 1, message[2] == 6,
              Array(message[236..<240]) == dhcpMagic else { return nil }
        var kind: UInt8?
        var at = 240
        while at < message.count {
            let code = message[at]
            if code == 255 { break }
            if code == 0 { at += 1; continue }
            guard at + 1 < message.count else { break }
            let length = Int(message[at + 1])
            guard at + 2 + length <= message.count else { break }
            if code == 53, length == 1 { kind = message[at + 2] }
            at += 2 + length
        }
        let answer: UInt8
        switch kind {
        case 1: answer = 2  // DISCOVER → OFFER
        case 3: answer = 5  // REQUEST → ACK
        default: return nil
        }
        var reply = [UInt8](repeating: 0, count: 240)
        reply[0] = 2
        reply[1] = 1
        reply[2] = 6
        reply.replaceSubrange(4..<8, with: message[4..<8])      // xid
        reply.replaceSubrange(10..<12, with: message[10..<12])  // drapeaux
        reply.replaceSubrange(16..<20, with: guest)             // yiaddr
        reply.replaceSubrange(20..<24, with: gateway)           // siaddr
        reply.replaceSubrange(28..<44, with: message[28..<44])  // chaddr
        reply.replaceSubrange(236..<240, with: dhcpMagic)
        reply += [53, 1, answer]
        reply += [54, 4] + gateway
        reply += [51, 4] + be32Bytes(leaseSeconds)
        reply += [1, 4] + netmask
        reply += [3, 4] + gateway
        reply += [6, 4] + nameServer
        // Le serveur de temps : la passerelle. `systemd-networkd` le passe
        // à `timesyncd`.
        reply += [42, 4] + gateway
        reply += [255]
        return reply
    }

    // MARK: - L'heure

    static let ntpPort: UInt16 = 123
    /// Des secondes de 1900 à 1970 : l'époque de NTP n'est pas celle d'Unix.
    static let ntpEpochOffset: TimeInterval = 2_208_988_800

    /// **L'heure du téléphone, servie par la passerelle** (SNTP, RFC 4330).
    ///
    /// Le temps de l'invité avance au rythme de l'interprète : un invité
    /// chargé prend du retard. Son client NTP le rattrape, à condition de
    /// joindre un serveur. Celui-ci est toujours là, sans réseau dehors,
    /// réseau coupé compris (`UserNetwork.isolated()`), et le bail l'annonce
    /// (option 42).
    ///
    /// Strate un, référence « WISQ » : l'horloge de l'hôte est la référence
    /// de ce petit réseau. Seule une demande de client (mode trois) reçoit
    /// une réponse ; elle reprend sa version, son intervalle et son heure
    /// d'envoi, comme le client l'attend.
    static func ntp(_ request: [UInt8], now: Date) -> [UInt8]? {
        guard request.count >= 48, request[0] & 0x07 == 3 else { return nil }
        let version = (request[0] >> 3) & 0x07
        let stamp = ntpTimestamp(now)
        var reply: [UInt8] = [version << 3 | 4, 1, request[2], 0xEC]
        reply += [0, 0, 0, 0]               // délai jusqu'à la racine
        reply += [0, 0, 0, 0x10]            // dispersion : un quart de milliseconde
        reply += Array("WISQ".utf8)         // référence
        reply += stamp                      // dernière mise à l'heure
        reply += Array(request[40..<48])    // l'envoi du client, rendu tel quel
        reply += stamp                      // réception
        reply += stamp                      // envoi
        return reply
    }

    /// Une date en horodatage NTP : secondes depuis 1900, puis la fraction
    /// en deux cent trente-deuxièmes.
    static func ntpTimestamp(_ date: Date) -> [UInt8] {
        let since1900 = date.timeIntervalSince1970 + ntpEpochOffset
        let seconds = since1900.rounded(.down)
        let fraction = UInt32(min((since1900 - seconds) * 4_294_967_296, 4_294_967_295))
        return be32Bytes(UInt32(truncatingIfNeeded: Int64(seconds))) + be32Bytes(fraction)
    }

    // MARK: - Les trames

    static func ethernet(to destination: [UInt8], type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        destination + routerMAC + be16Bytes(type) + payload
    }

    /// Sans `fragment`, le paquet est entier et ne doit pas être fragmenté.
    static func ipv4Packet(from source: [UInt8], to destination: [UInt8], protocol number: UInt8,
                           _ payload: [UInt8], identification: UInt16 = 0, fragment: UInt16 = 0x4000) -> [UInt8] {
        var header: [UInt8] = [0x45, 0] + be16Bytes(UInt16(20 + payload.count)) + be16Bytes(identification)
            + be16Bytes(fragment) + [64, number, 0, 0]
        header += source + destination
        let sum = checksum(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xFF)
        return header + payload
    }

    static func udpDatagram(sourcePort: UInt16, destinationPort: UInt16, _ payload: [UInt8],
                            from source: [UInt8], to destination: [UInt8]) -> [UInt8] {
        let length = UInt16(8 + payload.count)
        var datagram = be16Bytes(sourcePort) + be16Bytes(destinationPort) + be16Bytes(length) + [0, 0] + payload
        let pseudo = source + destination + [0, 17] + be16Bytes(length)
        var sum = checksum(pseudo + datagram)
        // Un total nul s'écrit tout à un : zéro veut dire « pas de somme ».
        if sum == 0 { sum = 0xFFFF }
        datagram[6] = UInt8(sum >> 8)
        datagram[7] = UInt8(sum & 0xFF)
        return datagram
    }

    /// La somme de contrôle d'Internet : le complément à un de la somme en
    /// complément à un des mots de seize bits. Nulle sur un en-tête juste.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    static func be16Bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
