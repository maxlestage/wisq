import Foundation

/// **Une tablette virtio : toucher l'écran là où l'on veut cliquer.**
///
/// La souris PS/2 (`X86PS2`) est relative : le doigt la pousse comme un pavé
/// tactile, et le pointeur ne va jamais exactement sous le doigt — Xorg
/// accélère ce qu'on lui envoie. Une tablette dit **où** : une position
/// absolue entre 0 et 32 767 sur chaque axe, que Linux (`virtio_input`, puis
/// `evdev`) et Xorg (`libinput`) rapportent à l'écran entier. C'est ce que
/// fait la `virtio-tablet` de QEMU, et ce que ce modèle reproduit : même nom
/// de bus, mêmes axes, mêmes boutons, plus la molette.
///
/// **Le transport « moderne » de virtio 1.0, et pas l'ancien.** Les disques
/// et la carte réseau de wisq parlent l'ancien transport, par des ports
/// d'entrée-sortie ; `virtio_input` le refuse (il exige `VIRTIO_F_VERSION_1`).
/// Ici donc : l'espace de configuration PCI porte une **liste de capacités**
/// qui disent où, dans la BAR0 (seize kibioctets en mémoire), trouver les
/// registres communs, l'ISR, la configuration du périphérique et les
/// sonnettes. Les files sont décrites par trois adresses de 64 bits, et le
/// pilote les active une à une.
///
/// **Pas de MSI-X** : le pilote retombe sur la ligne d'interruption (INTx),
/// comme pour les autres périphériques de la machine. Les vecteurs demandés
/// sont refusés (`0xFFFF`), ce que le pilote lit comme « pas de vecteur ».
///
/// Ce fichier ne sait rien de la machine : la configuration PCI, la fenêtre
/// de registres et la mémoire de l'invité lui sont passées. La brancher sur le
/// bus est une autre tranche.
public final class VirtioTablet: @unchecked Sendable {
    // MARK: - Ce qu'elle annonce

    /// Le nom que `evdev` donne au périphérique.
    public static let name = "wisq tablet"
    /// L'étendue de chaque axe : de 0 à 32 767, comme la tablette de QEMU.
    public static let axisMaximum: UInt32 = 0x7FFF

    // Les codes de `linux/input-event-codes.h`.
    static let synchronize: UInt16 = 0x00    // EV_SYN
    static let key: UInt16 = 0x01            // EV_KEY
    static let relative: UInt16 = 0x02       // EV_REL
    static let absolute: UInt16 = 0x03       // EV_ABS
    static let wheel: UInt16 = 0x08          // REL_WHEEL
    static let axisX: UInt16 = 0x00          // ABS_X
    static let axisY: UInt16 = 0x01          // ABS_Y
    /// BTN_LEFT, BTN_RIGHT, BTN_MIDDLE.
    static let buttonCodes: [UInt16] = [0x110, 0x111, 0x112]

    // MARK: - La configuration PCI

    /// virtio 1.0 : 0x1040 plus le numéro du périphérique, 18 pour l'entrée.
    static let identity: UInt32 = 0x1052_1AF4
    /// Révision 1 (« moderne ») ; classe 09, sous-classe 80 : « entrée, autre ».
    static let classAndRevision: UInt32 = 0x0980_0001
    /// La taille de la BAR0 : quatre pages, une par structure.
    public static let barBytes: UInt64 = 0x4000

    static let commonOffset: UInt64 = 0x0000
    static let interruptOffset: UInt64 = 0x1000
    static let deviceOffset: UInt64 = 0x2000
    static let notifyOffset: UInt64 = 0x3000
    /// L'écart entre deux sonnettes : `queue_notify_off` fois ce nombre.
    static let notifyMultiplier: UInt32 = 4

    /// L'emplacement sur le bus, et la ligne d'interruption : la 10, libre
    /// (le disque, le second disque, la carte réseau, le port série, le
    /// clavier et la souris ont les leurs).
    public static let slot: UInt32 = 7
    public static let line: UInt8 = 10

    /// Où commence la liste des capacités dans l'espace de configuration.
    static let firstCapability: UInt32 = 0x40

    /// L'adresse de la BAR0, que le micrologiciel ou le noyau choisit.
    public private(set) var base: UInt64 = 0
    public private(set) var command: UInt16 = 0
    var sizing = false
    public var interruptLine: UInt8

