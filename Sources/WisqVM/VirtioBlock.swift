import Foundation

/// Un disque virtio-mmio : le transport, la file, et le bloc.
///
/// **Pourquoi virtio-mmio et pas virtio-pci.** Un disque PCI demande d'abord
/// un bus PCI — l'espace de configuration par les ports 0xCF8/0xCFC, des BAR
/// à placer, une table d'interruptions —, et tout cela avant le premier
/// secteur lu. Le transport MMIO se passe de bus : le noyau prend l'adresse
/// et la ligne d'interruption sur sa ligne de commande
/// (`virtio_mmio.device=0x200@0xd0000000:5`), et le pilote est le même
/// ensuite. C'est une centaine de lignes contre un millier, pour le même
/// disque.
///
/// **Il ne s'appelait pas comme ça.** C'était `X86VirtioBlock`, par accident
/// d'histoire : il a été écrit pour la machine PC et rien d'autre n'en avait
/// besoin. Le transport MMIO n'a pourtant rien de propre au x86 — c'est la
/// machine qui choisit où poser la fenêtre et par quelle ligne prévenir, et
/// `Placement` porte ce choix. La machine rv32 emploie exactement ce
/// périphérique-ci.
///
/// **Ce qui est implémenté, et ce qui ne l'est pas.** La version 2 du
/// transport (« moderne ») : le pilote annonce `VIRTIO_F_VERSION_1` et rien
/// d'autre, donc pas de descripteurs indirects, pas d'index d'événement, pas
/// de `FLUSH` ni de topologie. Une seule file, les requêtes traitées à la
/// notification et dans l'ordre. C'est ce qu'il faut pour qu'un noyau Linux
/// voie `/dev/vda` et le lise ; le reste viendra quand quelque chose le
/// demandera.
/// La mémoire de l'invité, vue par un périphérique.
///
/// **Le strict nécessaire, et c'est ce qui rend le périphérique partageable.**
/// Un disque virtio ne fait que deux choses avec la mémoire : y lire les
/// descripteurs que le pilote a posés, et y écrire les secteurs demandés. Il
/// n'a besoin ni de pagination, ni de fenêtres d'entrée-sortie, ni de savoir
/// à quelle machine il appartient. `VirtioBlock` prenait un `X86Memory` en
/// paramètre, ce qui le clouait à une seule des deux machines pour une raison
/// qui n'existait pas.
///
/// Les adresses sont **physiques et absolues** : celles que le pilote a
/// écrites dans ses descripteurs. C'est à la machine de savoir où sa RAM
/// commence — la machine rv32 la place à 0x8000_0000, le PC à zéro.
public protocol GuestMemory: AnyObject {
    func read(_ address: UInt64, _ width: Int) throws -> UInt64
    func write(_ address: UInt64, _ width: Int, _ value: UInt64) throws
}

extension X86Memory: GuestMemory {}

public final class VirtioBlock: @unchecked Sendable {
    /// Où une machine pose ce périphérique, et par quelle ligne elle prévient.
    ///
    /// **C'est la machine qui décide, pas le périphérique.** Les deux machines
    /// de wisq le placent ailleurs et le signalent autrement : le PC par une
    /// ligne du 8259, la machine rv32 par le bit 11 de `mip`, faute de PLIC.
    /// Le transport, lui, est le même octet pour octet.
    public struct Placement: Equatable, Sendable {
        public let base: UInt64
        public let span: UInt64
        /// Le numéro que la machine emploie pour signaler : une ligne d'IRQ
        /// sur le PC, un bit de `mip` sur la machine rv32.
        public let interruptLine: UInt8

        public init(base: UInt64, span: UInt64, interruptLine: UInt8) {
            self.base = base
            self.span = span
            self.interruptLine = interruptLine
        }

        public func contains(_ address: UInt64) -> Bool {
            address >= base && address < base + span
        }
    }

