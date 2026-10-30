import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// **Le TCP de l'invité, porté par l'hôte** : chaque connexion que l'invité
/// ouvre devient une connexion de l'hôte, et wisq joue le pair TCP en face de
/// lui — comme slirp.
///
/// **Ce qu'on garde simple, et pourquoi c'est permis.** Le lien entre wisq et
/// l'invité ne perd rien : une trame posée dans la file de la carte arrive.
/// Pas de contrôle de congestion, donc, ni d'accusés retardés ; un
/// réémission « tout depuis le dernier accusé » après une seconde de silence
/// suffit pour les rares trames que la carte jetterait faute de tampons. On
/// n'annonce ni l'échelle de fenêtre, ni les horodatages, ni SACK : l'invité
/// s'en passe, et la fenêtre de l'invité se lit alors telle quelle.
///
/// **Le travail se partage en deux.** Ce que l'invité envoie est traité sur
/// le fil de l'interprète, avec des sockets jamais bloquantes ; un fil à
/// part attend les connexions qui s'établissent, lit ce que l'hôte renvoie et
/// réémet ce qui tarde. Les segments pour l'invité attendent sous verrou que
/// la carte les prenne.
public final class HostStreams: @unchecked Sendable {
    /// Un segment, tel qu'il circule entre l'invité et wisq, sous les adresses
    /// de l'invité.
    public struct Segment: Equatable, Sendable {
        public var remote: [UInt8]
        public var remotePort: UInt16
        public var guestPort: UInt16
        public var sequence: UInt32
        public var acknowledgment: UInt32
        public var flags: UInt8
        public var window: UInt16
        /// La taille de segment annoncée, dans un SYN seulement.
        public var maximumSegment: UInt16?
        public var payload: [UInt8]
    }

    public enum Flag {
        public static let fin: UInt8 = 0x01
        public static let syn: UInt8 = 0x02
        public static let rst: UInt8 = 0x04
        public static let psh: UInt8 = 0x08
        public static let ack: UInt8 = 0x10
    }

    /// Ce que wisq annonce à l'invité : une trame Ethernet pleine.
    public static let segmentSize: UInt16 = 1460
    /// Ce que l'hôte peut avoir lu d'avance pour l'invité.
    static let readAhead = 256 * 1024
    /// Ce que l'invité peut avoir envoyé que l'hôte n'a pas encore pris : la
    /// fenêtre annoncée, sans échelle.
    static let receiveWindow = 65_535
    static let retransmitAfter: TimeInterval = 1
    /// Une connexion qui ne s'établit pas dans ce délai est refusée à
    /// l'invité.
    static let connectTimeout: TimeInterval = 20
    static let connectionLimit = 256

    struct Key: Hashable {
        let guestPort: UInt16
        let remote: [UInt8]
        let remotePort: UInt16
    }

    enum Phase { case connecting, synReceived, established }

    final class Connection {
        let key: Key
        let descriptor: Int32
        var phase = Phase.connecting
        let opened = Date()
        // Le côté de l'invité.
        /// Le prochain octet attendu de l'invité : notre accusé.
        var guestNext: UInt32
        var guestWindow = 0
        var guestSegment = 536
        /// Ce que l'invité a envoyé et que l'hôte n'a pas encore pris.
        var toHost: [UInt8] = []
        var guestFinished = false
        var hostShutDown = false
        // Notre côté.
        let initial: UInt32
        /// Le premier octet que l'invité n'a pas accusé.
        var unacknowledged: UInt32
        /// Lus de l'hôte, depuis `unacknowledged` : en vol d'abord, puis pas
        /// encore envoyés.
        var fromHost: [UInt8] = []
        var inFlight = 0
        var hostFinished = false
        var finSent = false
        var finAcknowledged = false
        var lastSent = Date()

        init(key: Key, descriptor: Int32, guestNext: UInt32, initial: UInt32) {
            self.key = key
            self.descriptor = descriptor
            self.guestNext = guestNext
            self.initial = initial
            self.unacknowledged = initial &+ 1
        }

        var window: UInt16 { UInt16(max(0, HostStreams.receiveWindow - toHost.count)) }
        var finished: Bool { guestFinished && finAcknowledged }
    }

