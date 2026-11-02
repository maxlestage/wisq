import XCTest

@testable import WisqVM

/// **La tablette virtio, conduite comme Linux la conduit** : `virtio_pci`
/// parcourt les capacités, `virtio_pci_modern` négocie et pose les files,
/// `virtio_input` lit le nom, les bits et les axes, offre ses tampons, et
/// lit ce qui y tombe. Voir `VirtioTablet`.
final class VirtioTabletTests: XCTestCase {
    let descriptors: UInt64 = 0x1000, available: UInt64 = 0x2000, used: UInt64 = 0x3000
    let buffers: UInt64 = 0x4000

    func makeMemory() -> X86Memory { X86Memory(size: 0x10000, base: 0) }

    /// La BAR posée, la mémoire du périphérique allumée.
    func placed() -> VirtioTablet {
        let tablet = VirtioTablet(interruptLine: 10)
        tablet.writeConfiguration(0x10, 0xFE00_0000)
        tablet.writeConfiguration(0x04, 0x0006)
        return tablet
    }

    /// La poignée de main de `virtio_pci_modern`, puis la file des
    /// événements posée et garnie de `count` tampons de huit octets.
    func started(_ memory: X86Memory, count: Int = 8) throws -> VirtioTablet {
        let tablet = placed()
        tablet.write(0x14, 1, 0, memory)                  // remise à zéro
        tablet.write(0x14, 1, 1 | 2, memory)              // ACKNOWLEDGE | DRIVER
        tablet.write(0x00, 4, 1, memory)                  // les bits 32 à 63 offerts…
        XCTAssertEqual(tablet.read(0x04, 4), 1, "VIRTIO_F_VERSION_1")
        tablet.write(0x08, 4, 1, memory)
        tablet.write(0x0C, 4, 1, memory)                  // …acceptés
        tablet.write(0x14, 1, 1 | 2 | 8, memory)          // FEATURES_OK
        XCTAssertEqual(tablet.read(0x14, 1) & 8, 8, "le périphérique garde FEATURES_OK")
        tablet.write(0x16, 2, 0, memory)                  // la file des événements
        tablet.write(0x18, 2, 8, memory)
        tablet.write(0x1A, 2, 0, memory)                  // un vecteur MSI-X…
        XCTAssertEqual(tablet.read(0x1A, 2), 0xFFFF, "…refusé : l'INTx sert")
        tablet.write(0x20, 8, descriptors, memory)
        tablet.write(0x28, 4, available, memory)          // en deux moitiés, comme sur 32 bits
        tablet.write(0x2C, 4, 0, memory)
        tablet.write(0x30, 8, used, memory)
        tablet.write(0x1C, 2, 1, memory)                  // activée
        tablet.write(0x14, 1, 1 | 2 | 8 | 4, memory)      // DRIVER_OK
        // Les huit descripteurs existent ; seuls les `count` premiers sont
        // offerts.
        for index in 0..<8 {
            let at = descriptors + UInt64(index) * 16
            try memory.write(at, 8, buffers + UInt64(index) * 8)
            try memory.write(at + 8, 4, 8)
            try memory.write(at + 12, 2, 2)               // VRING_DESC_F_WRITE
        }
        for index in 0..<count {
            try memory.write(available + 4 + UInt64(index) * 2, 2, UInt64(index))
        }
        try memory.write(available + 2, 2, UInt64(count))
        return tablet
    }

    /// Les événements rendus, dans l'ordre : (type, code, valeur).
    func events(_ memory: X86Memory) throws -> [[UInt32]] {
        let count = try memory.read(used + 2, 2)
        return try (0..<count).map { slot in
            let head = try memory.read(used + 4 + slot * 8, 4)
            let at = buffers + head * 8
            return [UInt32(try memory.read(at, 2)), UInt32(try memory.read(at + 2, 2)),
                    UInt32(try memory.read(at + 4, 4))]
        }
    }

    // MARK: - Ce que voit `virtio_pci`

