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
/// **Ce qui est implémenté, et ce qui ne l'est pas.** La version 2 du
/// transport (« moderne ») : le pilote annonce `VIRTIO_F_VERSION_1` et rien
/// d'autre, donc pas de descripteurs indirects, pas d'index d'événement, pas
/// de `FLUSH` ni de topologie. Une seule file, les requêtes traitées à la
/// notification et dans l'ordre. C'est ce qu'il faut pour qu'un noyau Linux
/// voie `/dev/vda` et le lise ; le reste viendra quand quelque chose le
/// demandera.
public final class X86VirtioBlock: @unchecked Sendable {
    /// Là où le noyau ira le chercher, et par quelle ligne il sera prévenu.
    /// Ces trois nombres sont **la ligne de commande** : les changer ici sans
    /// la changer là ferait chercher le pilote dans le vide.
    public static let base: UInt64 = 0xD000_0000
    public static let span: UInt64 = 0x200
    public static let interruptLine: UInt8 = 5

    /// Le contenu du disque, secteur par secteur de 512 octets.
    public var image: [UInt8]

    public init(image: [UInt8]) {
        self.image = image
    }

    public var sectors: UInt64 { UInt64(image.count / 512) }

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

    public func writePort(_ offset: UInt16, _ width: Int, _ value: UInt64, _ memory: X86Memory) {
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

    public func write(_ offset: UInt64, _ width: Int, _ value: UInt64, _ memory: X86Memory) {
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

    func descriptor(_ index: UInt16, _ memory: X86Memory) throws -> Descriptor {
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
    func serve(_ memory: X86Memory) {
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

    private func serveOne(_ head: UInt16, _ memory: X86Memory) {
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
            && sector &* 512 &+ span > UInt64(image.count)
        guard !beyond else { refused &+= 1; return }
        switch kind {
        case 0:  // lecture
            var at = sector &* 512
            for buffer in payload {
                guard buffer.writable else { refused &+= 1; return }
                for byte in 0..<UInt64(buffer.length) {
                    try? memory.write(buffer.address &+ byte, 1, UInt64(image[Int(at &+ byte)]))
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
                for byte in 0..<UInt64(buffer.length) {
                    if let value = try? memory.read(buffer.address &+ byte, 1) {
                        image[Int(at &+ byte)] = UInt8(truncatingIfNeeded: value)
                    }
                }
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
                          _ last: Descriptor?, _ memory: X86Memory) {
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
}