    private let lock = NSLock()
    private var connections: [Key: Connection] = [:]
    private var outgoing: [Segment] = []
    private var running = true
    private let resolver: [UInt8]

    public init(resolver: [UInt8]? = nil) {
        self.resolver = resolver ?? HostDatagrams.hostResolver()
        let thread = Thread { [weak self] in
            while let streams = self, streams.listen() {}
        }
        thread.name = "wisq.tcp"
        thread.start()
    }

    deinit {
        for connection in connections.values { _ = closeSocket(connection.descriptor) }
    }

    public func close() {
        lock.lock()
        running = false
        let closing = connections.values.map(\.descriptor)
        connections.removeAll()
        lock.unlock()
        for descriptor in closing { _ = closeSocket(descriptor) }
    }

    /// Les connexions ouvertes, pour les tests.
    var openConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    public func receive() -> [Segment] {
        lock.lock()
        defer { lock.unlock() }
        guard !outgoing.isEmpty else { return [] }
        let taken = outgoing
        outgoing.removeAll()
        return taken
    }

    // MARK: - Ce que l'invité envoie

    public func handle(_ segment: Segment) {
        let key = Key(guestPort: segment.guestPort, remote: segment.remote, remotePort: segment.remotePort)
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        guard let connection = connections[key] else {
            if segment.flags & (Flag.syn | Flag.ack | Flag.rst) == Flag.syn {
                open(key, from: segment)
            } else if segment.flags & Flag.rst == 0 {
                refuse(segment)
            }
            return
        }
        if segment.flags & Flag.rst != 0 {
            drop(connection)
            return
        }
        if segment.flags & Flag.syn != 0 {
            // Un SYN répété : l'invité n'a pas vu notre réponse.
            if connection.phase == .synReceived { emit(connection, flags: Flag.syn | Flag.ack, sequence: connection.initial) }
            return
        }
        guard segment.flags & Flag.ack != 0 else { return }
        acknowledge(connection, segment.acknowledgment)
        connection.guestWindow = Int(segment.window)
        if connection.phase == .synReceived, segment.acknowledgment == connection.initial &+ 1 {
            connection.phase = .established
        }
        guard connection.phase == .established else { return }
        accept(segment, on: connection)
        pump(connection)
        if connection.finished { drop(connection) }
    }