    /// La fenêtre de la machine PC. Ces trois nombres sont **sa ligne de
    /// commande** : les changer ici sans la changer là ferait chercher le
    /// pilote dans le vide.
    public static let pc = Placement(base: 0xD000_0000, span: 0x200, interruptLine: 5)

    /// Celle de la machine rv32.
    ///
    /// Posée juste après l'UART, à 0x1000_1000, là où la carte `virt` de QEMU
    /// met ses propres périphériques virtio — un noyau construit pour elle
    /// tombe donc sur une adresse qui ne le surprend pas. La « ligne » est le
    /// bit 11 de `mip`, l'interruption externe machine : cette carte n'a pas
    /// de PLIC, et le nœud de l'arbre désigne directement le contrôleur du
    /// hart, comme le CLINT le fait déjà.
    public static let riscv = Placement(base: 0x1000_1000, span: 0x200, interruptLine: 11)

    /// Là où vivent les octets : en mémoire, ou dans un fichier avec sa
    /// couche d'écriture. Le périphérique ne sait pas lequel, et n'a pas à le
    /// savoir : il lit et écrit des morceaux, c'est tout.
    public private(set) var store: DiskStore

    public init(store: DiskStore) {
        self.store = store
    }

    /// La forme d'avant, et celle des tests : l'image entière en mémoire.
    public convenience init(image: [UInt8]) {
        self.init(store: MemoryDiskStore(image: image))
    }

    /// Le contenu du disque, secteur par secteur de 512 octets — relu depuis
    /// le store, quel qu'il soit. Pour les tests et les mesures ; un disque de
    /// six gigaoctets ne se demande pas comme ça.
    public var image: [UInt8] {
        store.read(at: 0, count: Int(store.sectors) * 512) ?? []
    }

    public var sectors: UInt64 { store.sectors }

    /// Pousser ce que l'invité a écrit jusqu'au stockage durable.
    public func flush() { store.flush() }

    // MARK: - Les registres du transport

    static let magic: UInt32 = 0x7472_6976  // « virt », en petit-boutiste
    static let version: UInt32 = 2
    static let blockDevice: UInt32 = 2
    static let vendor: UInt32 = 0x7773_7169  // « wisq »
    /// Le seul bit annoncé : la version 1 du protocole. Sans lui, un pilote
    /// moderne refuse le périphérique ; avec d'autres, il faudrait les tenir.
    static let versionOneBit = 32

    var deviceFeaturesSelect: UInt32 = 0
    var driverFeaturesSelect: UInt32 = 0
    public private(set) var driverFeatures: UInt64 = 0
    public private(set) var status: UInt32 = 0
    var queueSelect: UInt32 = 0
    public private(set) var queueSize: UInt32 = 0
    public private(set) var queueReady: UInt32 = 0
    var descriptorTable: UInt64 = 0
    var availableRing: UInt64 = 0
    var usedRing: UInt64 = 0
    public private(set) var interruptStatus: UInt32 = 0
    /// L'index de la prochaine entrée à lire dans l'anneau des disponibles.
    var nextAvailable: UInt16 = 0
    var nextUsed: UInt16 = 0
    /// Combien de requêtes ont été servies, et combien ont échoué. Un
    /// périphérique qui refuse tout et un périphérique que personne n'appelle
    /// se lisent pareil sans ces deux nombres.
    public private(set) var served: UInt64 = 0
    public private(set) var refused: UInt64 = 0

    // MARK: - La forme ancienne, par les ports

    /// **Le même périphérique, vu par une porte plus vieille.** La forme
    /// ancienne de virtio-pci ne fait pas de MMIO du tout : elle vit dans une
    /// fenêtre de ports, et le noyau y écrit le **numéro de page** de sa file
    /// plutôt que trois adresses. Les deux anneaux qui suivent se calculent à
    /// partir de là — c'est `vring_init`, et se tromper d'un octet fait lire
    /// au périphérique un anneau que personne n'a écrit.
    ///
    /// Tout le reste — les descripteurs, les requêtes, les refus — est
    /// exactement le même code.
    public private(set) var queuePageNumber: UInt32 = 0

