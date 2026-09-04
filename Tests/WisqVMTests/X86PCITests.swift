import XCTest

@testable import WisqVM

/// Le bus PCI, conduit comme le noyau le conduit.
///
/// **Ce que ces tests tiennent.** Sans réponse aux ports 0xCF8 et 0xCFC, le
/// noyau conclut « PCI: Fatal: No config space access function found », puis
/// « PCI: System does not support PCI », et aucun périphérique n'existera
/// jamais — c'est ce que disait le journal de démarrage de wisq avant ce
/// fichier. Avec, il énumère : il demande le fabricant de chaque
/// emplacement, mesure la fenêtre de ports que le périphérique réclame, la
/// place, l'active, et lit sa ligne d'interruption. Chaque étape est ici, et
/// l'oubli d'une seule suffit à ce que le disque n'apparaisse pas.
final class X86PCITests: XCTestCase {
    static func addressOf(slot: UInt32, register: UInt32) -> UInt32 {
        0x8000_0000 | (slot << 11) | register
    }

    static func host() -> X86PCIHost {
        X86PCIHost(storage: X86VirtioBlock(image: [UInt8](repeating: 0, count: 8 * 512)))
    }

    /// L'emplacement qu'on occupe se présente ; les autres rendent **tous les
    /// uns**, ce qui est la façon dont un bus dit « il n'y a personne ». Des
    /// zéros feraient croire à un périphérique de fabricant zéro.
    func testOnlyOurSlotAnswers() {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0))
        XCTAssertEqual(bus.configuration(), 0x1001_1AF4, "virtio, en forme ancienne")
        bus.writeAddress(Self.addressOf(slot: 4, register: 0))
        XCTAssertEqual(bus.configuration(), 0xFFFF_FFFF)
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0) & ~0x8000_0000)
        XCTAssertEqual(bus.configuration(), 0xFFFF_FFFF, "sans le bit d'activation, rien")
    }

    /// Un bus sans disque est un bus vide : le noyau énumère, ne trouve rien,
    /// et continue. C'est une réponse, pas une panne.
    func testAnEmptyBusIsHonest() {
        let bus = X86PCIHost()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0))
        XCTAssertEqual(bus.configuration(), 0xFFFF_FFFF)
    }

    /// La classe et le sous-système : c'est par là que le noyau sait que
    /// c'est un disque, et c'est de là que vient le `modalias` qui fait
    /// charger le pilote tout seul au démarrage.
    func testItCallsItselfADisk() {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x08))
        XCTAssertEqual(bus.configuration() >> 24, 0x01, "stockage de masse")
        XCTAssertEqual(bus.configuration() & 0xFF, 0x00, "révision zéro : la forme ancienne")
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x2C))
        XCTAssertEqual(bus.configuration(), 0x0002_1AF4, "sous-système : un bloc virtio")
    }

    /// **La mesure de la fenêtre.** Le noyau écrit tous les uns et relit : les
    /// bits qui ne changent pas disent la taille. Répondre la fenêtre elle-même
    /// ferait croire à une fenêtre de quatre gigaoctets.
    func testTheWindowSizeIsMeasuredTheWayFirmwareExpects() {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x10))
        bus.writeConfiguration(0xFFFF_FFFF, 4, 0)
        XCTAssertEqual(bus.configuration(), ~(X86PCIHost.windowSize - 1) | 1,
                       "le masque de taille, avec le bit « ports »")
        bus.writeConfiguration(0xC000, 4, 0)
        XCTAssertEqual(bus.configuration(), 0xC000 | 1, "puis la fenêtre placée")
    }

    /// Une fenêtre placée mais pas activée ne répond pas : le noyau active les
    /// ports par le registre de commande, et un périphérique qui répondrait
    /// avant volerait des ports à un autre.
    func testTheWindowOpensOnlyWhenEnabled() {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x10))
        bus.writeConfiguration(0xC000, 4, 0)
        XCTAssertNil(bus.windowOffset(0xC000), "placée, mais pas ouverte")
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x04))
        bus.writeConfiguration(0x0005, 4, 0)  // ports + maîtrise du bus
        XCTAssertEqual(bus.windowOffset(0xC000), 0)
        XCTAssertEqual(bus.windowOffset(0xC012), 0x12)
        XCTAssertNil(bus.windowOffset(0xC040), "et pas un octet au-delà")
    }

    /// La ligne d'interruption est **écrite** par le noyau et relue par le
    /// pilote : c'est elle qui décide où le disque frappe.
    func testTheInterruptLineIsWhatTheKernelWrote() {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x3C))
        XCTAssertEqual(bus.configuration() >> 8 & 0xFF, 1, "broche A")
        bus.writeConfiguration(0x0000_010B, 1, 0)
        XCTAssertEqual(bus.interruptLine, 11)
        XCTAssertEqual(bus.configuration() & 0xFF, 11)
    }

    // MARK: - Par les instructions, pas par la porte de derrière

    static func core(_ code: [UInt8], _ bus: X86PCIHost) throws -> X86Core {
        let ram = X86Memory(size: 1 << 20, base: 0)
        try ram.load(code, at: 0x100)
        ram.bus = bus
        return X86Core(registers: [UInt64](repeating: 0, count: 16), rip: 0x100, memory: ram)
    }

    /// Le noyau demande le fabricant de l'emplacement trois avec deux `out` et
    /// un `in`, et c'est **par les instructions** que ça doit marcher.
    func testTheKernelFindsTheDeviceThroughTheInstructions() throws {
        let bus = Self.host()
        // mov $0xcf8,%dx ; mov $0x80001800,%eax ; out %eax,(%dx)
        // mov $0xcfc,%dx ; in (%dx),%eax
        var core = try Self.core([
            0x66, 0xBA, 0xF8, 0x0C,
            0xB8, 0x00, 0x18, 0x00, 0x80,
            0xEF,
            0x66, 0xBA, 0xFC, 0x0C,
            0xED,
        ], bus)
        try core.run(budget: 5)
        XCTAssertEqual(core.registers[0] & 0xFFFF_FFFF, 0x1001_1AF4)
    }

    /// **Un port s'écrit en deux octets quand le préfixe le dit.** La largeur
    /// était figée à quatre : un `outw` écrivait quatre octets, et le pilote
    /// virtio choisit sa file exactement comme ça.
    func testATwoByteWriteReachesTheDeviceAsTwoBytes() throws {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x10))
        bus.writeConfiguration(0xC000, 4, 0)
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x04))
        bus.writeConfiguration(0x0005, 4, 0)
        // mov $0xc00e,%dx ; mov $0xffff0001,%eax ; outw %ax,(%dx)
        var core = try Self.core([
            0x66, 0xBA, 0x0E, 0xC0,
            0xB8, 0x01, 0x00, 0xFF, 0xFF,
            0x66, 0xEF,
        ], bus)
        try core.run(budget: 3)
        let device = try XCTUnwrap(bus.storage)
        XCTAssertEqual(device.queueSelect, 1, "deux octets, et pas quatre")
    }

    /// Et la capacité se lit par la fenêtre, en deux mots de quatre octets,
    /// comme le pilote la lit.
    func testTheCapacityIsReadableThroughTheWindow() throws {
        let bus = Self.host()
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x10))
        bus.writeConfiguration(0xC000, 4, 0)
        bus.writeAddress(Self.addressOf(slot: X86PCIHost.slot, register: 0x04))
        bus.writeConfiguration(0x0001, 4, 0)
        // mov $0xc014,%dx ; in (%dx),%eax
        var core = try Self.core([0x66, 0xBA, 0x14, 0xC0, 0xED], bus)
        try core.run(budget: 2)
        XCTAssertEqual(core.registers[0] & 0xFFFF_FFFF, 8, "huit secteurs")
    }

    /// **Les trois anneaux de la forme ancienne se calculent à partir d'un
    /// seul nombre**, et se tromper d'un octet fait lire au périphérique un
    /// anneau que personne n'a écrit. C'est `vring_init`, à la lettre.
    func testTheOldFormPlacesItsRingsWhereTheDriverPutThem() {
        let size: UInt32 = 128
        let (descriptors, available, used) = X86VirtioBlock.rings(pageNumber: 4, size: size)
        XCTAssertEqual(descriptors, 4 * 4096)
        XCTAssertEqual(available, descriptors + 16 * UInt64(size))
        // Après l'anneau des disponibles — drapeaux, index, la table, et le
        // mot d'événement — on arrondit à la page suivante.
        let after = available + 6 + 2 * UInt64(size)
        XCTAssertEqual(used, (after + 4095) & ~UInt64(4095))
        XCTAssertEqual(used % 4096, 0)
    }
}
