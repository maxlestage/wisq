import XCTest

@testable import WisqVM

/// Le second disque de la machine PC : l'emplacement quatre du bus, `vdb`
/// pour le noyau — celui sur lequel on installe quand le premier est l'image.
final class X86SecondDiskTests: XCTestCase {
    private static func address(slot: UInt32, register: UInt32) -> UInt32 {
        X86PCITests.addressOf(slot: slot, register: register)
    }

    private static func disk(sectors: Int = 8, fill: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: fill, count: sectors * 512)
    }

    private static func machine(first: Bool = true, second: Bool = true) -> X86Machine {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        if first { machine.attach(disk: disk()) }
        if second { machine.attach(secondDisk: disk(sectors: 16, fill: 0xEE)) }
        return machine
    }

    // MARK: - Le bus

    /// L'emplacement quatre se présente comme un second disque virtio, le
    /// trois reste le premier, et **le pont n'est annoncé qu'une fois**.
    func testSlotFourIsASecondVirtioDiskAndTheBridgeStaysSingle() throws {
        let machine = Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus)

        bus.writeAddress(Self.address(slot: X86PCIHost.secondSlot, register: 0))
        XCTAssertEqual(bus.configuration(), 0x1001_1AF4)
        bus.writeAddress(Self.address(slot: X86PCIHost.secondSlot, register: 0x3C))
        XCTAssertEqual(bus.configuration() & 0xFF, UInt32(X86PCIHost.secondInterruptLine))
        bus.writeAddress(Self.address(slot: X86PCIHost.slot, register: 0x3C))
        XCTAssertEqual(bus.configuration() & 0xFF, UInt32(VirtioBlock.pc.interruptLine),
                       "deux lignes, pas une partagée")

        let second = try XCTUnwrap(bus.second)
        second.writeAddress(Self.address(slot: X86PCIHost.bridgeSlot, register: 0))
        XCTAssertEqual(second.configuration(), 0xFFFF_FFFF, "le second hôte ne se dit pas pont")
        bus.writeAddress(Self.address(slot: X86PCIHost.bridgeSlot, register: 0))
        XCTAssertEqual(bus.configuration() & 0xFFFF, 0x8086)
    }

    /// Sans second disque, l'emplacement quatre est vide — tous les uns.
    func testWithoutASecondDiskSlotFourIsEmpty() throws {
        let bus = try XCTUnwrap(Self.machine(second: false).core.memory?.bus)
        bus.writeAddress(Self.address(slot: X86PCIHost.secondSlot, register: 0))
        XCTAssertEqual(bus.configuration(), 0xFFFF_FFFF)
    }

    /// **Chaque disque a sa fenêtre**, placée et ouverte par le noyau, et un
    /// port de l'une ne tombe jamais sur l'autre.
    func testEachDiskAnswersItsOwnWindow() throws {
        let machine = Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus)
        for (slot, window) in [(X86PCIHost.slot, UInt32(0xC000)),
                               (X86PCIHost.secondSlot, UInt32(0xC040))] {
            bus.writeAddress(Self.address(slot: slot, register: 0x10))
            bus.writeConfiguration(window, 4, 0)
            bus.writeAddress(Self.address(slot: slot, register: 0x04))
            bus.writeConfiguration(0x0005, 2, 0)
        }
        XCTAssertTrue(bus.device(atPort: 0xC004)?.device === machine.disk)
        XCTAssertEqual(bus.device(atPort: 0xC004)?.offset, 4)
        XCTAssertTrue(bus.device(atPort: 0xC044)?.device === machine.secondDisk)
        XCTAssertEqual(bus.device(atPort: 0xC044)?.offset, 4)
        XCTAssertNil(bus.device(atPort: 0xC080))
        // La capacité du second, lue par sa fenêtre : seize secteurs.
        XCTAssertEqual(machine.secondDisk?.readPort(0x14, 4), 16)
        XCTAssertEqual(machine.disk?.readPort(0x14, 4), 8)
    }

    /// Brancher le premier après le second ne perd pas le second, et l'inverse.
    func testTheOrderOfAttachingDoesNotMatter() throws {
        let machine = Self.machine(first: false)
        machine.attach(disk: Self.disk())
        XCTAssertNotNil(machine.core.memory?.bus?.second, "le premier branché après garde le second")
        XCTAssertTrue(machine.core.memory?.bus?.second?.storage === machine.secondDisk)
        machine.detachDisk()
        XCTAssertNil(machine.secondDisk)
        XCTAssertNil(machine.core.memory?.bus)
    }

    // MARK: - L'instantané

    /// Le second disque revient, avec l'état que le noyau avait posé sur son
    /// emplacement — fenêtre, commande, ligne.
    func testTheSecondDiskComesBackFromASnapshot() throws {
        let machine = Self.machine()
        let bus = try XCTUnwrap(machine.core.memory?.bus)
        bus.writeAddress(Self.address(slot: X86PCIHost.secondSlot, register: 0x10))
        bus.writeConfiguration(0xC040, 4, 0)
        bus.writeAddress(Self.address(slot: X86PCIHost.secondSlot, register: 0x04))
        bus.writeConfiguration(0x0005, 2, 0)
        let before = try XCTUnwrap(bus.second)

        let restored = Self.machine(second: false)
        try restored.restore(machine.snapshot())
        let after = try XCTUnwrap(restored.core.memory?.bus?.second)
        XCTAssertEqual(after.window, before.window)
        XCTAssertEqual(after.command, before.command)
        XCTAssertEqual(after.interruptLine, before.interruptLine)
        XCTAssertEqual(after.deviceSlot, X86PCIHost.secondSlot)
        XCTAssertNotNil(restored.secondDisk)
        XCTAssertTrue(after.storage === restored.secondDisk)
        XCTAssertEqual(restored.secondDisk?.readPort(0x14, 4), 16, "et ses octets avec lui")
    }

    /// **Un instantané d'avant se relit tel qu'il était** : sans second
    /// disque, et la machine qui en avait un le perd plutôt que de garder un
    /// périphérique que l'instantané ne connaît pas.
    func testASnapshotWithoutTheSecondDiskReadsAsHavingNone() throws {
        let old = Self.machine(second: false).snapshot()
        let restored = Self.machine()
        try restored.restore(old)
        XCTAssertNil(restored.secondDisk)
        XCTAssertNil(restored.core.memory?.bus?.second)
        XCTAssertNotNil(restored.disk)
    }

    /// Un instantané au second disque tronqué refuse en entier.
    func testATruncatedSecondDiskSectionIsRefused() throws {
        let whole = Self.machine().snapshot()
        let restored = Self.machine(second: false)
        XCTAssertThrowsError(try restored.restore(whole.dropLast(4)))
        XCTAssertNil(restored.secondDisk, "rien n'a été repris à moitié")
    }

    // MARK: - Les autres machines

    /// La machine rv32 n'a qu'un disque, et le dit.
    func testTheRiscvMachineRefusesASecondDisk() {
        let machine: GuestMachine = LinuxMachine(onOutput: { _ in })
        let url = URL(fileURLWithPath: "/nulle-part")
        XCTAssertThrowsError(try machine.attachSecondDisk(fileAt: url, writes: url)) {
            XCTAssertEqual($0 as? GuestMachineRefusal, .noSecondDiskHere)
        }
    }
}