    /// Sous verrou.
    private func open(_ key: Key, from segment: Segment) {
        guard let host = HostDatagrams.hostEndpoint(for: key.remote, port: key.remotePort, resolver: resolver),
              connections.count < Self.connectionLimit else { return refuse(segment) }
        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard descriptor >= 0 else { return refuse(segment) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        #if canImport(Darwin)
        // Une écriture vers un pair parti ne doit pas tuer l'application.
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = HostDatagrams.socketAddress(host, port: key.remotePort)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else {
            _ = closeSocket(descriptor)
            return refuse(segment)
        }
        let connection = Connection(key: key, descriptor: descriptor, guestNext: segment.sequence &+ 1,
                                    initial: UInt32.random(in: 0...UInt32.max))
        connection.guestWindow = Int(segment.window)
        connection.guestSegment = Int(min(segment.maximumSegment ?? 536, Self.segmentSize))
        connections[key] = connection
    }

    /// Une remise à zéro pour un segment sans connexion, selon RFC 793.
    private func refuse(_ segment: Segment) {
        var reply = Segment(remote: segment.remote, remotePort: segment.remotePort, guestPort: segment.guestPort,
                            sequence: 0, acknowledgment: 0, flags: Flag.rst, window: 0, maximumSegment: nil,
                            payload: [])
        if segment.flags & Flag.ack != 0 {
            reply.sequence = segment.acknowledgment
        } else {
            reply.flags |= Flag.ack
            let length = UInt32(segment.payload.count) + (segment.flags & Flag.syn != 0 ? 1 : 0)
                + (segment.flags & Flag.fin != 0 ? 1 : 0)
            reply.acknowledgment = segment.sequence &+ length
        }
        outgoing.append(reply)
    }

    /// L'accusé de l'invité retire de la file ce qu'il a reçu.
    private func acknowledge(_ connection: Connection, _ acknowledgment: UInt32) {
        let advance = Int(Int32(bitPattern: acknowledgment &- connection.unacknowledged))
        let finCount = connection.finSent && !connection.finAcknowledged ? 1 : 0
        guard advance > 0, advance <= connection.inFlight + finCount, connection.phase == .established else { return }
        let data = min(advance, connection.inFlight)
        connection.fromHost.removeFirst(data)
        connection.inFlight -= data
        connection.unacknowledged &+= UInt32(data)
        if advance > data {
            connection.finAcknowledged = true
            connection.unacknowledged &+= 1
        }
        connection.lastSent = Date()
    }

    /// Les données et la fin de l'invité, dans l'ordre seulement.
    private func accept(_ segment: Segment, on connection: Connection) {
        var payload = segment.payload
        var sequence = segment.sequence
        // Un segment déjà reçu en partie, réémis : on garde ce qui est neuf.
        let behind = Int(Int32(bitPattern: connection.guestNext &- sequence))
        if behind > 0 {
            guard behind <= payload.count || (behind == payload.count + 1 && segment.flags & Flag.fin != 0) else {
                emit(connection, flags: Flag.ack)
                return
            }
            payload.removeFirst(min(behind, payload.count))
            sequence &+= UInt32(behind)
        }
        guard sequence == connection.guestNext else {
            // En avance : on le laisse, l'invité réémettra dans l'ordre.
            emit(connection, flags: Flag.ack)
            return
        }
        let room = Int(connection.window)
        let taken = Array(payload.prefix(room))
        var acknowledge = !taken.isEmpty
        if !taken.isEmpty, !connection.guestFinished {
            connection.toHost += taken
            connection.guestNext &+= UInt32(taken.count)
            writeToHost(connection)
        }
        if segment.flags & Flag.fin != 0, taken.count == payload.count, !connection.guestFinished {
            connection.guestFinished = true
            connection.guestNext &+= 1
            acknowledge = true
            shutDownIfDrained(connection)
        }
        if acknowledge { emit(connection, flags: Flag.ack) }
    }

    /// Sous verrou. Jamais bloquant : ce que l'hôte ne prend pas attend.
    private func writeToHost(_ connection: Connection) {
        guard !connection.toHost.isEmpty else { return }
        let written = connection.toHost.withUnsafeBytes {
            send(connection.descriptor, $0.baseAddress, $0.count, Self.sendFlags)
        }
        if written > 0 { connection.toHost.removeFirst(written) }
        shutDownIfDrained(connection)
    }

    private func shutDownIfDrained(_ connection: Connection) {
        if connection.guestFinished, connection.toHost.isEmpty, !connection.hostShutDown {
            connection.hostShutDown = true
            _ = shutdown(connection.descriptor, Int32(SHUT_WR))
        }
    }

    /// Sous verrou : envoyer à l'invité ce que sa fenêtre accepte, puis la fin.
    private func pump(_ connection: Connection) {
        guard connection.phase == .established else { return }
        while connection.inFlight < connection.fromHost.count, connection.inFlight < connection.guestWindow {
            let size = min(connection.guestSegment, connection.fromHost.count - connection.inFlight,
                           connection.guestWindow - connection.inFlight)
            let start = connection.inFlight
            let chunk = Array(connection.fromHost[start..<(start + size)])
            emit(connection, flags: Flag.ack | Flag.psh,
                 sequence: connection.unacknowledged &+ UInt32(start), payload: chunk)
            connection.inFlight += size
            connection.lastSent = Date()
        }
        if connection.hostFinished, !connection.finSent, connection.inFlight == connection.fromHost.count {
            connection.finSent = true
            emit(connection, flags: Flag.fin | Flag.ack,
                 sequence: connection.unacknowledged &+ UInt32(connection.inFlight))
            connection.lastSent = Date()
        }
    }

    private func emit(_ connection: Connection, flags: UInt8, sequence: UInt32? = nil, payload: [UInt8] = []) {
        let next = connection.unacknowledged &+ UInt32(connection.inFlight)
            &+ (connection.finSent && !connection.finAcknowledged ? 1 : 0)
        outgoing.append(Segment(remote: connection.key.remote, remotePort: connection.key.remotePort,
                                guestPort: connection.key.guestPort,
                                sequence: sequence ?? (connection.phase == .established ? next : connection.initial),
                                acknowledgment: connection.guestNext, flags: flags, window: connection.window,
                                maximumSegment: flags & Flag.syn != 0 ? Self.segmentSize : nil,
                                payload: payload))
    }

    /// Sous verrou.
    private func drop(_ connection: Connection) {
        _ = closeSocket(connection.descriptor)
        connections[connection.key] = nil
    }

    private func reset(_ connection: Connection) {
        emit(connection, flags: Flag.rst | Flag.ack)
        drop(connection)
    }

    // MARK: - Le fil

    private func listen() -> Bool {
        lock.lock()
        guard running else { lock.unlock(); return false }
        let now = Date()
        var watched: [(connection: Connection, events: Int16)] = []
        for connection in connections.values {
            switch connection.phase {
            case .connecting:
                if now.timeIntervalSince(connection.opened) > Self.connectTimeout {
                    reset(connection)
                } else {
                    watched.append((connection, Int16(POLLOUT)))
                }
            case .synReceived:
                if now.timeIntervalSince(connection.lastSent) > Self.retransmitAfter {
                    emit(connection, flags: Flag.syn | Flag.ack, sequence: connection.initial)
                    connection.lastSent = now
                }
            case .established:
                if (connection.inFlight > 0 || (connection.finSent && !connection.finAcknowledged)),
                   now.timeIntervalSince(connection.lastSent) > Self.retransmitAfter {
                    // Tout depuis le dernier accusé.
                    connection.inFlight = 0
                    if !connection.finAcknowledged { connection.finSent = false }
                    pump(connection)
                }
                var events: Int16 = 0
                if !connection.hostFinished, connection.fromHost.count < Self.readAhead { events |= Int16(POLLIN) }
                if !connection.toHost.isEmpty { events |= Int16(POLLOUT) }
                if events != 0 { watched.append((connection, events)) }
            }
        }
        lock.unlock()
        guard !watched.isEmpty else {
            usleep(10_000)
            return true
        }
        var descriptors = watched.map { pollfd(fd: $0.connection.descriptor, events: $0.events, revents: 0) }
        guard poll(&descriptors, nfds_t(descriptors.count), 20) > 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        lock.lock()
        defer { lock.unlock() }
        for (index, entry) in descriptors.enumerated() where entry.revents != 0 {
            let connection = watched[index].connection
            // Refermée entre-temps par l'invité.
            guard connections[connection.key] === connection else { continue }
            serve(connection, revents: entry.revents, buffer: &buffer)
        }
        return true
    }

    /// Sous verrou.
    private func serve(_ connection: Connection, revents: Int16, buffer: inout [UInt8]) {
        switch connection.phase {
        case .connecting:
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(connection.descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
            // Un refus se lit dans l'erreur de la socket, pas dans l'événement.
            guard failure == 0 else { return reset(connection) }
            connection.phase = .synReceived
            emit(connection, flags: Flag.syn | Flag.ack, sequence: connection.initial)
            connection.lastSent = Date()
        case .synReceived:
            return
        case .established:
            if revents & Int16(POLLOUT) != 0 {
                let before = connection.toHost.count
                writeToHost(connection)
                // La fenêtre se rouvre : l'invité doit l'apprendre.
                if connection.toHost.count < before { emit(connection, flags: Flag.ack) }
            }
            guard revents & Int16(POLLIN | POLLHUP | POLLERR) != 0, !connection.hostFinished else { return }
            let room = min(buffer.count, Self.readAhead - connection.fromHost.count)
            guard room > 0 else { return }
            let count = buffer.withUnsafeMutableBytes { recv(connection.descriptor, $0.baseAddress, room, 0) }
            if count > 0 {
                connection.fromHost += buffer[0..<count]
            } else if count == 0 {
                connection.hostFinished = true
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                return reset(connection)
            }
            pump(connection)
            if connection.finished { drop(connection) }
        }
    }

    #if canImport(Glibc)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
    static let streamType = SOCK_STREAM
    static let sendFlags: Int32 = 0
    #endif
}