    /// Là où les trois anneaux tombent, pour une page et une taille données.
    static func rings(pageNumber: UInt32, size: UInt32) -> (UInt64, UInt64, UInt64) {
        let descriptors = UInt64(pageNumber) &* 4096
        let available = descriptors &+ UInt64(size) &* 16
        let after = available &+ 6 &+ UInt64(size) &* 2
        let used = (after &+ 4095) & ~UInt64(4095)
        return (descriptors, available, used)
    }

    public func readPort(_ offset: UInt16, _ width: Int) -> UInt64 {
        switch offset {
        case 0x00: return 0  // aucune fonction optionnelle annoncée
        case 0x08: return UInt64(queuePageNumber)
        case 0x0C: return UInt64(Self.queueLimit)
        case 0x12: return UInt64(status)
        case 0x13:
            // Lire l'état d'interruption l'acquitte : c'est la règle de la
            // forme ancienne, et le pilote ne fait rien d'autre pour ça.
            let pending = interruptStatus
            interruptStatus = 0
            return UInt64(pending)
        case 0x14...0x1B:
            let field = UInt64(offset - 0x14)
            var value: UInt64 = 0
            for byte in 0..<UInt64(width) where field + byte < 8 {
                value |= ((sectors >> (8 * (field + byte))) & 0xFF) << (8 * byte)
            }
            return value
        default: return 0
        }
    }

    public func writePort(_ offset: UInt16, _ width: Int, _ value: UInt64, _ memory: GuestMemory) {
        switch offset {
        case 0x04: driverFeatures = value
        case 0x08:
            queuePageNumber = UInt32(truncatingIfNeeded: value)
            queueSize = queuePageNumber == 0 ? 0 : Self.queueLimit
            queueReady = queuePageNumber == 0 ? 0 : 1
            (descriptorTable, availableRing, usedRing) =
                Self.rings(pageNumber: queuePageNumber, size: Self.queueLimit)
            nextAvailable = 0
            nextUsed = 0
        case 0x0E: queueSelect = UInt32(truncatingIfNeeded: value)
        case 0x10: if queueReady != 0 { serve(memory) }
        case 0x12:
            status = UInt32(truncatingIfNeeded: value) & 0xFF
            if status == 0 { reset() }
        default: break
        }
    }

    /// La file a une taille maximale, et le pilote ne peut pas en demander
    /// plus. Cent vingt-huit descripteurs suffisent très largement à un
    /// disque qui sert une requête à la fois.
    static let queueLimit: UInt32 = 128

    public func read(_ offset: UInt64, _ width: Int) -> UInt64 {
        // L'espace de configuration : la capacité, en secteurs de 512 octets.
        if offset >= 0x100 {
            let field = offset - 0x100
            guard field < 8 else { return 0 }
            let capacity = sectors
            var value: UInt64 = 0
            for byte in 0..<UInt64(width) where field + byte < 8 {
                value |= ((capacity >> (8 * (field + byte))) & 0xFF) << (8 * byte)
            }
            return value
        }
        switch offset {
        case 0x000: return UInt64(Self.magic)
        case 0x004: return UInt64(Self.version)
        case 0x008: return UInt64(Self.blockDevice)
        case 0x00C: return UInt64(Self.vendor)
        case 0x010:
            // Les bits 0 à 31, puis 32 à 63, selon ce que le pilote a demandé.
            return deviceFeaturesSelect == 1 ? 1 : 0
        case 0x034: return UInt64(Self.queueLimit)
        case 0x044: return UInt64(queueReady)
        case 0x060: return UInt64(interruptStatus)
        case 0x070: return UInt64(status)
        case 0x0FC: return 0  // la configuration ne change jamais
        default: return 0
        }
    }