    public init(interruptLine: UInt8) {
        self.interruptLine = interruptLine
    }

    /// **La liste des capacités**, telle que le pilote la parcourt depuis
    /// le pointeur 0x34 : une par structure, seize octets chacune (vingt pour
    /// les sonnettes, qui ajoutent leur multiplicateur), chaînées.
    ///
    /// Chaque entrée : `cap_vndr` (0x09, « propre au vendeur »), le suivant,
    /// la longueur, le type (1 commun, 2 sonnettes, 3 ISR, 4 périphérique),
    /// la BAR, puis le décalage et la longueur dans cette BAR.
    static let capabilities: [(type: UInt8, offset: UInt64, length: UInt32)] = [
        (1, commonOffset, 0x38),
        (3, interruptOffset, 4),
        (4, deviceOffset, 0x88),
        (2, notifyOffset, 2 * notifyMultiplier),
    ]

    /// Le mot de configuration à `register` (aligné sur quatre).
    public func configuration(_ register: UInt32) -> UInt32 {
        switch register {
        case 0x00: return Self.identity
        // L'état dit « liste de capacités présente » (bit 4 du mot d'état).
        case 0x04: return UInt32(command) | (1 << 20)
        case 0x08: return Self.classAndRevision
        case 0x0C: return 0
        case 0x10:
            if sizing { return ~UInt32(truncatingIfNeeded: Self.barBytes - 1) }
            return UInt32(truncatingIfNeeded: base)
        case 0x2C: return 0x1100_1AF4
        case 0x34: return Self.firstCapability
        case 0x3C: return UInt32(interruptLine) | (1 << 8)
        default:
            return Self.capabilityWord(register) ?? 0
        }
    }

    /// Un mot de la liste des capacités, ou nil hors de la liste.
    static func capabilityWord(_ register: UInt32) -> UInt32? {
        var start = firstCapability
        for (index, entry) in capabilities.enumerated() {
            let length: UInt32 = entry.type == 2 ? 20 : 16
            guard register >= start, register < start + length else {
                start += length
                continue
            }
            let next = index + 1 < capabilities.count ? start + length : 0
            switch register - start {
            case 0: return 0x09 | next << 8 | length << 16 | UInt32(entry.type) << 24
            case 4: return 0     // BAR0, et le remplissage
            case 8: return UInt32(entry.offset)
            case 12: return entry.length
            default: return notifyMultiplier  // la seule entrée de vingt octets
            }
        }
        return nil
    }

    /// Une écriture de configuration, déjà recomposée en un mot.
    public func writeConfiguration(_ register: UInt32, _ value: UInt32) {
        switch register {
        case 0x04: command = UInt16(truncatingIfNeeded: value)
        case 0x10:
            if value == 0xFFFF_FFFF {
                sizing = true
            } else {
                sizing = false
                base = UInt64(value) & ~(Self.barBytes - 1)
            }
        case 0x3C: interruptLine = UInt8(truncatingIfNeeded: value)
        default: break
        }
    }

    /// Le décalage dans la BAR0, ou nil si l'adresse est ailleurs ou que la
    /// mémoire du périphérique n'est pas encore allumée.
    public func registerOffset(_ address: UInt64, _ width: Int) -> UInt64? {
        guard base != 0, command & 0x02 != 0, address >= base else { return nil }
        let offset = address &- base
        return offset &+ UInt64(width) <= Self.barBytes ? offset : nil
    }

    // MARK: - Les registres communs

    struct Queue: Equatable {
        var size: UInt16 = VirtioTablet.queueSize
        var enabled = false
        var descriptors: UInt64 = 0
        var available: UInt64 = 0
        var used: UInt64 = 0
        var nextAvailable: UInt16 = 0
        var nextUsed: UInt16 = 0
    }

    static let queueSize: UInt16 = 64
    static let eventQueue = 0
    static let statusQueue = 1
    /// VIRTIO_F_VERSION_1, le bit 32 : le seul offert, le seul exigé.
    static let versionFeature: UInt64 = 1 << 32