    /// **L'identité et la liste des capacités** : 1AF4:1052, révision 1, et
    /// les quatre structures, chaînées, chacune dans la BAR0 à son décalage.
    func testThePCIConfigurationListsTheFourStructures() {
        let tablet = placed()
        XCTAssertEqual(tablet.configuration(0x00), 0x1052_1AF4)
        XCTAssertEqual(tablet.configuration(0x08) & 0xFF, 1, "révision 1 : moderne")
        XCTAssertNotEqual(tablet.configuration(0x04) & (1 << 20), 0, "liste de capacités présente")
        var found: [(type: UInt32, offset: UInt32, length: UInt32)] = []
        var at = tablet.configuration(0x34) & 0xFF
        while at != 0, found.count < 8 {
            let head = tablet.configuration(at)
            XCTAssertEqual(head & 0xFF, 0x09, "propre au vendeur")
            XCTAssertEqual(tablet.configuration(at + 4) & 0xFF, 0, "dans la BAR0")
            found.append((head >> 24, tablet.configuration(at + 8), tablet.configuration(at + 12)))
            if head >> 24 == 2 { XCTAssertEqual(tablet.configuration(at + 16), 4, "le multiplicateur") }
            at = (head >> 8) & 0xFF
        }
        XCTAssertEqual(found.map(\.type).sorted(), [1, 2, 3, 4])
        for entry in found {
            XCTAssertLessThanOrEqual(UInt64(entry.offset) + UInt64(entry.length), VirtioTablet.barBytes)
        }
    }

    /// **La BAR0 se mesure et se pose** comme toute BAR de seize kibioctets,
    /// et ne répond qu'une fois la mémoire du périphérique allumée.
    func testTheBarIsSizedPlacedAndGated() {
        let tablet = VirtioTablet(interruptLine: 10)
        tablet.writeConfiguration(0x10, 0xFFFF_FFFF)
        XCTAssertEqual(tablet.configuration(0x10), 0xFFFF_C000)
        tablet.writeConfiguration(0x10, 0xFE00_1234)
        XCTAssertEqual(tablet.configuration(0x10), 0xFE00_0000)
        XCTAssertNil(tablet.registerOffset(0xFE00_0014, 1), "mémoire du périphérique éteinte")
        tablet.writeConfiguration(0x04, 0x0002)
        XCTAssertEqual(tablet.registerOffset(0xFE00_2004, 4), 0x2004)
        XCTAssertNil(tablet.registerOffset(0xFE00_3FFE, 4), "à cheval sur la fin")
    }

    // MARK: - Ce que lit `virtio_input`

    /// **Le nom, les boutons, les axes et la molette**, par `select` et
    /// `subsel`, avec leur taille ; une question sans réponse a une taille
    /// nulle.
    func testTheConfigurationAnswersWhatVirtioInputAsks() {
        let tablet = placed()
        let memory = makeMemory()
        func ask(_ select: UInt8, _ subselect: UInt8) -> [UInt8] {
            tablet.write(0x2000, 1, UInt64(select), memory)
            tablet.write(0x2001, 1, UInt64(subselect), memory)
            let size = Int(tablet.read(0x2002, 1))
            return (0..<size).map { UInt8(tablet.read(0x2008 + UInt64($0), 1)) }
        }
        XCTAssertEqual(String(decoding: ask(0x01, 0), as: UTF8.self), "wisq tablet")
        let keys = ask(0x11, 0x01)
        for code in [0x110, 0x111, 0x112] {
            XCTAssertNotEqual(keys[code / 8] & (1 << (code % 8)), 0, "bouton \(code)")
        }
        XCTAssertEqual(ask(0x11, 0x03), [0x03], "ABS_X et ABS_Y")
        XCTAssertEqual(ask(0x11, 0x02), [0x00, 0x01], "REL_WHEEL")
        let info = ask(0x12, 0x01)
        XCTAssertEqual(info.count, 20)
        XCTAssertEqual(UInt32(info[4]) | UInt32(info[5]) << 8, 0x7FFF, "le maximum de l'axe")
        XCTAssertEqual(ask(0x11, 0x05), [], "pas de EV_SW")
        XCTAssertEqual(ask(0x02, 0), [], "pas de numéro de série")
        // Lu d'un coup sur quatre octets, comme `virtio_cread`.
        tablet.write(0x2000, 2, 0x0012, memory)
        XCTAssertEqual(tablet.read(0x2000, 4) & 0xFF_FFFF, 0x14_0012)
    }

    // MARK: - Les événements