    public func write(_ offset: UInt64, _ width: Int, _ value: UInt64, _ memory: GuestMemory) {
        let word = UInt32(truncatingIfNeeded: value)
        switch offset {
        case 0x014: deviceFeaturesSelect = word
        case 0x020:
            let shift: UInt64 = driverFeaturesSelect == 1 ? 32 : 0
            driverFeatures |= UInt64(word) << shift
        case 0x024: driverFeaturesSelect = word
        case 0x030: queueSelect = word
        case 0x038: queueSize = min(word, Self.queueLimit)
        case 0x044: queueReady = word
        case 0x050: if queueReady != 0 { serve(memory) }
        case 0x064: interruptStatus &= ~word
        case 0x070:
            status = word
            // Zéro remet tout à plat : c'est la réinitialisation.
            if word == 0 { reset() }
        case 0x080: descriptorTable = (descriptorTable & ~0xFFFF_FFFF) | UInt64(word)
        case 0x084: descriptorTable = (descriptorTable & 0xFFFF_FFFF) | (UInt64(word) << 32)
        case 0x090: availableRing = (availableRing & ~0xFFFF_FFFF) | UInt64(word)
        case 0x094: availableRing = (availableRing & 0xFFFF_FFFF) | (UInt64(word) << 32)
        case 0x0A0: usedRing = (usedRing & ~0xFFFF_FFFF) | UInt64(word)
        case 0x0A4: usedRing = (usedRing & 0xFFFF_FFFF) | (UInt64(word) << 32)
        default: break
        }
    }

    func reset() {
        queueReady = 0
        queueSize = 0
        descriptorTable = 0
        availableRing = 0
        usedRing = 0
        interruptStatus = 0
        nextAvailable = 0
        nextUsed = 0
        driverFeatures = 0
    }

    /// Vrai quand le périphérique demande l'interruption.
    public var interrupting: Bool { interruptStatus != 0 }

    // MARK: - La file

    /// Un descripteur : seize octets, et le suivant s'il y en a un.
    struct Descriptor {
        var address: UInt64
        var length: UInt32
        var flags: UInt16
        var next: UInt16
        var writable: Bool { flags & 2 != 0 }
        var chained: Bool { flags & 1 != 0 }
    }

    func descriptor(_ index: UInt16, _ memory: GuestMemory) throws -> Descriptor {
        let at = descriptorTable &+ UInt64(index) &* 16
        return Descriptor(address: try memory.read(at, 8),
                          length: UInt32(truncatingIfNeeded: try memory.read(at &+ 8, 4)),
                          flags: UInt16(truncatingIfNeeded: try memory.read(at &+ 12, 2)),
                          next: UInt16(truncatingIfNeeded: try memory.read(at &+ 14, 2)))
    }

    /// Servir tout ce que le pilote a rendu disponible.
    ///
    /// Le silence est un mensonge : une file mal formée, un secteur hors du
    /// disque ou un type de requête inconnu se répondent par un **statut**
    /// d'erreur dans le tampon prévu pour ça, jamais en ne répondant rien —
    /// un pilote qui n'a pas de réponse attend pour toujours.
    func serve(_ memory: GuestMemory) {
        guard queueSize > 0, descriptorTable != 0, availableRing != 0, usedRing != 0 else { return }
        guard let head = try? memory.read(availableRing &+ 2, 2) else { return }
        let target = UInt16(truncatingIfNeeded: head)
        while nextAvailable != target {
            let slot = UInt64(nextAvailable % UInt16(queueSize))
            guard let entry = try? memory.read(availableRing &+ 4 &+ slot &* 2, 2) else { return }
            serveOne(UInt16(truncatingIfNeeded: entry), memory)
            nextAvailable &+= 1
        }
    }

