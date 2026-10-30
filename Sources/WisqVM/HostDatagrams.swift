import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Ce qui porte les datagrammes UDP de l'invité au-dehors, et rapporte les
/// réponses. Les adresses sont toujours **celles que voit l'invité** : c'est
/// au relais de les traduire, et à lui seul.
public protocol DatagramRelay: AnyObject {
    /// Un datagramme parti de `guestPort` vers `destination:port`.
    func send(_ payload: [UInt8], to destination: [UInt8], port: UInt16, fromGuestPort guestPort: UInt16)
    /// Les réponses arrivées depuis : d'où elles viennent, vers quel port de
    /// l'invité, et leur contenu.
    func receive() -> [UserNetwork.Datagram]
}

/// **Le relais UDP de l'hôte** : une socket par port source de l'invité,
/// comme chez slirp, et un fil qui les écoute.
///
/// **Pourquoi un fil.** La carte est interrogée toutes les soixante-quatre
/// instructions ; un appel système à ce rythme coûterait plus que
/// l'interprète lui-même. Le fil attend les sockets, et `receive()` ne fait
/// que vider une file sous verrou.
///
/// **Deux adresses traduites**, celles de QEMU : `10.0.2.3:53` est le serveur
/// de noms de l'hôte, et `10.0.2.2` est l'hôte lui-même (`127.0.0.1`). Une
/// réponse revient sous l'adresse à laquelle l'invité avait écrit, sinon il
/// la jetterait.
public final class HostDatagrams: DatagramRelay, @unchecked Sendable {
    /// Une socket sans trafic depuis ce délai est refermée : un client DNS
    /// prend un port neuf à chaque requête, et elles s'accumuleraient.
    public static let idleSeconds: TimeInterval = 60
    /// Au-delà, la plus ancienne socket cède sa place.
    public static let socketLimit = 64

    private struct Outlet {
        let descriptor: Int32
        var lastUsed: Date
        /// Adresse de l'hôte → adresse vue par l'invité, pour les réponses.
        var seenAs: [Endpoint: Endpoint] = [:]
    }

    struct Endpoint: Hashable {
        let address: [UInt8]
        let port: UInt16
    }

    private let lock = NSLock()
    private var outlets: [UInt16: Outlet] = [:]
    private var arrived: [UserNetwork.Datagram] = []
    private var running = true
    private let resolver: [UInt8]

    /// `resolver` : le serveur de noms qui répond pour `10.0.2.3`, celui de
    /// l'hôte par défaut.
    public init(resolver: [UInt8]? = nil) {
        self.resolver = resolver ?? Self.hostResolver()
        let thread = Thread { [weak self] in
            while let relay = self, relay.listen() {}
        }
        thread.name = "wisq.udp"
        thread.start()
    }

    deinit {
        for outlet in outlets.values { _ = closeSocket(outlet.descriptor) }
    }

    /// Arrête le fil et ferme les sockets.
    public func close() {
        lock.lock()
        running = false
        let closing = outlets.values.map(\.descriptor)
        outlets.removeAll()
        lock.unlock()
        for descriptor in closing { _ = closeSocket(descriptor) }
    }

    /// Les sockets ouvertes, pour les tests.
    var openSockets: Int {
        lock.lock()
        defer { lock.unlock() }
        return outlets.count
    }

    // MARK: - La traduction

    /// Où va vraiment un datagramme que l'invité adresse à `destination:port`.
    static func hostEndpoint(for destination: [UInt8], port: UInt16, resolver: [UInt8]) -> [UInt8]? {
        if destination == UserNetwork.nameServer { return port == 53 ? resolver : nil }
        if destination == UserNetwork.gateway { return [127, 0, 0, 1] }
        // Le reste du petit réseau n'existe pas, ni la diffusion.
        if Array(destination[0..<3]) == [10, 0, 2] || destination == [255, 255, 255, 255] { return nil }
        if destination[0] >= 224 { return nil }
        return destination
    }