    /// **Un toucher arrive en un paquet** : X, Y, les trois boutons, puis
    /// `SYN_REPORT`, chacun dans son tampon, et l'interruption levée.
    func testATouchArrivesAsOnePacket() throws {
        let memory = makeMemory()
        let tablet = try started(memory)
        tablet.point(x: 0.5, y: 1.25, buttons: 1)
        tablet.deliver(memory)
        XCTAssertEqual(try events(memory), [
            [3, 0, 16384], [3, 1, 32767], [1, 0x110, 1], [1, 0x111, 0], [1, 0x112, 0], [0, 0, 0],
        ])
        XCTAssertTrue(tablet.interrupting)
        XCTAssertEqual(tablet.read(0x1000, 1), 1, "l'ISR dit la file")
        XCTAssertFalse(tablet.interrupting, "lire l'ISR l'efface")
        XCTAssertFalse(tablet.hasPending)
    }

    /// **Faute de tampons, les événements attendent** — dans l'ordre — et
    /// partent à la sonnette suivante. La molette va vers le haut en positif.
    func testEventsWaitForBuffersAndKeepTheirOrder() throws {
        let memory = makeMemory()
        let tablet = try started(memory, count: 2)
        tablet.scroll(-1)
        tablet.point(x: 0, y: 0, buttons: 0)
        tablet.deliver(memory)
        XCTAssertEqual(try events(memory), [[2, 8, UInt32(bitPattern: -1)], [0, 0, 0]])
        XCTAssertTrue(tablet.hasPending)
        // Deux tampons de plus, et la sonnette de la file zéro.
        for index in 2..<8 {
            try memory.write(available + 4 + UInt64(index) * 2, 2, UInt64(index))
        }
        try memory.write(available + 2, 2, 8)
        tablet.write(0x3000, 2, 0, memory)
        XCTAssertEqual(try events(memory).dropFirst(2).first, [3, 0, 0])
        XCTAssertEqual(try events(memory).count, 8)
    }

    /// **Rien ne part avant DRIVER_OK**, et une remise à zéro oublie ce qui
    /// attendait : un pilote qui recommence ne reçoit pas les gestes d'avant.
    func testNothingIsDeliveredBeforeTheDriverIsReadyAndResetForgets() throws {
        let memory = makeMemory()
        let tablet = try started(memory)
        // Les files posées et garnies, mais l'état retiré à FEATURES_OK.
        tablet.write(0x14, 1, 1 | 2 | 8, memory)
        tablet.point(x: 0.1, y: 0.1, buttons: 0)
        tablet.deliver(memory)
        XCTAssertFalse(tablet.interrupting)
        XCTAssertEqual(try memory.read(used + 2, 2), 0)
        XCTAssertTrue(tablet.hasPending)
        tablet.write(0x14, 1, 0, memory)
        XCTAssertFalse(tablet.hasPending)
    }

    /// **Le pilote n'accepte que ce qui est offert** : un bit inconnu écrit
    /// dans les fonctions du pilote ne reste pas.
    func testTheDriverCannotAcceptWhatIsNotOffered() {
        let memory = makeMemory()
        let tablet = placed()
        tablet.write(0x08, 4, 0, memory)
        tablet.write(0x0C, 4, 0xFFFF_FFFF, memory)
        tablet.write(0x08, 4, 1, memory)
        tablet.write(0x0C, 4, 0xFFFF_FFFF, memory)
        XCTAssertEqual(tablet.driverFeatures, 1 << 32)
    }

    // MARK: - Sur la machine

