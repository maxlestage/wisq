import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// **Le ping de l'invité vers le dehors** : ses échos ICMP partent par une
/// socket ICMP « datagramme » de l'hôte, celle qu'un programme sans
/// privilège a le droit d'ouvrir (iOS et macOS l'ouvrent ; Linux, si
/// `net.ipv4.ping_group_range` le permet).
///
/// **Le noyau change l'identifiant de l'écho** — Linux y met le numéro de la
/// socket. La réponse se reconnaît donc à sa source et à son numéro de
/// séquence, et repart vers l'invité avec l'identifiant qu'il avait choisi,
/// sinon son `ping` la jetterait.
///
/// Sans la socket, `make()` ne rend rien, et l'écho se perd comme avant.
public final class HostEchoes: @unchecked Sendable {
    /// Une réponse pour l'invité.
    public struct Reply: Equatable, Sendable {
        public let source: [UInt8]
        /// Le message ICMP entier, l'identifiant de l'invité remis en place.
        public let message: [UInt8]
    }

    struct Pending: Hashable {
        let destination: [UInt8]
        let sequence: UInt16
    }

    /// Un écho sans réponse au bout de ce délai est oublié.
    static let patience: TimeInterval = 10
    static let pendingLimit = 256

    private let descriptor: Int32
    private let lock = NSLock()
    private var pending: [Pending: (identifier: UInt16, sent: Date)] = [:]
    private var arrived: [Reply] = []
    private var running = true

    /// La socket, si le système la permet.
    public static func make() -> HostEchoes? {
        let descriptor = socket(AF_INET, HostDatagrams.datagramType, Int32(IPPROTO_ICMP))
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        return HostEchoes(descriptor: descriptor)
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        let thread = Thread { [weak self] in
            while let echoes = self, echoes.listen() {}
        }
        thread.name = "wisq.icmp"
        thread.start()
    }

    deinit { if running { _ = closeSocket(descriptor) } }

    public func close() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { _ = closeSocket(descriptor) }
    }

    /// Un écho de l'invité (le message ICMP entier) vers `destination`, une
    /// adresse de l'hôte.
    public func send(_ message: [UInt8], to destination: [UInt8]) {
        guard destination.count == 4, message.count >= 8, message[0] == 8 else { return }
        let identifier = UserNetwork.be16(message, 4)
        let sequence = UserNetwork.be16(message, 6)
        lock.lock()
        guard running else { lock.unlock(); return }
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.sent) < Self.patience }
        if pending.count < Self.pendingLimit {
            pending[Pending(destination: destination, sequence: sequence)] = (identifier, now)
        }
        lock.unlock()
        var address = HostDatagrams.socketAddress(destination, port: 0)
        _ = message.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func receive() -> [Reply] {
        lock.lock()
        defer { lock.unlock() }
        guard !arrived.isEmpty else { return [] }
        let taken = arrived
        arrived.removeAll()
        return taken
    }

    /// Un tour du fil. Faux une fois arrêté.
    private func listen() -> Bool {
        lock.lock()
        let alive = running
        lock.unlock()
        guard alive else { return false }
        var watched = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        guard poll(&watched, 1, 50) > 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length)
                }
            }
        }
        guard count > 0 else { return true }
        let raw = UInt32(bigEndian: address.sin_addr.s_addr)
        let source = [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        if let reply = Self.reply(Array(buffer[0..<count]), from: source, restoring: identifier(for:)) {
            lock.lock()
            if arrived.count < 256 { arrived.append(reply) }
            lock.unlock()
        }
        return true
    }

    private func identifier(for key: Pending) -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: key)?.identifier
    }

    /// **La réponse telle que l'invité l'attend.** Darwin rend l'en-tête IPv4
    /// devant le message, Linux non : on l'ôte s'il est là. Seule une réponse
    /// d'écho attendue passe, l'identifiant de l'invité remis, la somme
    /// refaite.
    static func reply(_ received: [UInt8], from source: [UInt8],
                      restoring identifier: (Pending) -> UInt16?) -> Reply? {
        var message = received
        if message.count >= 20, message[0] >> 4 == 4 {
            let header = Int(message[0] & 0x0F) * 4
            guard header >= 20, message.count >= header + 8 else { return nil }
            message = Array(message[header...])
        }
        guard message.count >= 8, message[0] == 0, message[1] == 0,
              let guestIdentifier = identifier(Pending(destination: source, sequence: UserNetwork.be16(message, 6)))
        else { return nil }
        message[4] = UInt8(guestIdentifier >> 8)
        message[5] = UInt8(guestIdentifier & 0xFF)
        message[2] = 0
        message[3] = 0
        let sum = UserNetwork.checksum(message)
        message[2] = UInt8(sum >> 8)
        message[3] = UInt8(sum & 0xFF)
        return Reply(source: source, message: message)
    }
}
