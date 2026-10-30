import Foundation

/// **Ce qui est de l'autre côté du câble.**
///
/// La carte réseau ne sait que deux choses : prendre les trames que l'invité
/// envoie, et lui rendre celles qui arrivent. Ce qui en fait un réseau — un
/// serveur DHCP, une passerelle, des connexions vers l'extérieur — vit derrière
/// ce protocole, pas dans le périphérique.
///
/// Les deux appels viennent du fil d'émulation : `send` quand l'invité
/// transmet, `receive` à chaque passage du contrôleur d'interruptions. Une
/// implémentation qui reçoit d'ailleurs (un socket de l'hôte) range ses trames
/// et les rend là.
public protocol NetworkBackend: AnyObject {
    /// Une trame Ethernet que l'invité vient d'envoyer, sans l'en-tête virtio.
    func send(_ frame: [UInt8])
    /// Les trames qui attendent l'invité, retirées de l'attente.
    func receive() -> [[UInt8]]
}

/// **Une carte réseau virtio, par la forme ancienne de virtio-pci.**
///
/// La même porte que `VirtioBlock` : une fenêtre de ports, le numéro de page
/// de chaque file, et l'octet d'état d'interruption qui s'acquitte en le
/// lisant. Deux files au lieu d'une : la zéro reçoit, la une émet.
///
/// **Ce qui est annoncé, et seulement ça** : `VIRTIO_NET_F_MAC`, pour que le
/// pilote lise l'adresse dans l'espace de configuration plutôt que d'en tirer
/// une au hasard à chaque démarrage. Sans `MRG_RXBUF`, l'en-tête de chaque
/// trame fait dix octets ; sans les fonctions de déchargement, le pilote
/// calcule ses sommes de contrôle et découpe ses segments lui-même, et le
/// périphérique ne voit que des trames entières.
public final class VirtioNet: @unchecked Sendable {
    /// Six octets. Le bit « administré localement » est posé et le bit de
    /// groupe ne l'est pas : une adresse qui n'appartient à aucun fabricant.
    public let mac: [UInt8]
    /// L'autre bout. Sans lui, ce que l'invité envoie se perd et rien
    /// n'arrive — un câble débranché, ce qu'un pilote sait vivre.
    @exclusivity(unchecked)
    public var backend: NetworkBackend?

    /// L'adresse par défaut : `02` (locale, individuelle), puis « wisq ».
    public static let defaultMAC: [UInt8] = [0x02, 0x77, 0x69, 0x73, 0x71, 0x01]

    public init(mac: [UInt8] = VirtioNet.defaultMAC, backend: NetworkBackend? = nil) {
        precondition(mac.count == 6)
        self.mac = mac
        self.backend = backend
    }

    // MARK: - L'état

    /// Une file : sa page, ses trois anneaux, et où on en est.
    struct Queue: Equatable {
        var pageNumber: UInt32 = 0
        var descriptors: UInt64 = 0
        var available: UInt64 = 0
        var used: UInt64 = 0
        var nextAvailable: UInt16 = 0
        var nextUsed: UInt16 = 0
        var ready: Bool { pageNumber != 0 }
    }

    static let receiveQueue = 0
    static let transmitQueue = 1
    var queues = [Queue(), Queue()]
    var queueSelect: UInt16 = 0
    public private(set) var driverFeatures: UInt32 = 0
    public private(set) var status: UInt8 = 0
    @exclusivity(unchecked)
    public private(set) var interruptStatus: UInt8 = 0

    /// Ce qui est arrivé et n'a pas encore trouvé de tampon chez l'invité.
    var waiting: [[UInt8]] = []
    /// Combien de trames ont été envoyées, reçues, et perdues.
    public private(set) var transmitted: UInt64 = 0
    public private(set) var delivered: UInt64 = 0
    public private(set) var dropped: UInt64 = 0

    static let macFeature: UInt32 = 1 << 5
    static let queueLimit: UInt32 = 256
    /// L'en-tête `virtio_net_hdr` sans tampons fusionnés.
    static let headerBytes = 10
    /// **Ce qu'on garde en attente au plus.** Un invité qui ne pose plus de
    /// tampons — pilote déchargé, machine arrêtée sur autre chose — ne doit pas
    /// faire grandir la file sans fin : au-delà, on perd, comme un vrai câble.
    static let waitingLimit = 512
    /// La plus grande trame Ethernet sans les jumbos, et l'en-tête : au-delà,
    /// ce n'est pas une trame qu'un pilote de ce genre a demandée.
    static let largestFrame = 1514

    /// Vrai quand le périphérique demande l'interruption.
    public var interrupting: Bool { interruptStatus != 0 }

    // MARK: - La fenêtre de ports