    /// **Un écran vient avec sa tablette** : en 00:07.0 sur le bus, sa BAR0
    /// déjà posée après les registres de la carte, ses registres joignables
    /// par la mémoire une fois allumée, et sa ligne levée quand un toucher
    /// arrive.
    func testTheScreenComesWithItsTablet() throws {
        let machine = try X86BochsDisplayTests.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let bus = try XCTUnwrap(memory.bus)
        bus.writeAddress(X86BochsDisplayTests.address(slot: VirtioTablet.slot, register: 0))
        XCTAssertEqual(bus.configuration(), 0x1052_1AF4)
        bus.writeAddress(X86BochsDisplayTests.address(slot: VirtioTablet.slot, register: 0x10))
        XCTAssertEqual(UInt64(bus.configuration()), X86Machine.tabletBase)
        bus.writeAddress(X86BochsDisplayTests.address(slot: VirtioTablet.slot, register: 0x04))
        bus.writeConfiguration(0x0006, 2, 0)
        // Le nom, lu par la mémoire comme le pilote le lit.
        try memory.write(X86Machine.tabletBase + 0x2000, 1, 1)
        XCTAssertEqual(try memory.read(X86Machine.tabletBase + 0x2002, 1), UInt64(VirtioTablet.name.utf8.count))
        XCTAssertNil(X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in }).tablet,
                     "sans écran, pas de tablette")
    }

    /// **La tablette revient avec la machine** : un pilote qui a posé ses
    /// files les retrouve, et le toucher d'après la reprise arrive.
    func testTheTabletComesBackWithTheMachine() throws {
        let saved = try X86BochsDisplayTests.machine()
        let memory = try XCTUnwrap(saved.core.memory)
        let tablet = try XCTUnwrap(saved.tablet)
        tablet.writeConfiguration(0x04, 0x0006)
        tablet.writeConfiguration(0x10, 0xF200_0000)
        tablet.write(0x14, 1, 1 | 2, memory)
        tablet.write(0x08, 4, 1, memory)
        tablet.write(0x0C, 4, 1, memory)
        tablet.write(0x16, 2, 0, memory)
        tablet.write(0x20, 8, 0x1000, memory)
        tablet.write(0x28, 8, 0x2000, memory)
        tablet.write(0x30, 8, 0x3000, memory)
        tablet.write(0x1C, 2, 1, memory)
        tablet.write(0x14, 1, 1 | 2 | 8 | 4, memory)

        let resumed = try X86BochsDisplayTests.machine()
        try resumed.restore(saved.snapshot())
        let back = try XCTUnwrap(resumed.tablet)
        XCTAssertEqual(back.configuration(0x10), 0xF200_0000)
        XCTAssertEqual(back.status, 15)
        XCTAssertEqual(back.driverFeatures, 1 << 32)
        XCTAssertEqual(back.queues, tablet.queues)
        XCTAssertEqual(try resumed.core.memory?.read(0xF200_0014, 1), 15, "la BAR déplacée répond")
    }

    // MARK: - Le doigt

    /// **Un toucher ne passe par la tablette que si l'invité l'a prise** :
    /// avant DRIVER_OK, `touch` répond non et l'application garde la souris
    /// PS/2 ; après, le toucher attend son tampon.
    func testATouchGoesThroughTheTabletOnlyOnceTheGuestTookIt() throws {
        let machine = try X86BochsDisplayTests.machine()
        XCTAssertFalse(machine.touch(x: 0.5, y: 0.5, buttons: 1))
        let tablet = try XCTUnwrap(machine.tablet)
        XCTAssertFalse(tablet.hasPending)
        let memory = try XCTUnwrap(machine.core.memory)
        tablet.write(0x16, 2, 0, memory)
        tablet.write(0x1C, 2, 1, memory)
        tablet.write(0x14, 1, 1 | 2 | 8 | 4, memory)
        XCTAssertTrue(machine.touch(x: 0.5, y: 0.5, buttons: 1))
        XCTAssertTrue(tablet.hasPending)
    }

    /// **Où tombe le doigt** : rapporté à l'écran de l'invité, et rien dans
    /// la marge noire ni pour un écran sans taille.
    func testTheFingerIsPlacedOnTheGuestScreen() throws {
        let middle = try XCTUnwrap(ScreenTouch.fraction(x: 512, y: 384, width: 1024, height: 768))
        XCTAssertEqual(middle.x, 0.5)
        XCTAssertEqual(middle.y, 0.5)
        XCTAssertNotNil(ScreenTouch.fraction(x: 1024, y: 768, width: 1024, height: 768), "le bord compte")
        XCTAssertNil(ScreenTouch.fraction(x: -1, y: 10, width: 1024, height: 768))
        XCTAssertNil(ScreenTouch.fraction(x: 10, y: 769, width: 1024, height: 768))
        XCTAssertNil(ScreenTouch.fraction(x: 10, y: 10, width: 0, height: 768))
        XCTAssertNil(ScreenTouch.fraction(x: .nan, y: 10, width: 1024, height: 768))
    }
}