    var queues = [Queue(), Queue()]
    var queueSelect: UInt16 = 0
    var deviceFeatureSelect: UInt32 = 0
    var driverFeatureSelect: UInt32 = 0
    public private(set) var driverFeatures: UInt64 = 0
    public private(set) var status: UInt8 = 0
    @exclusivity(unchecked)
    public private(set) var interruptStatus: UInt8 = 0
    public var interrupting: Bool { interruptStatus != 0 }

    /// Le choix de la configuration du périphérique (`select`, `subsel`).
    var select: UInt8 = 0
    var subselect: UInt8 = 0

    public func read(_ offset: UInt64, _ width: Int) -> UInt64 {
        switch offset {
        case Self.commonOffset..<(Self.commonOffset + 0x38):
            return readCommon(offset - Self.commonOffset, width)
        case Self.interruptOffset:
            // Lire l'ISR l'efface : c'est l'accusé de réception de l'INTx.
            let value = interruptStatus
            interruptStatus = 0
            if value & 1 != 0 {
                lock.lock()
                acknowledged = true
                lock.unlock()
            }
            return UInt64(value)
        case Self.deviceOffset..<(Self.deviceOffset + 0x88):
            let bytes = deviceConfiguration()
            let start = Int(offset - Self.deviceOffset)
            return (0..<width).reduce(UInt64(0)) { value, index in
                let at = start + index
                return value | UInt64(at < bytes.count ? bytes[at] : 0) << (8 * UInt64(index))
            }
        default:
            return 0
        }
    }

    public func write(_ offset: UInt64, _ width: Int, _ value: UInt64, _ memory: GuestMemory) {
        switch offset {
        case Self.commonOffset..<(Self.commonOffset + 0x38):
            writeCommon(offset - Self.commonOffset, width, value)
        case Self.deviceOffset:
            select = UInt8(truncatingIfNeeded: value)
            if width > 1 { subselect = UInt8(truncatingIfNeeded: value >> 8) }
        case Self.deviceOffset + 1:
            subselect = UInt8(truncatingIfNeeded: value)
        case Self.notifyOffset..<(Self.notifyOffset + 2 * UInt64(Self.notifyMultiplier)):
            // La sonnette d'une file : des tampons neufs. La file d'état
            // porte les voyants du clavier, qu'il n'y a pas : on les rend.
            let which = Int((offset - Self.notifyOffset) / UInt64(Self.notifyMultiplier))
            // **À la dernière heure connue** : sans elle, la sonnette rendait
            // tout d'un coup, retenu compris, et l'appui et la relâche d'un
            // toucher arrivaient encore à 27 µs d'écart.
            if which == Self.statusQueue { drainStatus(memory) } else { deliver(memory, now: clock, fromDoorbell: true) }
        default:
            break
        }
    }

    func readCommon(_ offset: UInt64, _ width: Int) -> UInt64 {
        let queue = queues[Int(min(queueSelect, 1))]
        let validQueue = queueSelect < 2
        let value: UInt64
        switch offset {
        case 0x00: value = UInt64(deviceFeatureSelect)
        case 0x04: value = deviceFeatureSelect == 1 ? Self.versionFeature >> 32 : 0
        case 0x08: value = UInt64(driverFeatureSelect)
        case 0x0C: value = (driverFeatures >> (32 * UInt64(driverFeatureSelect & 1))) & 0xFFFF_FFFF
        case 0x10: value = 0xFFFF                    // msix_config : aucun vecteur
        case 0x12: value = 2                         // num_queues
        case 0x14: value = UInt64(status)
        case 0x15: value = 0                         // config_generation : rien ne change
        case 0x16: value = UInt64(queueSelect)
        case 0x18: value = validQueue ? UInt64(queue.size) : 0
        case 0x1A: value = 0xFFFF                    // queue_msix_vector
        case 0x1C: value = validQueue && queue.enabled ? 1 : 0
        case 0x1E: value = validQueue ? UInt64(queueSelect) : 0  // queue_notify_off
        case 0x20: value = queue.descriptors
        case 0x24: value = queue.descriptors >> 32
        case 0x28: value = queue.available
        case 0x2C: value = queue.available >> 32
        case 0x30: value = queue.used
        case 0x34: value = queue.used >> 32
        default: value = 0
        }
        return width >= 8 ? value : value & ((1 << (8 * UInt64(width))) - 1)
    }