    public func readPort(_ offset: UInt16, _ width: Int) -> UInt64 {
        switch offset {
        case 0x00: return UInt64(Self.macFeature)
        case 0x04: return UInt64(driverFeatures)
        case 0x08: return UInt64(queues[Int(queueSelect)].pageNumber)
        case 0x0C: return UInt64(Self.queueLimit)
        case 0x0E: return UInt64(queueSelect)
        case 0x12: return UInt64(status)
        case 0x13:
            let pending = interruptStatus
            interruptStatus = 0
            return UInt64(pending)
        case 0x14...0x19:
            // L'adresse, octet par octet, quelle que soit la largeur lue.
            let first = Int(offset - 0x14)
            var value: UInt64 = 0
            for byte in 0..<width where first + byte < 6 {
                value |= UInt64(mac[first + byte]) << (8 * UInt64(byte))
            }
            return value
        default: return 0
        }
    }

    public func writePort(_ offset: UInt16, _ width: Int, _ value: UInt64, _ memory: GuestMemory) {
        switch offset {
        case 0x04: driverFeatures = UInt32(truncatingIfNeeded: value) & Self.macFeature
        case 0x08:
            let page = UInt32(truncatingIfNeeded: value)
            var queue = Queue(pageNumber: page)
            if page != 0 {
                (queue.descriptors, queue.available, queue.used) =
                    VirtioBlock.rings(pageNumber: page, size: Self.queueLimit)
            }
            queues[Int(queueSelect)] = queue
        case 0x0E:
            // Deux files seulement ; une autre se lit fermée et s'écrit dans
            // le vide, ce que le pilote prend pour « pas de file ici ».
            queueSelect = UInt16(truncatingIfNeeded: value) < 2 ? UInt16(truncatingIfNeeded: value) : 0
        case 0x10:
            switch Int(value) {
            case Self.transmitQueue: transmit(memory)
            case Self.receiveQueue: deliver(memory)
            default: break
            }
        case 0x12:
            status = UInt8(truncatingIfNeeded: value)
            if status == 0 { reset() }
        default: break
        }
    }

    func reset() {
        queues = [Queue(), Queue()]
        queueSelect = 0
        driverFeatures = 0
        interruptStatus = 0
        waiting.removeAll()
    }

    // MARK: - Les files

    /// La chaîne de descripteurs qui commence à `head`, bornée.
    private func chain(_ head: UInt16, in queue: Queue, _ memory: GuestMemory) -> [VirtioBlock.Descriptor] {
        var found: [VirtioBlock.Descriptor] = []
        var index = head
        while found.count < Int(Self.queueLimit) {
            let at = queue.descriptors &+ UInt64(index % UInt16(Self.queueLimit)) &* 16
            guard let address = try? memory.read(at, 8),
                  let length = try? memory.read(at &+ 8, 4),
                  let flags = try? memory.read(at &+ 12, 2),
                  let next = try? memory.read(at &+ 14, 2) else { break }
            let one = VirtioBlock.Descriptor(
                address: address, length: UInt32(truncatingIfNeeded: length),
                flags: UInt16(truncatingIfNeeded: flags), next: UInt16(truncatingIfNeeded: next))
            found.append(one)
            guard one.chained else { break }
            index = one.next
        }
        return found
    }

    /// La prochaine requête que le pilote a rendue disponible, ou rien.
    private func nextHead(_ which: Int, _ memory: GuestMemory) -> UInt16? {
        let queue = queues[which]
        guard queue.ready, let head = try? memory.read(queue.available &+ 2, 2),
              UInt16(truncatingIfNeeded: head) != queue.nextAvailable else { return nil }
        let slot = UInt64(queue.nextAvailable % UInt16(Self.queueLimit))
        guard let entry = try? memory.read(queue.available &+ 4 &+ slot &* 2, 2) else { return nil }
        queues[which].nextAvailable &+= 1
        return UInt16(truncatingIfNeeded: entry)
    }

    /// Range une requête dans l'anneau des servies, et lève l'interruption.
    private func complete(_ which: Int, _ head: UInt16, length: UInt32, _ memory: GuestMemory) {
        let queue = queues[which]
        let slot = UInt64(queue.nextUsed % UInt16(Self.queueLimit))
        try? memory.write(queue.used &+ 4 &+ slot &* 8, 4, UInt64(head))
        try? memory.write(queue.used &+ 8 &+ slot &* 8, 4, UInt64(length))
        queues[which].nextUsed &+= 1
        try? memory.write(queue.used &+ 2, 2, UInt64(queues[which].nextUsed))
        interruptStatus |= 1
    }

    /// **Ce que l'invité envoie** : chaque chaîne de la file d'émission, ses
    /// octets lus bout à bout, l'en-tête retiré, et la trame au réseau.
    func transmit(_ memory: GuestMemory) {
        while let head = nextHead(Self.transmitQueue, memory) {
            var bytes: [UInt8] = []
            for buffer in chain(head, in: queues[Self.transmitQueue], memory) where !buffer.writable {
                let room = Self.headerBytes + Self.largestFrame - bytes.count
                let count = min(Int(buffer.length), max(room, 0))
                bytes += memory.copyOut(at: buffer.address, count: count)
            }
            if bytes.count > Self.headerBytes, let backend {
                backend.send(Array(bytes[Self.headerBytes...]))
                transmitted &+= 1
            } else {
                dropped &+= 1
            }
            complete(Self.transmitQueue, head, length: 0, memory)
        }
    }

