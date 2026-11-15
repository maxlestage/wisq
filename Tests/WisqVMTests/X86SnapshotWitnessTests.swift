import Foundation
import XCTest

@testable import WisqVM

/// **Les instantanés témoins** : `Tests/Fixtures/x86-instantane-N.wisqvm`, un
/// par niveau de machine (`X86Machine.snapshotLevel`), écrits une fois sous
/// Linux et relus à chaque passage, sous Linux (« Cœur (Linux) ») **et** sur
/// macOS arm64 (« Cœur (Apple) »).
///
/// **Ce qui n'était tenu par rien.** Un bureau prêt est fabriqué sous Linux
/// x86-64 et repris sur un iPhone arm64, par une version de wisq plus récente
/// que celle qui l'a fabriqué. Que le format soit portable se lisait dans le
/// code (petit-boutiste partout, pas d'adresse de l'hôte) ; que les versions
/// suivantes le relisent tenait à une règle — ne jamais déplacer un octet,
/// ajouter en queue derrière une marque. Aucun test ne relisait sur un hôte
/// un instantané écrit sur l'autre, ni un instantané d'une version passée :
/// un champ ajouté au milieu d'une section, ou un périphérique déplacé sur le
/// bus, cassait en silence tous les bureaux déjà publiés.
///
/// **Ce que le témoin porte** : la machine de l'application (la carte réseau,
/// l'écran et sa tablette, les deux disques sur fichier) à 128 Mio, presque
/// vide, mais avec **une valeur reconnaissable dans chaque champ** de chaque
/// section — un champ décalé se voit comme une valeur fausse —, et des
/// périphériques programmés **par les ports**, comme un noyau le fait : les
/// emplacements PCI sont ceux auxquels le témoin a parlé.
///
/// **Les règles** :
///
/// - un témoin publié ne se refabrique jamais. Une machine qui change monte
///   son niveau et ajoute le témoin du niveau suivant
///   (`WISQ_ECRIRE_TEMOIN=1 swift test --filter X86SnapshotWitnessTests`,
///   qui n'écrit qu'un fichier absent) ; les anciens continuent d'être relus ;
/// - le témoin du niveau courant est **exactement** ce que cette machine
///   écrit aujourd'hui : un octet qui bouge sans que le niveau monte est un
///   instantané publié que cette version relirait de travers.
final class X86SnapshotWitnessTests: XCTestCase {
    // MARK: - Où ils vivent

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func witnessURL(level: UInt64) -> URL {
        fixtures.appendingPathComponent("x86-instantane-\(level).wisqvm")
    }

    /// Les niveaux dont un témoin est commité, du plus ancien au plus récent.
    static func committedLevels() throws -> [UInt64] {
        try FileManager.default.contentsOfDirectory(atPath: fixtures.path).compactMap { name in
            guard name.hasPrefix("x86-instantane-"), name.hasSuffix(".wisqvm") else { return nil }
            return UInt64(name.dropFirst("x86-instantane-".count).dropLast(".wisqvm".count))
        }.sorted()
    }