    func writeCommon(_ offset: UInt64, _ width: Int, _ value: UInt64) {
        let selected = Int(queueSelect)
        let validQueue = selected < 2
        func setLow(_ field: inout UInt64) { field = field & ~0xFFFF_FFFF | value & 0xFFFF_FFFF }
        func setHigh(_ field: inout UInt64) { field = field & 0xFFFF_FFFF | (value & 0xFFFF_FFFF) << 32 }
        switch offset {
        case 0x00: deviceFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x08: driverFeatureSelect = UInt32(truncatingIfNeeded: value)
        case 0x0C:
            let shift = 32 * UInt64(driverFeatureSelect & 1)
            // Le pilote ne peut accepter que ce qui est offert.
            let offered = (Self.versionFeature >> shift) & 0xFFFF_FFFF
            driverFeatures = driverFeatures & ~(0xFFFF_FFFF << shift) | (value & offered) << shift
        case 0x14:
            status = UInt8(truncatingIfNeeded: value)
            if status == 0 { reset() }
        case 0x16: queueSelect = UInt16(truncatingIfNeeded: value)
        case 0x18 where validQueue:
            // Une taille plus petite, puissance de deux, est permise.
            let size = UInt16(truncatingIfNeeded: value)
            if size != 0, size <= Self.queueSize, size & (size - 1) == 0 { queues[selected].size = size }
        case 0x1C where validQueue:
            queues[selected].enabled = value & 1 != 0
        case 0x20 where validQueue:
            if width >= 8 { queues[selected].descriptors = value } else { setLow(&queues[selected].descriptors) }
        case 0x24 where validQueue: setHigh(&queues[selected].descriptors)
        case 0x28 where validQueue:
            if width >= 8 { queues[selected].available = value } else { setLow(&queues[selected].available) }
        case 0x2C where validQueue: setHigh(&queues[selected].available)
        case 0x30 where validQueue:
            if width >= 8 { queues[selected].used = value } else { setLow(&queues[selected].used) }
        case 0x34 where validQueue: setHigh(&queues[selected].used)
        default: break
        }
    }

    func reset() {
        queues = [Queue(), Queue()]
        queueSelect = 0
        driverFeatures = 0
        status = 0
        interruptStatus = 0
        select = 0
        subselect = 0
        lock.lock()
        pending.removeAll()
        deliveredButtons = 0
        lastChangedButtons = false
        acknowledged = true
        holdingSince = nil
        packetLeft = 0
        lock.unlock()
    }

    // MARK: - La configuration du périphérique

    /// `virtio_input_config` pour le couple (`select`, `subsel`) courant :
    /// les deux octets de choix, la taille, cinq réservés, puis la réponse.
    /// Une question sans réponse a une taille nulle.
    func deviceConfiguration() -> [UInt8] {
        let answer = Self.answer(select: select, subselect: subselect)
        return [select, subselect, UInt8(answer.count), 0, 0, 0, 0, 0] + answer
    }