    /// **Ce qui arrive** : les trames du réseau, rangées dans les tampons que
    /// le pilote a posés sur la file de réception, chacune derrière un
    /// en-tête nul. Celles qui ne trouvent pas de tampon attendent.
    func deliver(_ memory: GuestMemory) {
        while !waiting.isEmpty, let head = nextHead(Self.receiveQueue, memory) {
            let frame = waiting.removeFirst()
            let bytes = [UInt8](repeating: 0, count: Self.headerBytes) + frame
            var at = 0
            for buffer in chain(head, in: queues[Self.receiveQueue], memory) where buffer.writable {
                guard at < bytes.count else { break }
                let count = min(Int(buffer.length), bytes.count - at)
                memory.copyIn(Array(bytes[at..<(at + count)]), at: buffer.address)
                at += count
            }
            if at < bytes.count {
                // Un tampon trop petit pour la trame : la rendre tronquée
                // ferait lire au pilote un paquet qui n'a jamais existé.
                dropped &+= 1
                complete(Self.receiveQueue, head, length: 0, memory)
            } else {
                delivered &+= 1
                complete(Self.receiveQueue, head, length: UInt32(bytes.count), memory)
            }
        }
    }

    /// Les passages du contrôleur d'interruptions qu'on laisse filer, quand le
    /// processeur travaille, entre deux questions au réseau.
    ///
    /// **Pourquoi.** Le contrôleur passe toutes les soixante-quatre
    /// instructions, et chaque question au réseau en mode utilisateur prend
    /// quatre verrous — le sien, l'UDP, le TCP, l'ICMP — même quand rien
    /// n'est arrivé. Mesuré sur l'Alpine installé, six milliards
    /// d'instructions : 200 s sans carte, 223 s avec. Une question sur seize,
    /// soit toutes les 1 024 instructions (une trentaine de microsecondes),
    /// ne se voit plus, ni dans le temps ni dans la latence.
    ///
    /// **Au repos, à chaque passage** : une machine endormie n'exécute rien,
    /// et attendre seize passages, ce serait attendre seize battements.
    static let busyPollInterval = 16
    private var passesSincePoll = 0

    /// **Prendre ce que le réseau a pour l'invité**, et le lui donner si ses
    /// tampons sont là. Appelé à chaque passage du contrôleur d'interruptions ;
    /// `busy` dit que le processeur travaille (voir `busyPollInterval`).
    public func poll(_ memory: GuestMemory, busy: Bool = false) {
        if busy {
            passesSincePoll += 1
            guard passesSincePoll >= Self.busyPollInterval else {
                deliver(memory)
                return
            }
        }
        passesSincePoll = 0
        if let backend {
            for frame in backend.receive() {
                guard frame.count <= Self.largestFrame, waiting.count < Self.waitingLimit else {
                    dropped &+= 1
                    continue
                }
                waiting.append(frame)
            }
        }
        deliver(memory)
    }

    // MARK: - Ce qu'on sauve

    /// **Ce que le pilote a posé, et où en sont les deux files.** Les trames
    /// en attente ne se sauvent pas : un réseau perd des paquets, et le pilote
    /// et les protocoles au-dessus savent le vivre ; un instantané qui les
    /// porterait les rendrait au retour, des minutes plus tard, à un invité
    /// qui ne les attend plus.
    func save(into writer: inout Snapshot.Writer) {
        for byte in mac { writer.u32(UInt32(byte)) }
        for queue in queues {
            writer.u32(queue.pageNumber)
            writer.u32(UInt32(queue.nextAvailable))
            writer.u32(UInt32(queue.nextUsed))
        }
        writer.u32(UInt32(queueSelect))
        writer.u32(driverFeatures)
        writer.u32(UInt32(status))
        writer.u32(UInt32(interruptStatus))
    }

    /// La carte telle qu'elle était, branchée sur `backend`.
    static func restored(from reader: inout Snapshot.Reader, backend: NetworkBackend?) throws -> VirtioNet {
        var mac: [UInt8] = []
        for _ in 0..<6 { mac.append(UInt8(truncatingIfNeeded: try reader.u32())) }
        let device = VirtioNet(mac: mac, backend: backend)
        for which in 0..<2 {
            let page = try reader.u32()
            var queue = Queue(pageNumber: page)
            if page != 0 {
                (queue.descriptors, queue.available, queue.used) =
                    VirtioBlock.rings(pageNumber: page, size: queueLimit)
            }
            queue.nextAvailable = UInt16(truncatingIfNeeded: try reader.u32())
            queue.nextUsed = UInt16(truncatingIfNeeded: try reader.u32())
            device.queues[which] = queue
        }
        let select = try reader.u32()
        guard select < 2 else { throw Snapshot.Failure.corrupt }
        device.queueSelect = UInt16(select)
        device.driverFeatures = try reader.u32() & macFeature
        device.status = UInt8(truncatingIfNeeded: try reader.u32())
        device.interruptStatus = UInt8(truncatingIfNeeded: try reader.u32())
        return device
    }
}
