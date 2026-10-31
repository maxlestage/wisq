import XCTest

@testable import WisqVM

/// **La carte graphique de QEMU**, telle que `bochs-drm` la voit : voir
/// `X86BochsDisplay`. Chaque test rejoue ce que le pilote fait
/// (`drivers/gpu/drm/tiny/bochs.c`) : trouver la carte sur le bus, lire ses
/// BAR, son identifiant et sa mémoire, poser un mode, changer de page.
final class X86BochsDisplayTests: XCTestCase {
    /// Une machine avec un écran 1024 × 768, sans disque ni réseau.
    static func machine() throws -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.attachDisplay(width: 1024, height: 768)
        return machine
    }

    static func address(slot: UInt32, register: UInt32) -> UInt32 {
        0x8000_0000 | (slot << 11) | register
    }

    /// Le mot de configuration de la carte à `register`.
    static func configuration(_ bus: X86PCIHost, _ register: UInt32) -> UInt32 {
        bus.writeAddress(address(slot: X86BochsDisplay.slot, register: register))
        return bus.configuration()
    }

    static func setConfiguration(_ bus: X86PCIHost, _ register: UInt32, _ value: UInt32) {
        bus.writeAddress(address(slot: X86BochsDisplay.slot, register: register))
        bus.writeConfiguration(value, 4, 0)
    }

    /// Un registre DISPI, par la BAR2, comme le pilote quand il l'a.
    static func dispi(_ memory: X86Memory, _ register: Int) throws -> UInt64 {
        try memory.read(X86Machine.displayRegistersBase + 0x500 + UInt64(register * 2), 2)
    }

    static func setDispi(_ memory: X86Memory, _ register: Int, _ value: UInt64) throws {
        try memory.write(X86Machine.displayRegistersBase + 0x500 + UInt64(register * 2), 2, value)
    }

    /// **Ce que `bochs_hw_setmode` écrit**, dans son ordre : la carte
    /// éteinte, la profondeur, la taille, la banque, la taille virtuelle, les
    /// décalages, puis la carte rallumée en cadre linéaire.
    static func setMode(_ memory: X86Memory, width: UInt64, height: UInt64) throws {
        try setDispi(memory, 4, 0)
        try setDispi(memory, 3, 32)
        try setDispi(memory, 1, width)
        try setDispi(memory, 2, height)
        try setDispi(memory, 5, 0)
        try setDispi(memory, 6, width)
        try setDispi(memory, 7, UInt64(X86BochsDisplay.memoryBytes) / (width * 4))
        try setDispi(memory, 8, 0)
        try setDispi(memory, 9, 0)
        try setDispi(memory, 4, 0x41)
    }

    // MARK: - Sur le bus

    /// **La carte est en 00:02.0**, avec l'identité que le pilote cherche :
    /// 1234:1111, contrôleur VGA, révision 2, sous-système de QEMU. Et même
    /// sans disque ni réseau : une machine qui n'a qu'un écran a un bus.
    func testTheCardIsOnTheBusWhereThePilotLooks() throws {
        let machine = try Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus, "un écran seul doit avoir un bus")
        XCTAssertEqual(Self.configuration(bus, 0x00), 0x1111_1234)
        XCTAssertEqual(Self.configuration(bus, 0x08), 0x0300_0002)
        XCTAssertEqual(Self.configuration(bus, 0x2C), 0x1100_1AF4)
        XCTAssertEqual(Self.configuration(bus, 0x04) & 0x03, 0x03, "mémoire et ports décodés")
        bus.writeAddress(Self.address(slot: 1, register: 0))
        XCTAssertEqual(bus.configuration(), 0xFFFF_FFFF, "rien en 00:01.0")
    }

    /// **Les deux BAR** : la mémoire vidéo là où était déjà le cadre du
    /// démarrage, préchargeable, et les registres juste après. Et leur taille
    /// se mesure comme toujours : des uns écrits, le masque relu, l'adresse
    /// remise.
    func testTheBarsSayWhereAndHowLarge() throws {
        let machine = try Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus)
        XCTAssertEqual(Self.configuration(bus, 0x10), UInt32(X86Machine.displayBase) | 0x08)
        XCTAssertEqual(Self.configuration(bus, 0x18), UInt32(X86Machine.displayRegistersBase))
        Self.setConfiguration(bus, 0x10, 0xFFFF_FFFF)
        XCTAssertEqual(Self.configuration(bus, 0x10), 0xFF00_0008, "seize mébioctets")
        Self.setConfiguration(bus, 0x10, UInt32(X86Machine.displayBase) | 0x08)
        Self.setConfiguration(bus, 0x18, 0xFFFF_FFFF)
        XCTAssertEqual(Self.configuration(bus, 0x18), 0xFFFF_F000, "quatre kibioctets")
        Self.setConfiguration(bus, 0x18, UInt32(X86Machine.displayRegistersBase))
        XCTAssertEqual(machine.display?.base, X86Machine.displayBase, "la mesure ne déplace rien")
        XCTAssertEqual(Self.configuration(bus, 0x18), UInt32(X86Machine.displayRegistersBase))
    }

    /// **Le noyau peut déplacer les BAR**, et la carte le suit : la mémoire
    /// vidéo répond à sa nouvelle adresse, plus à l'ancienne.
    func testMovedBarsAreFollowed() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let bus = try XCTUnwrap(memory.bus)
        Self.setConfiguration(bus, 0x10, 0xF000_0008)
        Self.setConfiguration(bus, 0x18, 0xF100_0000)
        try memory.write(0xF000_0010, 4, 0x00AB_CDEF)
        XCTAssertEqual(try machine.display.map { Array($0.snapshot()[16..<20]) }, [0xEF, 0xCD, 0xAB, 0])
        XCTAssertThrowsError(try memory.write(X86Machine.displayBase, 4, 1), "l'ancienne adresse est vide")
        XCTAssertEqual(try memory.read(0xF100_0500, 2), 0xB0C5, "les registres aussi")
    }

    /// Un disque branché refait le pont : la carte y reste.
    func testAttachingADiskKeepsTheCard() throws {
        let machine = try Self.machine()
        machine.attach(disk: [UInt8](repeating: 0, count: 4096))
        let bus = try XCTUnwrap(machine.core.memory?.bus)
        XCTAssertEqual(Self.configuration(bus, 0x00), 0x1111_1234)
        machine.detachDisk()
        XCTAssertEqual(Self.configuration(try XCTUnwrap(machine.core.memory?.bus), 0x00), 0x1111_1234)
    }

    // MARK: - Les registres

    /// **Ce que `bochs_hw_init` lit** : l'identifiant (0xB0C0 à 0xB0C5), la
    /// mémoire en unités de 64 Kio, la taille des registres étendus de QEMU.
    /// Et l'EDID absent : des zéros, que le pilote prend pour « pas d'EDID ».
    func testWhatThePilotReadsAtProbe() throws {
        let memory = try XCTUnwrap(try Self.machine().core.memory)
        XCTAssertEqual(try Self.dispi(memory, 0), 0xB0C5)
        XCTAssertEqual(try Self.dispi(memory, 10), 256, "seize mébioctets")
        XCTAssertEqual(try memory.read(X86Machine.displayRegistersBase + 0x600, 4), 8)
        try memory.write(X86Machine.displayRegistersBase + 0x604, 4, 0x1E1E_1E1E)
        XCTAssertEqual(try memory.read(X86Machine.displayRegistersBase + 0x604, 4), 0x1E1E_1E1E)
        XCTAssertEqual(try memory.read(X86Machine.displayRegistersBase, 8), 0, "pas d'en-tête EDID")
    }

    /// **Le mode que le pilote pose est celui que l'écran montre**, et
    /// éteindre la carte ramène le cadre du démarrage.
    func testTheModeThePilotSetsIsTheOneShown() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let screen = try XCTUnwrap(machine.display)
        XCTAssertEqual(screen.mode, screen.bootMode)
        try Self.setMode(memory, width: 800, height: 600)
        XCTAssertEqual(screen.mode, X86Framebuffer.Mode(width: 800, height: 600, bytesPerRow: 3200, start: 0))
        try Self.setDispi(memory, 4, 0)
        XCTAssertEqual(screen.mode, screen.bootMode)
    }

    /// **Changer de page** (`bochs_hw_setbase`) : la largeur virtuelle et les
    /// décalages disent où commence l'image montrée.
    func testFlippingAPageMovesTheStart() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let screen = try XCTUnwrap(machine.display)
        try Self.setMode(memory, width: 640, height: 480)
        try Self.setDispi(memory, 6, 640)
        try Self.setDispi(memory, 8, 0)
        try Self.setDispi(memory, 9, 480)
        XCTAssertEqual(screen.mode.start, 480 * 640 * 4)
        // L'image montrée vient bien de là.
        try memory.write(X86Machine.displayBase + UInt64(480 * 640 * 4), 4, 0x0012_3456)
        XCTAssertEqual(Array(screen.snapshot()[0..<4]), [0x56, 0x34, 0x12, 0])
    }

    /// **Une ligne virtuelle plus longue que l'image** : la vue en lit les
    /// pixels montrés, ligne à ligne, sans le remplissage.
    func testAWiderVirtualLineIsReadWithoutItsPadding() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let screen = try XCTUnwrap(machine.display)
        try Self.setMode(memory, width: 8, height: 2)
        try Self.setDispi(memory, 6, 16)
        try memory.write(X86Machine.displayBase + 64, 4, 0x0000_00AA)  // deuxième ligne, premier pixel
        let frame = screen.frame()
        XCTAssertEqual(frame.mode.bytesPerRow, 64)
        XCTAssertEqual(frame.data.count, 8 * 2 * 4)
        XCTAssertEqual(frame.data[32], 0xAA)
    }

    /// **Un mode qui ne tient pas dans la mémoire vidéo ne s'affiche pas** :
    /// l'écran garde ce qu'il montrait — un décalage de trop laisse le mode
    /// en place, une taille de trop laisse le cadre du démarrage, que la
    /// carte éteinte avait remis —, et la vue ne lit jamais au-delà des
    /// pixels.
    func testAModeThatDoesNotFitIsRefused() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let screen = try XCTUnwrap(machine.display)
        try Self.setMode(memory, width: 800, height: 600)
        try Self.setDispi(memory, 9, 7000)
        XCTAssertEqual(screen.mode.start, 0, "le décalage de trop est refusé")
        try Self.setMode(memory, width: 4096, height: 4096)
        XCTAssertEqual(screen.mode, screen.bootMode)
    }

    /// Allumer la carte efface ce qu'elle va montrer, comme QEMU ; avec
    /// `NOCLEARMEM`, non.
    func testEnablingClearsUnlessAskedNotTo() throws {
        let machine = try Self.machine()
        let memory = try XCTUnwrap(machine.core.memory)
        let screen = try XCTUnwrap(machine.display)
        try memory.write(X86Machine.displayBase, 4, 0x00FF_FFFF)
        try Self.setMode(memory, width: 640, height: 480)
        XCTAssertEqual(Array(screen.snapshot()[0..<4]), [0, 0, 0, 0])
        try Self.setDispi(memory, 4, 0)
        try memory.write(X86Machine.displayBase, 4, 0x00FF_FFFF)
        try Self.setDispi(memory, 4, 0xC1)
        XCTAssertEqual(Array(screen.snapshot()[0..<4]), [0xFF, 0xFF, 0xFF, 0])
    }

    /// Sous `GETCAPS`, la taille et la profondeur se lisent à leur maximum.
    func testCapabilitiesReadTheMaximums() throws {
        let memory = try XCTUnwrap(try Self.machine().core.memory)
        try Self.setDispi(memory, 4, 0x02)
        XCTAssertEqual(try Self.dispi(memory, 1), UInt64(X86BochsDisplay.maximumWidth))
        XCTAssertEqual(try Self.dispi(memory, 2), UInt64(X86BochsDisplay.maximumHeight))
        XCTAssertEqual(try Self.dispi(memory, 3), 32)
    }

    /// **Les mêmes registres par les ports** 0x1CE et 0x1CF, pour un pilote
    /// sans BAR2 : l'index, puis la donnée.
    func testTheSameRegistersThroughThePorts() throws {
        let machine = try Self.machine()
        machine.core.portWrite(X86BochsDisplay.indexPort, 2, 0)
        XCTAssertEqual(machine.core.portRead(X86BochsDisplay.dataPort, 2), 0xB0C5)
        machine.core.portWrite(X86BochsDisplay.indexPort, 2, 1)
        machine.core.portWrite(X86BochsDisplay.dataPort, 2, 320)
        XCTAssertEqual(machine.vga?.readRegister(1), 320)
    }

    // MARK: - L'instantané

    /// **La carte et sa mémoire reviennent avec la machine** : le mode, la
    /// page montrée, les pixels, et une BAR déplacée.
    func testTheCardComesBackWithTheMachine() throws {
        let saved = try Self.machine()
        let memory = try XCTUnwrap(saved.core.memory)
        try Self.setMode(memory, width: 640, height: 480)
        try Self.setDispi(memory, 9, 10)
        try memory.write(X86Machine.displayBase + UInt64(10 * 640 * 4), 4, 0x0077_8899)
        Self.setConfiguration(try XCTUnwrap(memory.bus), 0x18, 0xF100_0000)

        let resumed = try Self.machine()
        try resumed.restore(saved.snapshot())
        XCTAssertEqual(resumed.display?.mode, saved.display?.mode)
        XCTAssertEqual(resumed.display?.snapshot(), saved.display?.snapshot())
        XCTAssertEqual(resumed.vga?.state, saved.vga?.state)
        XCTAssertEqual(try resumed.core.memory?.read(0xF100_0500, 2), 0xB0C5)
    }
}