    static func answer(select: UInt8, subselect: UInt8) -> [UInt8] {
        switch (select, subselect) {
        case (0x01, _):                                      // VIRTIO_INPUT_CFG_ID_NAME
            return Array(name.utf8)
        case (0x03, _):                                      // VIRTIO_INPUT_CFG_ID_DEVIDS
            // BUS_VIRTUAL, puis le vendeur, le produit et la version de QEMU.
            return [0x06, 0x00, 0xF4, 0x1A, 0x03, 0x00, 0x01, 0x00]
        case (0x11, UInt8(truncatingIfNeeded: key)):         // EV_BITS, EV_KEY
            return bitmap(buttonCodes)
        case (0x11, UInt8(truncatingIfNeeded: relative)):    // EV_BITS, EV_REL
            return bitmap([wheel])
        case (0x11, UInt8(truncatingIfNeeded: absolute)):    // EV_BITS, EV_ABS
            return bitmap([axisX, axisY])
        case (0x12, UInt8(truncatingIfNeeded: axisX)), (0x12, UInt8(truncatingIfNeeded: axisY)):
            // VIRTIO_INPUT_CFG_ABS_INFO : min, max, fuzz, flat, res.
            return [UInt32(0), axisMaximum, 0, 0, 0].flatMap { word in
                (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * UInt32($0))) }
            }
        default:
            return []
        }
    }

    /// Un champ de bits, octet de poids faible d'abord, assez long pour le
    /// plus grand code.
    static func bitmap(_ codes: [UInt16]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(codes.max() ?? 0) / 8 + 1)
        for code in codes { bytes[Int(code) / 8] |= 1 << (code % 8) }
        return bytes
    }

    // MARK: - Ce qu'on sauve

    /// **L'état que le pilote a posé** : la BAR, l'état, les fonctions, les
    /// files et où elles en sont. Sans lui, une machine reprise garderait un
    /// pilote qui croit ses files prêtes devant un périphérique remis à zéro,
    /// et le doigt ne pointerait plus rien. Les événements en attente ne
    /// sont pas gardés : ce sont des gestes d'avant.
    func save(into writer: inout Snapshot.Writer) {
        writer.u64(base)
        writer.u32(UInt32(command))
        writer.u32(UInt32(interruptLine))
        writer.u32(UInt32(status))
        writer.u64(driverFeatures)
        writer.u32(UInt32(queueSelect))
        writer.u32(UInt32(select) | UInt32(subselect) << 8)
        writer.u32(UInt32(interruptStatus))
        for queue in queues {
            writer.u32(UInt32(queue.size) | (queue.enabled ? 1 << 16 : 0))
            writer.u64(queue.descriptors)
            writer.u64(queue.available)
            writer.u64(queue.used)
            writer.u32(UInt32(queue.nextAvailable) | UInt32(queue.nextUsed) << 16)
        }
    }

    /// Lit l'état, le vérifie, et ne l'applique qu'entier.
    func restore(from reader: inout Snapshot.Reader) throws {
        let base = try reader.u64()
        let command = UInt16(truncatingIfNeeded: try reader.u32())
        let line = UInt8(truncatingIfNeeded: try reader.u32())
        let status = UInt8(truncatingIfNeeded: try reader.u32())
        let features = try reader.u64()
        let select = UInt16(truncatingIfNeeded: try reader.u32())
        let choice = try reader.u32()
        let pending = UInt8(truncatingIfNeeded: try reader.u32())
        var restored: [Queue] = []
        for _ in 0..<2 {
            let word = try reader.u32()
            var queue = Queue()
            queue.size = UInt16(truncatingIfNeeded: word)
            queue.enabled = word >> 16 & 1 != 0
            queue.descriptors = try reader.u64()
            queue.available = try reader.u64()
            queue.used = try reader.u64()
            let positions = try reader.u32()
            queue.nextAvailable = UInt16(truncatingIfNeeded: positions)
            queue.nextUsed = UInt16(truncatingIfNeeded: positions >> 16)
            guard queue.size != 0, queue.size <= Self.queueSize, queue.size & (queue.size - 1) == 0 else {
                throw Snapshot.Failure.corrupt
            }
            restored.append(queue)
        }
        guard base & (Self.barBytes - 1) == 0, base < 1 << 32, features & ~Self.versionFeature == 0 else {
            throw Snapshot.Failure.corrupt
        }
        self.base = base
        self.command = command
        interruptLine = line
        self.status = status
        driverFeatures = features
        queueSelect = select
        self.select = UInt8(truncatingIfNeeded: choice)
        subselect = UInt8(truncatingIfNeeded: choice >> 8)
        interruptStatus = pending
        queues = restored
    }

    // MARK: - Les événements

    /// Un `virtio_input_event` : type, code, valeur, huit octets.
    struct Event: Equatable {
        var type: UInt16
        var code: UInt16
        var value: UInt32

        var bytes: [UInt8] {
            [UInt8(truncatingIfNeeded: type), UInt8(truncatingIfNeeded: type >> 8),
             UInt8(truncatingIfNeeded: code), UInt8(truncatingIfNeeded: code >> 8)]
                + (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
        }
    }

    /// **Ce que l'application a demandé**, en attente d'un tampon de
    /// l'invité. Écrit depuis l'interface, lu par le fil de la machine : sous
    /// verrou. Borné : une machine qui ne lit plus ses événements ne fait
    /// pas grossir l'application.
    var pending: [Event] = []
    let lock = NSLock()
    static let pendingLimit = 1024

    /// **Un toucher** : la position, rapportée à l'écran (0 à 1 sur chaque
    /// axe, rognée), et l'état des trois boutons (bit 0 gauche, 1 droit,
    /// 2 milieu). Un paquet par appel, terminé par `SYN_REPORT`.
    public func point(x: Double, y: Double, buttons: UInt8) {
        func axis(_ fraction: Double) -> UInt32 {
            UInt32((min(max(fraction, 0), 1) * Double(Self.axisMaximum)).rounded())
        }
        var packet = [Event(type: Self.absolute, code: Self.axisX, value: axis(x)),
                      Event(type: Self.absolute, code: Self.axisY, value: axis(y))]
        for (bit, code) in Self.buttonCodes.enumerated() {
            packet.append(Event(type: Self.key, code: code, value: UInt32(buttons >> bit & 1)))
        }
        packet.append(Event(type: Self.synchronize, code: 0, value: 0))
        enqueue(packet)
    }

    /// **La molette** : des crans, positifs vers le haut.
    public func scroll(_ notches: Int32) {
        enqueue([Event(type: Self.relative, code: Self.wheel, value: UInt32(bitPattern: notches)),
                 Event(type: Self.synchronize, code: 0, value: 0)])
    }

    func enqueue(_ packet: [Event]) {
        lock.lock()
        defer { lock.unlock() }
        // Un paquet entier ou rien : un SYN perdu collerait deux gestes.
        guard pending.count + packet.count <= Self.pendingLimit else { return }
        pending += packet
    }

    /// **Le pilote l'a prise** : DRIVER_OK posé et la file des événements
    /// active. Avant, ou sur un système sans `virtio_input`, un toucher ne
    /// mènerait nulle part, et l'application garde la souris PS/2.
    public var isReady: Bool { status & 0x04 != 0 && queues[Self.eventQueue].enabled }

    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// **Le rythme d'un doigt autour des boutons.** Un appui, puis le
    /// glissé, puis la relâche, rendus d'un coup à l'invité, portent la même
    /// heure : xfwm4 voit l'appui sur la barre de titre, demande où en est le
    /// bouton, et le trouve déjà relâché — la fenêtre ne bouge pas. Un paquet
    /// qui suit un changement de boutons attend donc `buttonTicks` (30 ms du
    /// PIT, l'appui du clavier) : la relâche d'un toucher, le premier pas
    /// d'un glissé. Le reste passe sans attendre — l'appui lui-même, sans
    /// latence ajoutée, et les déplacements, qui retenus s'entasseraient dès
    /// que la machine prend du retard sur le doigt.
    ///
    /// **Les 30 ms comptent depuis que l'invité a lu**, pas depuis le dépôt.
    /// Compté depuis le dépôt, une machine endormie sautait jusqu'au
    /// battement suivant — jusqu'à 55 ms — et trouvait l'appui *et* la
    /// relâche dans ses tampons : evdev les datait à 17 µs d'écart. L'ISR lu,
    /// `vp_interrupt` vide la file dans la foulée ; c'est de là que l'écart
    /// part.
    public static let buttonTicks: UInt64 = 35_795
    var deliveredButtons: UInt8 = 0
    var lastChangedButtons = false
    /// La dernière heure qu'on a donnée à `deliver`, pour la sonnette, qui
    /// n'en a pas. Sans aucune (les tests), rien n'est retenu.
    var clock: UInt64?
    /// L'invité a lu l'ISR depuis le dernier dépôt.
    var acknowledged = true
    /// L'heure où l'attente a commencé : le premier passage après la lecture.
    var holdingSince: UInt64?
    /// Ce qui reste à rendre du paquet commencé, faute de tampons.
    var packetLeft = 0

    /// Les boutons que porte un paquet, ou ceux d'avant s'il n'en dit rien
    /// (la molette).
    func buttons(of packet: ArraySlice<Event>) -> UInt8 {
        var buttons = deliveredButtons
        for event in packet where event.type == Self.key {
            guard let bit = Self.buttonCodes.firstIndex(of: event.code) else { continue }
            if event.value != 0 { buttons |= 1 << bit } else { buttons &= ~(1 << bit) }
        }
        return buttons
    }

    /// **Les événements en attente, dans les tampons que l'invité a
    /// offerts**, tant qu'il y en a. Chaque tampon reçoit un événement. Avec
    /// `now` (le PIT de la machine), au rythme d'un doigt ; sans, tout part.
    public func deliver(_ memory: GuestMemory, now: UInt64? = nil, fromDoorbell: Bool = false) {
        guard status & 0x04 != 0 else { return }  // DRIVER_OK
        lock.lock()
        defer { lock.unlock() }
        if let now, !fromDoorbell { clock = now }
        while !pending.isEmpty {
            // Un paquet qui commence en tête de file : peut-il partir ? Un
            // paquet commencé, lui, finit sans attendre.
            if packetLeft == 0 {
                let end = (pending.firstIndex { $0.type == Self.synchronize } ?? pending.count - 1) + 1
                let buttons = buttons(of: pending[..<end])
                let changes = buttons != deliveredButtons
                if let now, lastChangedButtons {
                    guard acknowledged else { return }
                    // L'heure de la sonnette est celle d'un passage ancien :
                    // elle ne commence pas l'attente, elle la laisse au PIT.
                    if holdingSince == nil, !fromDoorbell { holdingSince = now }
                    guard let since = holdingSince, now >= since &+ Self.buttonTicks else { return }
                }
                guard let next = nextBuffer(Self.eventQueue, memory) else { return }
                packetLeft = end
                lastChangedButtons = changes
                deliveredButtons = buttons
                acknowledged = false
                holdingSince = nil
                deliverOne(next, memory)
            } else {
                guard let next = nextBuffer(Self.eventQueue, memory) else { return }
                deliverOne(next, memory)
            }
            packetLeft -= 1
        }
    }

    private func deliverOne(_ next: (UInt16, VirtioBlock.Descriptor), _ memory: GuestMemory) {
        let (head, buffer) = next
        do {  // sous le verrou de `deliver`
            let event = pending.removeFirst()
            if buffer.writable, buffer.length >= 8 {
                memory.copyIn(event.bytes, at: buffer.address)
                complete(Self.eventQueue, head, length: 8, memory)
            } else {
                complete(Self.eventQueue, head, length: 0, memory)
            }
        }
    }

    /// La file d'état : les voyants que le pilote envoie. Rendus tels quels.
    func drainStatus(_ memory: GuestMemory) {
        while let (head, _) = nextBuffer(Self.statusQueue, memory) {
            complete(Self.statusQueue, head, length: 0, memory)
        }
    }

    /// Le prochain tampon offert dans une file : la tête de chaîne et son
    /// premier descripteur, qui suffit à un événement de huit octets.
    func nextBuffer(_ which: Int, _ memory: GuestMemory) -> (UInt16, VirtioBlock.Descriptor)? {
        let queue = queues[which]
        guard queue.enabled, queue.descriptors != 0,
              let published = try? memory.read(queue.available &+ 2, 2),
              UInt16(truncatingIfNeeded: published) != queue.nextAvailable else { return nil }
        let slot = UInt64(queue.nextAvailable % queue.size)
        guard let entry = try? memory.read(queue.available &+ 4 &+ slot &* 2, 2) else { return nil }
        queues[which].nextAvailable &+= 1
        let head = UInt16(truncatingIfNeeded: entry) % queue.size
        let at = queue.descriptors &+ UInt64(head) &* 16
        guard let address = try? memory.read(at, 8), let length = try? memory.read(at &+ 8, 4),
              let flags = try? memory.read(at &+ 12, 2), let next = try? memory.read(at &+ 14, 2)
        else { return nil }
        return (head, VirtioBlock.Descriptor(
            address: address, length: UInt32(truncatingIfNeeded: length),
            flags: UInt16(truncatingIfNeeded: flags), next: UInt16(truncatingIfNeeded: next)))
    }

    func complete(_ which: Int, _ head: UInt16, length: UInt32, _ memory: GuestMemory) {
        let queue = queues[which]
        let slot = UInt64(queue.nextUsed % queue.size)
        try? memory.write(queue.used &+ 4 &+ slot &* 8, 4, UInt64(head))
        try? memory.write(queue.used &+ 8 &+ slot &* 8, 4, UInt64(length))
        queues[which].nextUsed &+= 1
        try? memory.write(queue.used &+ 2, 2, UInt64(queues[which].nextUsed))
        interruptStatus |= 1
    }
}