    private func serveOne(_ head: UInt16, _ memory: GuestMemory) {
        var written: UInt32 = 0
        var statusByte: UInt8 = 1  // erreur d'entrée-sortie, sauf preuve du contraire

        // La chaîne : l'en-tête, les données, puis l'octet de statut.
        var chain: [Descriptor] = []
        var index = head
        while chain.count <= Int(Self.queueLimit) {
            guard let one = try? descriptor(index, memory) else { break }
            chain.append(one)
            guard one.chained else { break }
            index = one.next
        }
        defer { complete(head, written, statusByte, chain.last, memory) }
        guard chain.count >= 2, let header = chain.first, header.length >= 16,
              let last = chain.last, last.writable, last.length >= 1 else {
            refused &+= 1
            return
        }
        guard let kind = try? memory.read(header.address, 4),
              let sector = try? memory.read(header.address &+ 8, 8) else {
            refused &+= 1
            return
        }
        let payload = chain.dropFirst().dropLast()
        // **Un secteur qui n'existe pas est une erreur, pas des zéros.** Rendre
        // des zéros pour ce qui est au-delà du disque, c'est répondre « voici
        // le contenu » à une question dont la réponse est « il n'y a rien
        // là » : un système de fichiers y lirait un superbloc vide au lieu
        // d'apprendre qu'il a demandé trop loin.
        let span = payload.reduce(UInt64(0)) { $0 + UInt64($1.length) }
        let beyond = (kind == 0 || kind == 1)
            && sector &* 512 &+ span > sectors &* 512
        guard !beyond else { refused &+= 1; return }
        switch kind {
        case 0:  // lecture
            var at = sector &* 512
            for buffer in payload {
                guard buffer.writable,
                      let bytes = store.read(at: at, count: Int(buffer.length)) else {
                    refused &+= 1
                    return
                }
                for (index, value) in bytes.enumerated() {
                    try? memory.write(buffer.address &+ UInt64(index), 1, UInt64(value))
                }
                written &+= buffer.length
                at &+= UInt64(buffer.length)
            }
            statusByte = 0
            served &+= 1
        case 1:  // écriture
            var at = sector &* 512
            for buffer in payload {
                guard !buffer.writable else { refused &+= 1; return }
                var bytes = [UInt8](repeating: 0, count: Int(buffer.length))
                for index in 0..<bytes.count {
                    if let value = try? memory.read(buffer.address &+ UInt64(index), 1) {
                        bytes[index] = UInt8(truncatingIfNeeded: value)
                    }
                }
                guard store.write(at: at, bytes) else { refused &+= 1; return }
                at &+= UInt64(buffer.length)
            }
            statusByte = 0
            served &+= 1
        case 8:  // l'identifiant du disque, vingt octets
            let name = Array("wisq-disk".utf8)
            for buffer in payload where buffer.writable {
                for byte in 0..<UInt64(buffer.length) {
                    let value = byte < UInt64(name.count) ? name[Int(byte)] : 0
                    try? memory.write(buffer.address &+ byte, 1, UInt64(value))
                }
                written &+= buffer.length
            }
            statusByte = 0
            served &+= 1
        default:
            statusByte = 2  // le type n'est pas connu de ce périphérique
            refused &+= 1
        }
    }

    /// Poser le statut, ranger la requête dans l'anneau des servies, et lever
    /// l'interruption.
    private func complete(_ head: UInt16, _ written: UInt32, _ statusByte: UInt8,
                          _ last: Descriptor?, _ memory: GuestMemory) {
        if let last, last.writable, last.length >= 1 {
            try? memory.write(last.address &+ UInt64(last.length) &- 1, 1, UInt64(statusByte))
        }
        guard queueSize > 0 else { return }
        let slot = UInt64(nextUsed % UInt16(queueSize))
        try? memory.write(usedRing &+ 4 &+ slot &* 8, 4, UInt64(head))
        try? memory.write(usedRing &+ 8 &+ slot &* 8, 4, UInt64(written))
        nextUsed &+= 1
        try? memory.write(usedRing &+ 2, 2, UInt64(nextUsed))
        interruptStatus |= 1
    }

    // MARK: - Ce qu'on sauve