    static func witness(level: UInt64) throws -> Data {
        try SnapshotFile.unpack(Data(contentsOf: witnessURL(level: level)))
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-temoin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - La machine

    static let ramSize = 128 << 20
    static let diskBytes = 64 << 10
    static let secondDiskBytes = 32 << 10

    /// Les deux disques, sur fichier comme dans l'application : chaque
    /// secteur porte son numéro, décalé d'un disque à l'autre.
    func diskFiles() throws -> (disk: URL, writes: URL, second: URL, secondWrites: URL) {
        func image(_ bytes: Int, shift: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 / 512 + shift) })
        }
        let disk = folder.appendingPathComponent("disque.img")
        let second = folder.appendingPathComponent("second.img")
        try image(Self.diskBytes, shift: 1).write(to: disk)
        try image(Self.secondDiskBytes, shift: 101).write(to: second)
        return (disk, folder.appendingPathComponent("disque.writes"),
                second, folder.appendingPathComponent("second.writes"))
    }

    /// **La machine de l'application**, neuve : celle que
    /// `GuestMachineFactory.make` construit pour un PC, la carte réseau
    /// branchée, puis l'écran et sa tablette, puis les deux disques — dans
    /// l'ordre de `LocalVMModel`.
    func applicationMachine() throws -> X86Machine {
        let files = try diskFiles()
        let fixed = Date(timeIntervalSince1970: 1_794_614_400)
        let made = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: Self.ramSize, onOutput: { _ in },
            network: { UserNetwork.isolated(hostClock: { fixed }) })
        let machine = try XCTUnwrap(made as? X86Machine)
        machine.entropy = .seeded(X86Entropy.reproducibleSeed)
        try GuestMachineFactory.attachScreen(to: machine)
        try machine.attach(diskFileAt: files.disk, writes: files.writes)
        try machine.attach(secondDiskFileAt: files.second, writes: files.secondWrites)
        return machine
    }

    // MARK: - Le témoin, champ par champ

    /// Les valeurs du témoin : une par champ, toutes différentes.
    enum Spec {
        static func register(_ index: Int) -> UInt64 { 0x5157_4953_0000_0000 | UInt64(index) << 8 | UInt64(index) }
        static let flags: UInt64 = 0x0000_0000_0020_0A97
        static let rip: UInt64 = 0xFFFF_FFFF_8102_3456
        static let retired: UInt64 = 0x0000_0123_4567_89AB
        static let idled: UInt64 = 0x0000_0000_0765_4321
        static func control(_ index: Int) -> UInt64 {
            switch index {
            case 0: return 0x8005_0033
            case 2: return 0xDEAD_B000
            case 3: return 0x0123_4000
            case 4: return 0x0036_06F0
            case 8: return 0x0F
            default: return 0xC0_0000 | UInt64(index)
            }
        }
        static func debug(_ index: Int) -> UInt64 { 0xD000 | UInt64(index) }
        /// Triés, comme l'instantané les écrit.
        static let modelSpecific: [(UInt32, UInt64)] = [
            (0xC000_0080, 0x0D01), (0xC000_0081, 0x0023_0010_0000_0000), (0xC000_0082, 0xFFFF_FFFF_8160_0080),
            (0xC000_0100, 0x7F00_1234_5000), (0xC000_0101, 0xFFFF_8880_0F00_0000),
            (0xC000_0102, 0x0000_7FFF_ABCD_0000), (0xC000_0103, 3),
        ]
        static let segments: [UInt16] = [0x2B, 0x10, 0x18, 0x2B, 0x53, 0x63]
        static let descriptorBases: [UInt64] = [0xFFFF_FE00_0000_1000, 0xFFFF_FE00_0000_0000]
        static let descriptorLimits: [UInt64] = [0x7F, 0xFFF]
        static let taskSelector: UInt16 = 0x40
        static let taskBase: UInt64 = 0xFFFF_FE00_0000_3000
        static let taskLimit: UInt64 = 0x4087
        static let x87Control: UInt16 = 0x027F
        static let x87Status: UInt16 = 0x3800
        static let mxcsr: UInt32 = 0x1FA0
        static func vector(_ index: Int) -> UInt64 { 0xA5A5_0000_0000_0000 | UInt64(index) * 0x0101 }
        static func x87(_ index: Int) -> X86Extended {
            X86Extended(significand: 0xC000_0000_0000_0000 | UInt64(index), signExponent: 0x3FFF + UInt16(index))
        }
        static let x87Tags: UInt16 = 0x5A0F
        static let xcr0: UInt64 = 0b111
        static func upperVector(_ index: Int) -> UInt64 { 0x5A5A_0000_0000_0000 | UInt64(index) * 0x0303 }
        static let instructionsPerTick: UInt64 = 288
        /// Ce qui attend d'être tapé : une part dans le port série, une part
        /// dans la file de la machine.
        static let typedInPort = Array("en ".utf8)
        static let typedQueued = Array("attente\n".utf8)
        /// La marque en mémoire, et le dernier mot de la mémoire.
        static let markAt: UInt64 = 0x7000
        static let mark = Array("WISQ-TEMOIN".utf8)
        static let lastWord: UInt64 = 0x0123_4567_89AB_CDEF

        /// Les fenêtres de ports que le témoin donne aux trois périphériques.
        static let diskWindow: UInt32 = 0xC000
        static let secondDiskWindow: UInt32 = 0xC040
        static let networkWindow: UInt32 = 0xC080
        /// Les pages des files : celle du disque, du second, et les deux de la
        /// carte réseau.
        static let diskQueuePage: UInt32 = 0x20
        static let secondDiskQueuePage: UInt32 = 0x24
        static let networkQueuePages: [UInt32] = [0x28, 0x2C]
        /// La requête servie : lire le secteur deux du premier disque.
        static let requestHeader: UInt64 = 0x30000
        static let requestBuffer: UInt64 = 0x30200
        static let requestStatus: UInt64 = 0x30400
        static let requestSector: UInt64 = 2
        /// La mémoire vidéo déplacée par sa BAR, et le mode posé.
        static let displayBase: UInt64 = 0xC000_0000
        static let mode: [UInt16] = [1024, 768, 32]
        static let yOffset: UInt16 = 768
        /// Les files de la tablette.
        static let tabletRings: [UInt64] = [0x38000, 0x39000, 0x3A000]
        /// La dernière adresse écrite sur le bus : l'emplacement trois, sa
        /// ligne d'interruption.
        static let busAddress: UInt32 = 0x8000_183C

        // **Ce que l'invité a vu de la machine, écrit en chiffres** et pas lu
        // dans le code : un emplacement, une ligne, une adresse que le code
        // déplacerait suivraient sinon, et le témoin ne dirait rien. C'est
        // la machine que le noyau d'un bureau publié a découverte.
        static let displaySlot: UInt32 = 2
        static let diskSlot: UInt32 = 3
        static let secondDiskSlot: UInt32 = 4
        static let networkSlot: UInt32 = 5
        static let tabletSlot: UInt32 = 7
        static let diskLine: UInt8 = 5
        static let secondDiskLine: UInt8 = 6
        static let networkLine: UInt8 = 3
        static let tabletLine: UInt8 = 10
        static let mac: [UInt8] = [0x02, 0x77, 0x69, 0x73, 0x71, 0x01]
        static let macFeature: UInt32 = 1 << 5
        static let videoMemory = 16 << 20
        static let displayRegistersBase: UInt64 = 0xE100_0000
        static let tabletBase: UInt64 = 0xE101_0000
        /// Les anneaux d'une file de cent vingt-huit en forme ancienne : les
        /// descripteurs à la page, les disponibles derrière, les servies à la
        /// page suivante.
        static let blockQueueSize: UInt32 = 128
        static let diskRings: [UInt64] = [0x20000, 0x20800, 0x21000]
        static let secondDiskRings: [UInt64] = [0x24000, 0x24800, 0x25000]
    }

    /// **Écrire le témoin dans `machine`** : chaque champ du processeur posé à
    /// sa valeur, puis chaque périphérique programmé par ses ports et sa
    /// mémoire, comme un pilote.
    static func program(_ machine: X86Machine) throws {
        let memory = machine.memory
        func port(_ number: UInt32, _ width: Int, _ value: UInt64) {
            machine.core.portWrite(UInt16(number), width, value)
        }
        func configure(slot: UInt32, register: UInt32, _ value: UInt32) {
            port(0xCF8, 4, UInt64(0x8000_0000 | slot << 11 | register))
            port(0xCFC, 4, UInt64(value))
        }
        func dispi(_ register: UInt16, _ value: UInt16) {
            port(0x1CE, 2, UInt64(register))
            port(0x1CF, 2, UInt64(value))
        }

        // Le bus, emplacement par emplacement : les ports ouverts et les
        // fenêtres placées, comme `pci_enable_device` et l'allocation des BAR.
        configure(slot: Spec.diskSlot, register: 0x04, 0x0005)
        configure(slot: Spec.diskSlot, register: 0x10, Spec.diskWindow | 1)
        configure(slot: Spec.secondDiskSlot, register: 0x04, 0x0005)
        configure(slot: Spec.secondDiskSlot, register: 0x10, Spec.secondDiskWindow | 1)
        configure(slot: Spec.networkSlot, register: 0x04, 0x0005)
        configure(slot: Spec.networkSlot, register: 0x10, Spec.networkWindow | 1)
        configure(slot: Spec.displaySlot, register: 0x04, 0x0003)
        configure(slot: Spec.displaySlot, register: 0x10, UInt32(Spec.displayBase) | 0x08)
        configure(slot: Spec.tabletSlot, register: 0x04, 0x0006)

        // Le disque, en forme ancienne de virtio-pci : la poignée de main, la
        // file, puis une lecture servie — ses index et ses compteurs bougent.
        let disk = Spec.diskWindow
        port(disk + 0x12, 1, 1)
        port(disk + 0x12, 1, 3)
        port(disk + 0x04, 4, 0)
        port(disk + 0x0E, 2, 0)
        port(disk + 0x08, 4, UInt64(Spec.diskQueuePage))
        port(disk + 0x12, 1, 7)
        let (descriptors, available) = (Spec.diskRings[0], Spec.diskRings[1])
        try memory.write(Spec.requestHeader, 4, 0)
        try memory.write(Spec.requestHeader + 8, 8, Spec.requestSector)
        for (index, span) in [(Spec.requestHeader, 16, 0), (Spec.requestBuffer, 512, 2),
                              (Spec.requestStatus, 1, 2)].enumerated() {
            let at = descriptors + UInt64(index) * 16
            try memory.write(at, 8, span.0)
            try memory.write(at + 8, 4, UInt64(span.1))
            try memory.write(at + 12, 2, UInt64(span.2) | (index < 2 ? 1 : 0))
            try memory.write(at + 14, 2, UInt64(index + 1))
        }
        try memory.write(available + 4, 2, 0)
        try memory.write(available + 2, 2, 1)
        try memory.write(Spec.requestStatus, 1, 0xFF)
        port(disk + 0x10, 2, 0)

        // Le second disque : la file posée, rien de servi.
        let second = Spec.secondDiskWindow
        port(second + 0x12, 1, 3)
        port(second + 0x0E, 2, 0)
        port(second + 0x08, 4, UInt64(Spec.secondDiskQueuePage))
        port(second + 0x12, 1, 7)

        // La carte réseau : l'adresse acceptée, ses deux files posées.
        let network = Spec.networkWindow
        port(network + 0x12, 1, 3)
        port(network + 0x04, 4, UInt64(Spec.macFeature))
        for (queue, page) in Spec.networkQueuePages.enumerated() {
            port(network + 0x0E, 2, UInt64(queue))
            port(network + 0x08, 4, UInt64(page))
        }
        port(network + 0x0E, 2, 1)
        port(network + 0x12, 1, 7)

        // La tablette, en forme moderne, par sa mémoire : la poignée de main
        // de `virtio_pci_modern`, puis la file des événements, garnie.
        let tablet = Spec.tabletBase
        let rings = Spec.tabletRings
        for (offset, width, value) in [(0x14, 1, 0), (0x14, 1, 3), (0x00, 4, 1), (0x08, 4, 1), (0x0C, 4, 1),
                                       (0x14, 1, 11), (0x16, 2, 0), (0x18, 2, 8),
                                       (0x20, 8, Int(rings[0])), (0x28, 4, Int(rings[1])), (0x2C, 4, 0),
                                       (0x30, 8, Int(rings[2])), (0x1C, 2, 1), (0x14, 1, 15)] {
            try memory.write(tablet + UInt64(offset), width, UInt64(value))
        }
        for index in 0..<8 {
            let at = rings[0] + UInt64(index) * 16
            try memory.write(at, 8, 0x3B000 + UInt64(index) * 8)
            try memory.write(at + 8, 4, 8)
            try memory.write(at + 12, 2, 2)
            try memory.write(rings[1] + 4 + UInt64(index) * 2, 2, UInt64(index))
        }
        try memory.write(rings[1] + 2, 2, 8)

        // L'écran : le mode de `bochs_hw_setmode`, la carte allumée, puis la
        // seconde page montrée comme `bochs_hw_setbase` la montre — après
        // l'allumage, qui remet les décalages à zéro —, et un carré peint sur
        // chacune des deux.
        dispi(4, 0)
        dispi(3, Spec.mode[2])
        dispi(1, Spec.mode[0])
        dispi(2, Spec.mode[1])
        dispi(5, 0)
        dispi(4, 0x41)
        dispi(6, Spec.mode[0])
        dispi(7, UInt16(Spec.videoMemory / (Int(Spec.mode[0]) * 4)))
        dispi(8, 0)
        dispi(9, Spec.yOffset)
        for page in 0..<2 {
            for row in 0..<16 {
                for column in 0..<16 {
                    let y = UInt64(page * Int(Spec.yOffset) + 8 + row), x = UInt64(8 + column)
                    try memory.write(Spec.displayBase + (y * 1024 + x) * 4, 4, page == 0 ? 0x00FF_8000 : 0x0040_C0FF)
                }
            }
        }

        // La mémoire : la marque, et le dernier mot.
        for (index, byte) in Spec.mark.enumerated() { try memory.write(Spec.markAt + UInt64(index), 1, UInt64(byte)) }
        try memory.write(UInt64(ramSize) - 8, 8, Spec.lastWord)

        // Le processeur, champ par champ.
        for index in 0..<16 { machine.core.registers[index] = Spec.register(index) }
        machine.core.flags = Spec.flags
        machine.core.rip = Spec.rip
        machine.core.retired = Spec.retired
        machine.core.idled = Spec.idled
        machine.core.halted = true
        machine.core.pagingActive = true
        for index in 0..<16 { machine.core.system.control[index] = Spec.control(index) }
        for index in 0..<8 { machine.core.system.debug[index] = Spec.debug(index) }
        var registers = X86ModelSpecific()
        for (number, value) in Spec.modelSpecific { registers[number] = value }
        machine.core.system.modelSpecific = registers
        machine.core.segments = Spec.segments
        machine.core.descriptorBases = Spec.descriptorBases
        machine.core.descriptorLimits = Spec.descriptorLimits
        machine.core.taskSelector = Spec.taskSelector
        machine.core.taskBase = Spec.taskBase
        machine.core.taskLimit = Spec.taskLimit
        machine.core.x87Control = Spec.x87Control
        machine.core.x87Status = Spec.x87Status
        machine.core.mxcsr = Spec.mxcsr
        for index in 0..<32 { machine.core.vectors[index] = Spec.vector(index) }
        for index in 0..<8 { machine.core.x87[index] = Spec.x87(index) }
        machine.core.x87Tags = Spec.x87Tags
        machine.core.xcr0 = Spec.xcr0
        for index in 0..<32 { machine.core.upperVectors[index] = Spec.upperVector(index) }
        machine.core.instructionsPerTick = Spec.instructionsPerTick

        // Les périphériques hérités, posés après la requête du disque, qui a
        // levé sa ligne.
        machine.core.devices = legacyDevices()
        machine.core.serialInput = Spec.typedInPort
        machine.send(Data(Spec.typedQueued))
        // La dernière adresse du bus, qu'une reprise au milieu d'un couple
        // adresse-donnée doit retrouver.
        port(0xCF8, 4, UInt64(Spec.busAddress))
    }

    /// Le 8259, le 8253, le haut-parleur et le 16550 du témoin.
    static func legacyDevices() -> X86LegacyDevices {
        var devices = X86LegacyDevices()
        devices.primary.mask = 0xB8
        devices.primary.request = 0x21
        devices.primary.service = 0x01
        devices.primary.vectorBase = 0x30
        devices.primary.initialisationStep = 0
        devices.primary.readsService = false
        devices.secondary.mask = 0xEF
        devices.secondary.request = 0x02
        devices.secondary.service = 0x00
        devices.secondary.vectorBase = 0x38
        devices.secondary.initialisationStep = 2
        devices.secondary.readsService = true
        devices.reload = 0x2E9C
        devices.oneShot = true
        devices.writeHighNext = true
        devices.readHighNext = false
        devices.latched = 0x1234
        devices.reloadedAt = 0x1_0000_0001
        devices.raised = 4242
        devices.speakerReload = 0x0533
        devices.speakerWriteHighNext = false
        devices.speakerReadHighNext = true
        devices.speakerStartedAt = 777
        devices.speakerGate = true
        devices.serial.interruptEnable = 0x03
        devices.serial.fifoControl = 0xC7
        devices.serial.lineControl = 0x03
        devices.serial.modemControl = 0x0B
        devices.serial.scratch = 0x5A
        devices.serial.divisor = 1
        devices.serial.transmitPending = true
        return devices
    }

    /// Le témoin tel que cette machine l'écrit aujourd'hui.
    func writtenToday() throws -> Data {
        let machine = try applicationMachine()
        try Self.program(machine)
        machine.flushDisk()
        return machine.snapshot()
    }

    // MARK: - Les témoins commités

    /// **Le niveau courant a son témoin** : une machine qui monte son niveau
    /// sans en ajouter un n'est tenue par rien.
    func testTheCurrentLevelHasItsWitness() throws {
        let levels = try Self.committedLevels()
        XCTAssertTrue(levels.contains(X86Machine.snapshotLevel),
                      "pas de témoin pour le niveau \(X86Machine.snapshotLevel) : \(levels)")
        for level in levels {
            let bytes = try XCTUnwrap(try? Data(contentsOf: Self.witnessURL(level: level)))
            XCTAssertLessThan(bytes.count, 16 << 10, "le témoin \(level) pèse \(bytes.count) octets")
            XCTAssertEqual(Array(bytes.prefix(7)), Array("WISQLZ4".utf8), "le témoin \(level) n'est pas une session")
        }
    }

    /// **Chaque témoin se lit section par section**, par un lecteur écrit ici
    /// d'après le format, pas par celui de la machine : chaque marque à sa
    /// place, chaque longueur juste, chaque champ à sa valeur, et rien après
    /// le second disque.
    func testEachWitnessReadsSectionBySection() throws {
        for level in try Self.committedLevels() {
            try Self.walk(try Self.witness(level: level), level: level)
        }
    }

    /// **Chaque témoin reprend dans la machine de l'application d'aujourd'hui**,
    /// et ce que l'invité avait programmé y est encore : les registres, la
    /// mémoire, et surtout **chaque périphérique à l'emplacement PCI où
    /// l'invité l'a trouvé**, sa fenêtre là où il l'a mise. C'est ce qu'un
    /// emplacement déplacé dans le code casserait, et le format n'en dirait
    /// rien.
    func testEachWitnessResumesInTodaysMachine() throws {
        for level in try Self.committedLevels() {
            let machine = try applicationMachine()
            try machine.restore(try Self.witness(level: level))
            try Self.checkResumed(machine, level: level)
        }
    }

    /// **Cette machine écrit encore, octet pour octet, le témoin de son
    /// niveau.** Sinon, le format a bougé sans que le niveau monte : un champ
    /// glissé dans une section, un périphérique déplacé.
    func testThisMachineStillWritesTheWitnessOfItsLevel() throws {
        let today = try writtenToday()
        let committed = try Self.witness(level: X86Machine.snapshotLevel)
        let first = zip(today, committed).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertTrue(today == committed,
                      "le témoin du niveau \(X86Machine.snapshotLevel) a changé (\(committed.count) octets, "
                      + "aujourd'hui \(today.count), premier écart à l'octet \(first.map(String.init) ?? "—")) : "
                      + "monter X86Machine.snapshotLevel et ajouter le témoin du niveau suivant")
    }

    /// Repris puis resauvé, le témoin du niveau courant redonne ses propres
    /// octets : rien n'est perdu ni déplacé en passant par la machine.
    func testAResumedWitnessWritesItselfAgain() throws {
        let committed = try Self.witness(level: X86Machine.snapshotLevel)
        let machine = try applicationMachine()
        try machine.restore(committed)
        XCTAssertTrue(machine.snapshot() == committed, "la reprise du témoin ne le redonne pas")
    }

    /// **Écrire le témoin du niveau courant**, armé par `WISQ_ECRIRE_TEMOIN` —
    /// et seulement s'il n'existe pas : un témoin publié ne se refabrique pas.
    func testWriteTheWitnessOfThisLevel() throws {
        guard ProcessInfo.processInfo.environment["WISQ_ECRIRE_TEMOIN"] == "1" else {
            throw XCTSkip("définir WISQ_ECRIRE_TEMOIN=1 pour écrire le témoin d'un niveau neuf")
        }
        let url = Self.witnessURL(level: X86Machine.snapshotLevel)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("le témoin du niveau \(X86Machine.snapshotLevel) existe : il ne se refabrique pas")
        }
        let packed = SnapshotFile.pack(try writtenToday())
        try packed.write(to: url)
        print("témoin écrit : \(url.path), \(packed.count) octets")
    }

    // MARK: - Le lecteur du format

    /// Un lecteur d'octets, à part de `Snapshot.Reader` : c'est le format
    /// écrit noir sur blanc, pas le code qui le lit.
    struct Walker {
        let bytes: [UInt8]
        var at = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, at + count <= bytes.count else {
                throw Failure("plus d'octets à l'octet \(at) (il en fallait \(count))")
            }
            defer { at += count }
            return bytes[at..<at + count]
        }

        mutating func u32() throws -> UInt32 {
            try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() throws -> UInt64 {
            try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// Une marque de section, nommée par ses huit lettres.
        mutating func section(_ name: String) throws {
            let found = try take(8)
            guard Array(found) == Array(name.utf8) else {
                throw Failure("à l'octet \(at - 8), « \(name) » attendu, \(Array(found)) trouvé")
            }
        }

        /// Une mémoire codée par paires (zéros, littéral) : sa taille, et ses
        /// octets non nuls par adresse.
        mutating func ram() throws -> (size: UInt64, written: [UInt64: UInt8]) {
            let size = try u64()
            let pairs = try u64()
            var written: [UInt64: UInt8] = [:]
            var position: UInt64 = 0
            for _ in 0..<pairs {
                position += try u64()
                let literal = try u64()
                for byte in try take(Int(literal)) {
                    if byte != 0 { written[position] = byte }
                    position += 1
                }
            }
            guard position == size else { throw Failure("la mémoire couvre \(position) octets sur \(size)") }
            return (size, written)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Le format du niveau `level`, dans l'ordre (`X86Machine.snapshot`).
    static func walk(_ snapshot: Data, level: UInt64, file: StaticString = #filePath, line: UInt = #line) throws {
        var walker = Walker(bytes: Array(snapshot))
        XCTAssertEqual(Array(try walker.take(8)), Array("WISQSNP".utf8) + [1], "la marque")
        func expect<T: Equatable>(_ read: T, _ wanted: T, _ what: String) {
            XCTAssertEqual(read, wanted, "témoin \(level) : \(what)", file: file, line: line)
        }

        // Le processeur.
        for index in 0..<16 { expect(try walker.u64(), Spec.register(index), "registre \(index)") }
        expect(try walker.u64(), Spec.flags, "drapeaux")
        expect(try walker.u64(), Spec.rip, "rip")
        expect(try walker.u64(), Spec.retired, "instructions retirées")
        expect(try walker.u64(), Spec.idled, "instructions dormies")
        expect(try walker.u64(), 1, "arrêté sur HLT")
        expect(try walker.u64(), 1, "pagination active")
        for index in 0..<16 { expect(try walker.u64(), Spec.control(index), "CR\(index)") }
        for index in 0..<8 { expect(try walker.u64(), Spec.debug(index), "DR\(index)") }
        expect(try walker.u64(), UInt64(Spec.modelSpecific.count), "nombre de MSR")
        for (number, value) in Spec.modelSpecific {
            expect(try walker.u32(), number, "numéro de MSR")
            expect(try walker.u64(), value, "MSR \(String(number, radix: 16))")
        }
        for index in 0..<6 { expect(try walker.u32(), UInt32(Spec.segments[index]), "segment \(index)") }
        for index in 0..<2 {
            expect(try walker.u64(), Spec.descriptorBases[index], "base de la table \(index)")
            expect(try walker.u64(), Spec.descriptorLimits[index], "limite de la table \(index)")
        }
        expect(try walker.u32(), UInt32(Spec.taskSelector), "registre de tâche")
        expect(try walker.u64(), Spec.taskBase, "base de la tâche")
        expect(try walker.u64(), Spec.taskLimit, "limite de la tâche")
        expect(try walker.u32(), UInt32(Spec.x87Control), "mot de contrôle x87")
        expect(try walker.u32(), UInt32(Spec.x87Status), "mot d'état x87")
        expect(try walker.u32(), Spec.mxcsr, "MXCSR")
        for index in 0..<32 { expect(try walker.u64(), Spec.vector(index), "XMM, mot \(index)") }

        // Les périphériques hérités.
        let devices = legacyDevices()
        for controller in [devices.primary, devices.secondary] {
            let fields = [UInt32(controller.mask), UInt32(controller.request), UInt32(controller.service),
                          UInt32(controller.vectorBase), UInt32(controller.initialisationStep),
                          controller.readsService ? 1 : 0]
            for wanted in fields { expect(try walker.u32(), wanted, "8259") }
        }
        expect(try walker.u32(), UInt32(devices.reload) | 1 << 16, "8253, compte et mode")
        expect(try walker.u32(), 1, "8253, octet haut à écrire")
        expect(try walker.u32(), 0, "8253, octet haut à lire")
        expect(try walker.u32(), UInt32(devices.latched ?? 0), "8253, compte verrouillé")
        expect(try walker.u32(), 1, "8253, verrouillé")
        expect(try walker.u64(), devices.reloadedAt, "8253, rechargé à")
        expect(try walker.u64(), devices.raised, "8253, levées")
        expect(try walker.u32(), UInt32(devices.speakerReload), "haut-parleur, compte")
        expect(try walker.u32(), 0, "haut-parleur, octet haut à écrire")
        expect(try walker.u32(), 1, "haut-parleur, octet haut à lire")
        expect(try walker.u64(), devices.speakerStartedAt, "haut-parleur, parti à")
        expect(try walker.u32(), 1, "haut-parleur, porte")
        for (wanted, what) in [(0x03, "IER"), (0xC7, "FCR"), (0x03, "LCR"), (0x0B, "MCR"), (0x5A, "SCR"),
                               (1, "diviseur"), (1, "émission en attente")] as [(UInt32, String)] {
            expect(try walker.u32(), wanted, "16550, \(what)")
        }

        // Ce qui attend d'être tapé, puis la mémoire.
        let typed = Spec.typedInPort + Spec.typedQueued
        expect(try walker.u64(), UInt64(typed.count), "longueur de ce qui est tapé")
        expect(Array(try walker.take(typed.count)), typed, "ce qui est tapé")
        let ram = try walker.ram()
        expect(ram.size, UInt64(ramSize), "taille de la mémoire")
        for (index, byte) in Spec.mark.enumerated() {
            expect(ram.written[Spec.markAt + UInt64(index)], byte, "la marque en mémoire")
        }
        for index in 0..<8 {
            expect(ram.written[UInt64(ramSize) - 8 + UInt64(index)],
                   UInt8(truncatingIfNeeded: Spec.lastWord >> (8 * UInt64(index))), "le dernier mot")
        }
        // Le secteur deux lu par la requête, et son statut (zéro : réussi).
        let sector = (0..<512).compactMap { ram.written[Spec.requestBuffer + UInt64($0)] }
        expect(sector, [UInt8](repeating: UInt8(Spec.requestSector + 1), count: 512), "le secteur lu")
        expect(ram.written[Spec.requestStatus], nil, "le statut de la requête")

        // Le niveau, juste derrière la mémoire.
        try walker.section("WISQ_lvl")
        expect(try walker.u64(), level, "niveau")
        try walker.section("WISQ_x87")
        for index in 0..<8 {
            expect(try walker.u64(), Spec.x87(index).significand, "ST\(index), mantisse")
            expect(try walker.u32(), UInt32(Spec.x87(index).signExponent), "ST\(index), exposant")
        }
        expect(try walker.u32(), UInt32(Spec.x87Tags), "étiquettes x87")
        try walker.section("WISQ_ymm")
        expect(try walker.u64(), Spec.xcr0, "XCR0")
        for index in 0..<32 { expect(try walker.u64(), Spec.upperVector(index), "haut des YMM, mot \(index)") }
        try walker.section("WISQ_tck")
        expect(try walker.u64(), Spec.instructionsPerTick, "instructions par battement")

        // L'écran : la mémoire vidéo et la carte.
        try walker.section("WISQ_vid")
        expect(try walker.u64(), UInt64(Spec.videoMemory), "taille de la mémoire vidéo")
        expect(try walker.u64(), Spec.displayBase, "base de la mémoire vidéo")
        expect(try walker.u64(), 1024, "largeur de l'écran de démarrage")
        expect(try walker.u64(), 768, "hauteur de l'écran de démarrage")
        var registers: [UInt32] = []
        for _ in 0..<11 { registers.append(try walker.u32()) }
        expect(Array(registers[1...3]), Spec.mode.map(UInt32.init), "le mode posé")
        expect(registers[4], 0x41, "la carte allumée en cadre linéaire")
        expect(registers[9], UInt32(Spec.yOffset), "la page montrée")
        expect(try walker.u32(), 9, "dernier registre choisi")
        expect(try walker.u64(), Spec.displayRegistersBase, "base des registres")
        expect(try walker.u32(), 3, "commande de la carte")
        _ = try walker.u32()  // l'ordre des octets, tel que la carte le garde
        let video = try walker.ram()
        expect(video.size, UInt64(Spec.videoMemory), "mémoire vidéo couverte")
        expect(video.written.count, 16 * 16 * (2 + 3),
               "les deux carrés peints : deux octets non nuls par point, puis trois")

        // La tablette.
        try walker.section("WISQ_tab")
        expect(try walker.u64(), Spec.tabletBase, "BAR de la tablette")
        expect(try walker.u32(), 6, "commande de la tablette")
        expect(try walker.u32(), UInt32(Spec.tabletLine), "ligne de la tablette")
        expect(try walker.u32(), 15, "état de la tablette")
        expect(try walker.u64(), 1 << 32, "fonctions acceptées")
        expect(try walker.u32(), 0, "file choisie")
        _ = try walker.u32()  // la question de configuration en cours
        _ = try walker.u32()  // l'interruption en attente
        let tabletQueue = try walker.u32()
        expect(tabletQueue & 0xFFFF, 8, "taille de la file des événements")
        expect(tabletQueue >> 16 & 1, 1, "file des événements activée")
        for (index, ring) in Spec.tabletRings.enumerated() { expect(try walker.u64(), ring, "anneau \(index)") }
        _ = try walker.u32()  // ses index
        _ = try walker.take(4 + 3 * 8 + 4)  // la file d'état, jamais posée

        // La carte réseau et son pont.
        try walker.section("WISQ_net")
        for byte in Spec.mac { expect(try walker.u32(), UInt32(byte), "adresse MAC") }
        for page in Spec.networkQueuePages {
            expect(try walker.u32(), page, "page d'une file réseau")
            expect(try walker.u32(), 0, "index des disponibles")
            expect(try walker.u32(), 0, "index des servies")
        }
        expect(try walker.u32(), 1, "file réseau choisie")
        expect(try walker.u32(), Spec.macFeature, "fonctions réseau acceptées")
        expect(try walker.u32(), 7, "état de la carte réseau")
        expect(try walker.u32(), 0, "interruption réseau")
        try walkBridge(&walker, window: Spec.networkWindow, line: Spec.networkLine, level: level)

        // Le premier disque, sans marque, sur fichier : « ailleurs ».
        expect(try walker.u32(), 0, "disque, choix des fonctions")
        expect(try walker.u32(), 0, "disque, choix des fonctions du pilote")
        expect(try walker.u64(), 0, "disque, fonctions du pilote")
        expect(try walker.u32(), 7, "disque, état")
        expect(try walker.u32(), 0, "disque, file choisie")
        expect(try walker.u32(), Spec.blockQueueSize, "disque, taille de la file")
        expect(try walker.u32(), 1, "disque, file prête")
        for (wanted, what) in zip(Spec.diskRings, ["descripteurs", "disponibles", "servies"]) {
            expect(try walker.u64(), wanted, "disque, \(what)")
        }
        expect(try walker.u32(), Spec.diskQueuePage, "disque, page de la file")
        expect(try walker.u32(), 1, "disque, interruption en attente")
        expect(try walker.u32(), 1, "disque, index des disponibles")
        expect(try walker.u32(), 1, "disque, index des servies")
        expect(try walker.u64(), 1, "disque, requêtes servies")
        expect(try walker.u64(), 0, "disque, requêtes refusées")
        expect(try walker.u64(), .max, "disque, contenu ailleurs")
        try walkBridge(&walker, window: Spec.diskWindow, line: Spec.diskLine, level: level,
                       address: Spec.busAddress)

        // Le second disque, derrière sa marque.
        try walker.section("WISQ_vdb")
        expect(try walker.u32(), 0, "second disque, choix des fonctions")
        expect(try walker.u32(), 0, "second disque, choix des fonctions du pilote")
        expect(try walker.u64(), 0, "second disque, fonctions du pilote")
        expect(try walker.u32(), 7, "second disque, état")
        expect(try walker.u32(), 0, "second disque, file choisie")
        expect(try walker.u32(), Spec.blockQueueSize, "second disque, taille de la file")
        expect(try walker.u32(), 1, "second disque, file prête")
        for (wanted, what) in zip(Spec.secondDiskRings, ["descripteurs", "disponibles", "servies"]) {
            expect(try walker.u64(), wanted, "second disque, \(what)")
        }
        expect(try walker.u32(), Spec.secondDiskQueuePage, "second disque, page de la file")
        for what in ["interruption", "disponibles", "servies"] { expect(try walker.u32(), 0, "second disque, \(what)") }
        expect(try walker.u64(), 0, "second disque, servies")
        expect(try walker.u64(), 0, "second disque, refusées")
        expect(try walker.u64(), .max, "second disque, contenu ailleurs")
        try walkBridge(&walker, window: Spec.secondDiskWindow, line: Spec.secondDiskLine, level: level,
                       address: Spec.busAddress)

        expect(walker.at, walker.bytes.count, "des octets après le second disque")
    }

    /// L'état d'un hôte PCI : l'adresse, la commande, la fenêtre, la ligne,
    /// la mesure en cours.
    static func walkBridge(_ walker: inout Walker, window: UInt32, line: UInt8, level: UInt64,
                           address: UInt32 = Spec.busAddress) throws {
        XCTAssertEqual(try walker.u32(), address, "témoin \(level) : dernière adresse du bus")
        XCTAssertEqual(try walker.u32(), 5, "témoin \(level) : commande")
        XCTAssertEqual(try walker.u32(), window, "témoin \(level) : fenêtre")
        XCTAssertEqual(try walker.u32(), UInt32(line), "témoin \(level) : ligne")
        XCTAssertEqual(try walker.u32(), 0, "témoin \(level) : mesure de la fenêtre")
    }

    // MARK: - Ce que la machine d'aujourd'hui en refait

    /// Lire la configuration PCI par les ports, comme un noyau qui énumère.
    static func configuration(_ machine: X86Machine, slot: UInt32, register: UInt32) -> UInt32 {
        machine.core.portWrite(0xCF8, 4, UInt64(0x8000_0000 | slot << 11 | register))
        return UInt32(truncatingIfNeeded: machine.core.portRead(0xCFC, 4))
    }

    static func checkResumed(_ machine: X86Machine, level: UInt64,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        func expect<T: Equatable>(_ read: T, _ wanted: T, _ what: String) {
            XCTAssertEqual(read, wanted, "témoin \(level) repris : \(what)", file: file, line: line)
        }
        expect((0..<16).map { machine.core.registers[$0] }, (0..<16).map(Spec.register), "registres")
        expect(machine.core.rip, Spec.rip, "rip")
        expect(machine.core.retired, Spec.retired, "instructions retirées")
        expect(machine.core.system.control, (0..<16).map(Spec.control), "registres de contrôle")
        expect(machine.core.system.modelSpecific.sorted { $0.key < $1.key }.map(\.value),
               Spec.modelSpecific.map(\.1), "MSR")
        expect(machine.core.segments, Spec.segments, "segments")
        expect(machine.core.x87, (0..<8).map(Spec.x87), "pile x87")
        expect(machine.core.xcr0, Spec.xcr0, "XCR0")
        expect(machine.core.upperVectors, (0..<32).map(Spec.upperVector), "haut des YMM")
        expect(machine.core.instructionsPerTick, Spec.instructionsPerTick, "instructions par battement")
        expect(machine.core.devices.serial.divisor, 1, "diviseur du 16550")
        expect(machine.core.serialInput, Spec.typedInPort + Spec.typedQueued, "ce qui est tapé")
        expect(machine.memory.dump(Spec.markAt, Spec.mark.count), Spec.mark, "la marque en mémoire")
        expect(try machine.memory.read(UInt64(ramSize) - 8, 8), Spec.lastWord, "le dernier mot")

        // **Chaque périphérique là où l'invité l'a trouvé**, par les ports.
        expect(configuration(machine, slot: 0, register: 0), 0x1237_8086, "le pont en 00:00.0")
        expect(configuration(machine, slot: Spec.displaySlot, register: 0), 0x1111_1234, "la carte graphique")
        expect(configuration(machine, slot: Spec.displaySlot, register: 0x10) & ~0xF,
               UInt32(Spec.displayBase), "la mémoire vidéo là où l'invité l'a mise")
        for (slot, identity, window, what) in [
            (Spec.diskSlot, UInt32(0x1001_1AF4), Spec.diskWindow, "le disque"),
            (Spec.secondDiskSlot, UInt32(0x1001_1AF4), Spec.secondDiskWindow, "le second disque"),
            (Spec.networkSlot, UInt32(0x1000_1AF4), Spec.networkWindow, "la carte réseau"),
        ] as [(UInt32, UInt32, UInt32, String)] {
            expect(configuration(machine, slot: slot, register: 0), identity, "\(what) en 00:0\(slot).0")
            expect(configuration(machine, slot: slot, register: 0x04) & 0x7, 5, "\(what), ses ports ouverts")
            expect(configuration(machine, slot: slot, register: 0x10) & ~0x3, window, "\(what), sa fenêtre")
        }
        expect(configuration(machine, slot: Spec.tabletSlot, register: 0), 0x1052_1AF4, "la tablette")
        // Les emplacements que le témoin a programmés sont, eux, à l'adresse
        // fixée par l'invité ; au-delà, rien.
        expect(configuration(machine, slot: 6, register: 0), 0xFFFF_FFFF, "rien en 00:06.0")

        // Par les fenêtres : ce que les pilotes relisent.
        expect(machine.core.portRead(UInt16(Spec.diskWindow + 0x12), 1), 7, "état du disque, par sa fenêtre")
        expect(machine.core.portRead(UInt16(Spec.diskWindow + 0x08), 4), UInt64(Spec.diskQueuePage),
               "page de la file du disque")
        expect(machine.core.portRead(UInt16(Spec.secondDiskWindow + 0x08), 4), UInt64(Spec.secondDiskQueuePage),
               "page de la file du second disque")
        expect(machine.core.portRead(UInt16(Spec.networkWindow + 0x12), 1), 7, "état de la carte réseau")
        expect(machine.disk?.served, 1, "la requête servie")
        expect(machine.secondDisk?.sectors, UInt64(secondDiskBytes / 512), "le second disque branché")
        expect(machine.network?.mac, Spec.mac, "l'adresse de la carte")
        expect(machine.network?.backend != nil, true, "le réseau de la machine qui reprend")
        expect(machine.tablet?.isReady, true, "la tablette prête")
        expect(machine.display?.base, Spec.displayBase, "l'écran à sa base")
        let pixels = try XCTUnwrap(machine.display?.snapshot())
        // La page montrée est la seconde : son carré, à (8, 8).
        let shown = (8 * 1024 + 8) * 4
        expect(Array(pixels[shown..<shown + 4]), [0xFF, 0xC0, 0x40, 0x00], "le carré de la page montrée")
    }
}
