import XCTest

@testable import WisqVM

/// Le disque virtio-mmio, conduit comme le pilote de Linux le conduit.
///
/// **Ce que ces tests tiennent.** Un périphérique virtio se découvre en huit
/// lectures et se met en marche en autant d'écritures ; se tromper d'une
/// seule fait dire au noyau « virtio_mmio: Wrong magic value » ou
/// « device does not support VIRTIO_F_VERSION_1 », et le disque n'existe
/// jamais. Ensuite tout passe par une file en mémoire de l'invité : un
/// anneau de descripteurs, un anneau de disponibles, un anneau de servies.
/// Les tests posent ces anneaux à la main, exactement comme le pilote, et
/// demandent des secteurs.
final class X86VirtioBlockTests: XCTestCase {
    /// Là où l'on pose la file dans la mémoire de l'invité.
    static let descriptors: UInt64 = 0x1000
    static let available: UInt64 = 0x2000
    static let used: UInt64 = 0x3000
    static let scratch: UInt64 = 0x4000
    static let queue: UInt32 = 8

    /// Un disque de quatre secteurs, chacun rempli de son propre numéro.
    static func disk() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4 * 512)
        for sector in 0..<4 {
            for byte in 0..<512 { bytes[sector * 512 + byte] = UInt8(sector + 1) }
        }
        return bytes
    }

    /// La poignée de main du pilote, dans son ordre.
    static func started() -> (X86VirtioBlock, X86Memory) {
        let device = X86VirtioBlock(image: disk())
        let memory = X86Memory(size: 0x10000, base: 0)
        start(device, memory)
        return (device, memory)
    }

    /// La même poignée de main, sur une mémoire qu'on fournit.
    static func start(_ device: X86VirtioBlock, _ memory: X86Memory) {
        device.write(0x070, 4, 0, memory)      // remise à zéro
        device.write(0x070, 4, 1, memory)      // ACKNOWLEDGE
        device.write(0x070, 4, 3, memory)      // | DRIVER
        device.write(0x014, 4, 1, memory)      // les bits 32 à 63…
        device.write(0x024, 4, 1, memory)
        device.write(0x020, 4, device.read(0x010, 4), memory)
        device.write(0x070, 4, 11, memory)     // | FEATURES_OK
        device.write(0x030, 4, 0, memory)      // la file zéro
        device.write(0x038, 4, UInt64(queue), memory)
        device.write(0x080, 4, descriptors, memory)
        device.write(0x084, 4, 0, memory)
        device.write(0x090, 4, available, memory)
        device.write(0x094, 4, 0, memory)
        device.write(0x0A0, 4, used, memory)
        device.write(0x0A4, 4, 0, memory)
        device.write(0x044, 4, 1, memory)      // la file est prête
        device.write(0x070, 4, 15, memory)     // | DRIVER_OK
    }

    /// Un morceau de la mémoire de l'invité, tel qu'un descripteur le décrit :
    /// où il commence, combien il fait, et si c'est le périphérique qui y écrit.
    /// Les trois voyagent ensemble parce qu'ils ne veulent rien dire séparément.
    struct Span {
        var at: UInt64
        var length: UInt32
        var writable: Bool
    }

    /// Poser un descripteur.
    static func describe(_ memory: X86Memory, _ index: UInt64,
                         _ span: Span, next: UInt16?) throws {
        let base = descriptors + index * 16
        try memory.write(base, 8, span.at)
        try memory.write(base + 8, 4, UInt64(span.length))
        try memory.write(base + 12, 2, (span.writable ? 2 : 0) | (next != nil ? 1 : 0))
        try memory.write(base + 14, 2, UInt64(next ?? 0))
    }

    /// Une requête complète : l'en-tête, un tampon, l'octet de statut.
    static func request(_ memory: X86Memory, kind: UInt32, sector: UInt64,
                        buffer: Span) throws {
        let header = scratch
        try memory.write(header, 4, UInt64(kind))
        try memory.write(header + 4, 4, 0)
        try memory.write(header + 8, 8, sector)
        try describe(memory, 0, .init(at: header, length: 16, writable: false), next: 1)
        try describe(memory, 1, buffer, next: 2)
        try describe(memory, 2, .init(at: scratch + 0x800, length: 1, writable: true), next: nil)
        try memory.write(scratch + 0x800, 1, 0xFF)  // ni réussite ni échec
        // L'anneau des disponibles : l'entrée, puis l'index qui la publie.
        try memory.write(available + 4, 2, 0)
        try memory.write(available + 2, 2, 1)
    }

    static func status(_ memory: X86Memory) throws -> UInt64 {
        try memory.read(scratch + 0x800, 1)
    }

    // MARK: - La découverte

    /// Les quatre premiers registres : sans eux, le pilote ne va pas plus loin.
    func testTheDeviceIntroducesItself() {
        let device = X86VirtioBlock(image: Self.disk())
        XCTAssertEqual(device.read(0x000, 4), 0x7472_6976, "« virt »")
        XCTAssertEqual(device.read(0x004, 4), 2, "la version moderne du transport")
        XCTAssertEqual(device.read(0x008, 4), 2, "un périphérique de bloc")
        XCTAssertNotEqual(device.read(0x00C, 4), 0, "un fabricant, quel qu'il soit")
    }

    /// **Le seul bit annoncé est celui sans lequel rien ne marche.** Un pilote
    /// moderne exige `VIRTIO_F_VERSION_1`, le bit 32 : il est dans la seconde
    /// moitié des bits, celle que le pilote demande en écrivant 1 dans le
    /// sélecteur.
    func testOnlyVersionOneIsOffered() {
        let device = X86VirtioBlock(image: Self.disk())
        let memory = X86Memory(size: 0x1000, base: 0)
        device.write(0x014, 4, 0, memory)
        XCTAssertEqual(device.read(0x010, 4), 0, "aucun bit dans la première moitié")
        device.write(0x014, 4, 1, memory)
        XCTAssertEqual(device.read(0x010, 4), 1, "le bit 32, et lui seul")
    }

    /// La capacité, en secteurs de 512 octets, à l'offset zéro de l'espace de
    /// configuration. C'est ce que le noyau imprime : « [vda] 8 512-byte
    /// logical blocks ».
    func testTheCapacityIsTheDiskInSectors() {
        let device = X86VirtioBlock(image: Self.disk())
        XCTAssertEqual(device.read(0x100, 8), 4)
        XCTAssertEqual(device.read(0x100, 4), 4, "lue en deux fois, elle dit la même chose")
        XCTAssertEqual(device.read(0x104, 4), 0)
    }

    // MARK: - Les requêtes

    /// Une lecture : le secteur deux du disque arrive dans le tampon, l'octet
    /// de statut dit « réussi », l'anneau des servies avance, et la ligne
    /// d'interruption se lève.
    func testAReadBringsTheSectorBack() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 0, sector: 2, buffer: .init(at: 0x5000, length: 512, writable: true))
        XCTAssertFalse(device.interrupting, "rien n'a encore été demandé")
        device.write(0x050, 4, 0, memory)  // QueueNotify

        XCTAssertEqual(try Self.status(memory), 0, "réussi")
        XCTAssertEqual(try memory.read(0x5000, 1), 3, "le secteur deux porte des 3")
        XCTAssertEqual(try memory.read(0x5000 + 511, 1), 3, "jusqu'au bout")
        XCTAssertEqual(try memory.read(Self.used + 2, 2), 1, "une requête servie")
        XCTAssertEqual(try memory.read(Self.used + 4, 4), 0, "celle qui commençait au zéro")
        XCTAssertEqual(try memory.read(Self.used + 8, 4), 512, "512 octets écrits")
        XCTAssertTrue(device.interrupting)
        XCTAssertEqual(device.served, 1)
    }

    /// L'interruption s'acquitte par le registre prévu, et pas autrement.
    func testTheInterruptIsAcknowledged() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 0, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertTrue(device.interrupting)
        device.write(0x064, 4, 1, memory)
        XCTAssertFalse(device.interrupting)
    }

    /// Une écriture change le disque, et seulement le secteur demandé.
    func testAWriteChangesTheDisk() throws {
        let (device, memory) = Self.started()
        for byte in 0..<UInt64(512) { try memory.write(0x5000 + byte, 1, 0xAB) }
        try Self.request(memory, kind: 1, sector: 1, buffer: .init(at: 0x5000, length: 512, writable: false))
        device.write(0x050, 4, 0, memory)

        XCTAssertEqual(try Self.status(memory), 0)
        XCTAssertEqual(device.image[512], 0xAB, "le secteur un a changé")
        XCTAssertEqual(device.image[1023], 0xAB)
        XCTAssertEqual(device.image[0], 1, "le secteur zéro, non")
        XCTAssertEqual(device.image[1024], 3, "le secteur deux non plus")
    }

    /// **Un secteur au-delà du disque est une erreur.** Rendre des zéros
    /// serait répondre « voici le contenu » à une question dont la réponse est
    /// « il n'y a rien là ».
    func testASectorBeyondTheDiskIsRefused() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 0, sector: 99, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertEqual(try Self.status(memory), 1, "erreur d'entrée-sortie")
        XCTAssertEqual(device.refused, 1)
        XCTAssertEqual(device.served, 0)
    }

    /// Un type de requête que ce périphérique ne connaît pas se répond
    /// « non supporté » — pas par le silence, qui ferait attendre le pilote
    /// pour toujours.
    func testAnUnknownRequestIsAnsweredAnyway() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 99, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertEqual(try Self.status(memory), 2, "non supporté")
        XCTAssertEqual(try memory.read(Self.used + 2, 2), 1, "et la requête est rendue")
    }

    /// L'identifiant du disque : vingt octets que le noyau lit pour son
    /// attribut `serial`.
    func testTheDiskSaysItsName() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 8, sector: 0, buffer: .init(at: 0x5000, length: 20, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertEqual(try Self.status(memory), 0)
        var name = [UInt8]()
        for offset in 0..<UInt64(9) { name.append(UInt8(try memory.read(0x5000 + offset, 1))) }
        XCTAssertEqual(String(decoding: name, as: UTF8.self), "wisq-disk")
    }

    /// Deux requêtes d'affilée avancent l'anneau des servies de deux, et non
    /// de une : l'index des disponibles ne se relit pas, il se suit.
    func testTwoRequestsInARowAreBothServed() throws {
        let (device, memory) = Self.started()
        try Self.request(memory, kind: 0, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        // La seconde entrée de l'anneau des disponibles, puis son index.
        try memory.write(Self.available + 6, 2, 0)
        try memory.write(Self.available + 2, 2, 2)
        try memory.write(Self.scratch + 8, 8, 1)  // le secteur un, cette fois
        try memory.write(Self.scratch + 0x800, 1, 0xFF)
        device.write(0x050, 4, 0, memory)

        XCTAssertEqual(device.served, 2)
        XCTAssertEqual(try memory.read(Self.used + 2, 2), 2)
        XCTAssertEqual(try memory.read(0x5000, 1), 2, "le secteur un porte des 2")
    }

    /// Une file que le pilote n'a pas déclarée prête ne sert rien : c'est ce
    /// qui empêche de lire des anneaux qui n'existent pas encore.
    func testAQueueThatIsNotReadyServesNothing() throws {
        let (device, memory) = Self.started()
        device.write(0x044, 4, 0, memory)
        try Self.request(memory, kind: 0, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertEqual(device.served, 0)
        XCTAssertEqual(try Self.status(memory), 0xFF, "personne n'a répondu")
    }

    // MARK: - Branché derrière la mémoire

    /// **Les registres du périphérique répondent à des adresses qu'aucune RAM
    /// ne couvre.** C'est le chemin qui levait « hors mémoire » : le disque s'y
    /// branche sans rien coûter aux adresses ordinaires.
    func testTheDeviceAnswersThroughMemory() throws {
        let memory = X86Memory(size: 0x10000, base: 0)
        XCTAssertThrowsError(try memory.read(X86VirtioBlock.base, 4),
                             "sans disque, c'est hors mémoire")
        memory.storage = X86VirtioBlock(image: Self.disk())
        XCTAssertEqual(try memory.read(X86VirtioBlock.base, 4), 0x7472_6976)
        XCTAssertThrowsError(try memory.read(X86VirtioBlock.base + X86VirtioBlock.span, 4),
                             "et une adresse au-delà de la fenêtre reste hors mémoire")
    }

    /// La RAM garde la priorité : un disque branché ne doit pas voler une
    /// adresse que la mémoire couvre.
    func testMemoryKeepsItsOwnAddresses() throws {
        let memory = X86Memory(size: 0x10000, base: 0)
        memory.storage = X86VirtioBlock(image: Self.disk())
        try memory.write(0x1234, 4, 0xDEAD)
        XCTAssertEqual(try memory.read(0x1234, 4), 0xDEAD)
    }

    /// **Et l'interruption arrive au processeur, sur la ligne cinq.** Sans
    /// elle, le pilote pose sa requête et attend une réponse qu'il ne saura
    /// jamais arrivée.
    func testTheDiskInterruptReachesTheHandler() throws {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.load([0xF4], at: 0x100)      // hlt : la machine attend
        try ram.load([0xF4], at: 0x8000)     // le gestionnaire
        let low = (UInt64(0x8000) & 0xFFFF) | (UInt64(0x10) << 16) | (UInt64(0x8E) << 40)
        try ram.write(0x9000 + UInt64(0x35) * 16, 8, low)  // vecteur 0x30 + ligne 5
        var core = X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
        core.descriptorBases[1] = 0x9000
        core.descriptorLimits[1] = 0xFFF
        core.registers[4] = 0x7000
        core.devices.primary.mask = 0xDF   // la ligne cinq démasquée
        core.devices.primary.vectorBase = 0x30
        core.flags |= X86Core.Flag.interrupt

        let device = X86VirtioBlock(image: Self.disk())
        ram.storage = device
        try core.run(budget: 3)
        XCTAssertTrue(core.halted, "rien ne s'est encore passé")

        // Une vraie requête, servie comme le pilote la ferait servir.
        Self.start(device, ram)
        try Self.request(ram, kind: 0, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, ram)
        core.halted = false
        core.rip = 0x100
        try core.run(budget: 10, waiting: 100)
        XCTAssertEqual(core.rip, 0x8001, "le disque a réveillé la machine")
        XCTAssertEqual(core.devices.primary.service, 1 << 5)
    }

    /// Et une remise à zéro efface la file : un pilote qui recommence ne doit
    /// pas retrouver les anneaux du précédent.
    func testAResetForgetsTheQueue() throws {
        let (device, memory) = Self.started()
        device.write(0x070, 4, 0, memory)
        XCTAssertEqual(device.queueReady, 0)
        XCTAssertEqual(device.status, 0)
        try Self.request(memory, kind: 0, sector: 0, buffer: .init(at: 0x5000, length: 512, writable: true))
        device.write(0x050, 4, 0, memory)
        XCTAssertEqual(device.served, 0)
    }
}