    /// Le serveur de noms de l'hôte : le premier `nameserver` IPv4 de
    /// `/etc/resolv.conf`, sinon un résolveur public.
    static func hostResolver(_ text: String? = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8))
        -> [UInt8] {
        for line in (text ?? "").split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, words[0] == "nameserver" else { continue }
            let parts = words[1].split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4, words[1].split(separator: ".").count == 4 {
                return parts
            }
        }
        return [1, 1, 1, 1]
    }

    // MARK: - L'envoi

    public func send(_ payload: [UInt8], to destination: [UInt8], port: UInt16, fromGuestPort guestPort: UInt16) {
        guard destination.count == 4, port != 0,
              let host = Self.hostEndpoint(for: destination, port: port, resolver: resolver) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        guard var outlet = outlets[guestPort] ?? openOutlet() else { return }
        outlet.lastUsed = Date()
        outlet.seenAs[Endpoint(address: host, port: port)] = Endpoint(address: destination, port: port)
        outlets[guestPort] = outlet
        var address = Self.socketAddress(host, port: port)
        _ = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(outlet.descriptor, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func receive() -> [UserNetwork.Datagram] {
        lock.lock()
        defer { lock.unlock() }
        guard !arrived.isEmpty else { return [] }
        let taken = arrived
        arrived.removeAll()
        return taken
    }

    /// Sous verrou.
    private func openOutlet() -> Outlet? {
        if outlets.count >= Self.socketLimit,
           let oldest = outlets.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            _ = closeSocket(oldest.value.descriptor)
            outlets[oldest.key] = nil
        }
        let descriptor = socket(AF_INET, Self.datagramType, 0)
        guard descriptor >= 0 else { return nil }
        // Jamais bloquante : le fil ne lit que ce que `poll` lui annonce, et
        // l'envoi ne doit pas arrêter l'interprète.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        return Outlet(descriptor: descriptor, lastUsed: Date())
    }

    // MARK: - L'écoute

    /// Un tour du fil : attendre, lire, refermer ce qui dort. Faux une fois
    /// arrêté.
    private func listen() -> Bool {
        lock.lock()
        guard running else { lock.unlock(); return false }
        let now = Date()
        for (port, outlet) in outlets where now.timeIntervalSince(outlet.lastUsed) > Self.idleSeconds {
            _ = closeSocket(outlet.descriptor)
            outlets[port] = nil
        }
        let watched = outlets.map { (port: $0.key, descriptor: $0.value.descriptor) }
        lock.unlock()
        guard !watched.isEmpty else {
            usleep(20_000)
            return true
        }
        var descriptors = watched.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
        // Un délai court : une socket ouverte entre-temps attend au plus ça.
        guard poll(&descriptors, nfds_t(descriptors.count), 20) > 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for (index, entry) in descriptors.enumerated() where entry.revents & Int16(POLLIN) != 0 {
            while let (from, payload) = Self.read(entry.fd, into: &buffer) {
                deliver(payload, from: from, toGuestPort: watched[index].port, descriptor: entry.fd)
            }
        }
        return true
    }

    private func deliver(_ payload: [UInt8], from host: Endpoint, toGuestPort port: UInt16, descriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // La socket a pu être refermée, et son port repris, pendant la lecture.
        guard let outlet = outlets[port], outlet.descriptor == descriptor,
              let seen = outlet.seenAs[host] else { return }
        // Une file bornée : un invité qui ne lit plus ne fait pas grossir l'hôte.
        guard arrived.count < 256 else { return }
        arrived.append(UserNetwork.Datagram(source: seen.address, sourcePort: seen.port,
                                            guestPort: port, payload: payload))
    }

    private static func read(_ descriptor: Int32, into buffer: inout [UInt8]) -> (Endpoint, [UInt8])? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length)
                }
            }
        }
        guard count >= 0 else { return nil }
        let raw = UInt32(bigEndian: address.sin_addr.s_addr)
        let source = [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        return (Endpoint(address: source, port: UInt16(bigEndian: address.sin_port)), Array(buffer[0..<count]))
    }

    static func socketAddress(_ address: [UInt8], port: UInt16) -> sockaddr_in {
        var result = sockaddr_in()
        #if canImport(Darwin)
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        result.sin_family = sa_family_t(AF_INET)
        result.sin_port = port.bigEndian
        let raw = UInt32(address[0]) << 24 | UInt32(address[1]) << 16 | UInt32(address[2]) << 8 | UInt32(address[3])
        result.sin_addr.s_addr = raw.bigEndian
        return result
    }

    #if canImport(Glibc)
    static let datagramType = Int32(SOCK_DGRAM.rawValue)
    #else
    static let datagramType = SOCK_DGRAM
    #endif
}

private func closeSocket(_ descriptor: Int32) -> Int32 {
    #if canImport(Glibc)
    Glibc.close(descriptor)
    #else
    Darwin.close(descriptor)
    #endif
}