    /// **Tout ce que le pilote a posé, plus où en est la file.**
    ///
    /// Les registres de découverte sont constants et ne se sauvent pas : le
    /// magique, la version, la classe. Ce qui se sauve, c'est ce que le pilote
    /// a écrit — l'état de la poignée de main, la taille et les trois adresses
    /// de la file — et les deux index qui disent où elle en est. Ces deux-là
    /// sont les seuls qu'une reprise ne peut pas recalculer : ils ne vivent
    /// que dans ce périphérique, et le pilote, lui, garde les siens.
    func save(into writer: inout Snapshot.Writer) {
        writer.u32(deviceFeaturesSelect)
        writer.u32(driverFeaturesSelect)
        writer.u64(driverFeatures)
        writer.u32(status)
        writer.u32(queueSelect)
        writer.u32(queueSize)
        writer.u32(queueReady)
        writer.u64(descriptorTable)
        writer.u64(availableRing)
        writer.u64(usedRing)
        writer.u32(queuePageNumber)
        writer.u32(interruptStatus)
        writer.u32(UInt32(nextAvailable))
        writer.u32(UInt32(nextUsed))
        writer.u64(served)
        writer.u64(refused)
        // L'image, par l'encodage de la RAM : une image fraîchement formatée
        // est presque entièrement nulle — treize pages sur quatre mille
        // quatre-vingt-seize pour une ext4 de seize mébioctets — et la coder
        // telle quelle rendrait l'instantané trop lourd pour être pris à
        // chaque passage en arrière-plan, qui est le seul moment où on peut.
        //
        // **Sauf quand le contenu vit ailleurs.** Un disque sur fichier ne
        // s'embarque pas : sa couche d'écriture est déjà durable, et
        // l'instantané d'une machine avec six gigaoctets de disque ferait six
        // gigaoctets. Une longueur impossible marque « ailleurs » ; la reprise
        // rebranche le store que l'application lui tend.
        if let memory = store as? MemoryDiskStore {
            writer.u64(UInt64(memory.image.count))
            memory.image.withUnsafeBytes { writer.ram($0) }
        } else {
            writer.u64(Self.contentLivesElsewhere)
        }
    }

    /// La marque, à la place de la longueur de l'image : aucune image n'a
    /// cette taille.
    static let contentLivesElsewhere = UInt64.max

    /// Le périphérique tel qu'il était. Construit plutôt que rempli sur place :
    /// une reprise qui échoue en chemin ne doit pas laisser derrière elle un
    /// disque à moitié rangé, et la machine ne prend celui-ci qu'une fois
    /// toutes les lectures faites.
    ///
    /// `keeping` est le store à rebrancher quand l'instantané porte la marque
    /// « ailleurs » : celui que la machine avait déjà, ouvert par
    /// l'application sur le même fichier. Sans lui, le disque revient vide —
    /// zéro secteur, des erreurs d'entrée-sortie — plutôt qu'un plantage :
    /// c'est le cas du fichier supprimé entre deux sessions.
    static func restored(from reader: inout Snapshot.Reader,
                         keeping kept: DiskStore? = nil) throws -> VirtioBlock {
        let device = VirtioBlock(image: [])
        device.deviceFeaturesSelect = try reader.u32()
        device.driverFeaturesSelect = try reader.u32()
        device.driverFeatures = try reader.u64()
        device.status = try reader.u32()
        device.queueSelect = try reader.u32()
        device.queueSize = try reader.u32()
        device.queueReady = try reader.u32()
        device.descriptorTable = try reader.u64()
        device.availableRing = try reader.u64()
        device.usedRing = try reader.u64()
        device.queuePageNumber = try reader.u32()
        device.interruptStatus = try reader.u32()
        device.nextAvailable = UInt16(truncatingIfNeeded: try reader.u32())
        device.nextUsed = UInt16(truncatingIfNeeded: try reader.u32())
        device.served = try reader.u64()
        device.refused = try reader.u64()
        let length = try reader.u64()
        if length == Self.contentLivesElsewhere {
            if let kept { device.store = kept }
        } else {
            guard let count = Int(exactly: length) else { throw Snapshot.Failure.corrupt }
            var image = [UInt8](repeating: 0, count: count)
            try image.withUnsafeMutableBytes { try reader.ram($0) }
            device.store = MemoryDiskStore(image: image)
        }
        return device
    }
}
