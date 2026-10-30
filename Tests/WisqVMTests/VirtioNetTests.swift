import XCTest
@testable import WisqVM

/// La carte réseau virtio, conduite comme son pilote la conduit : des files
/// posées en mémoire, des tampons rendus disponibles, et le périphérique qui
/// les remplit ou les vide. Voir `VirtioNet`.
final class VirtioNetTests: XCTestCase {
    /// L'autre bout du câble, qui retient ce qu'on lui envoie.
    final class Cable: NetworkBackend {
        var sent: [[UInt8]] = []
        var incoming: [[UInt8]] = []
        func send(_ frame: [UInt8]) { sent.append(frame) }
        func receive() -> [[UInt8]] {
            defer { incoming.removeAll() }
            return incoming
        }
    }

    /// Un pilote minimal : une page par file, des tampons dans la mémoire qui
    /// suit, et les anneaux tenus comme Linux les tient.
    struct Driver {
        let memory = X86Memory(size: 1 << 20, base: 0)
        let nic: VirtioNet
        let pages: [UInt32] = [0x10, 0x20]
        var posted: [UInt16] = [0, 0]

        init(_ nic: VirtioNet) {
            self.nic = nic
            for queue in 0..<2 {
                nic.writePort(0x0E, 2, UInt64(queue), memory)
                nic.writePort(0x08, 4, UInt64(pages[queue]), memory)
            }
        }

        func rings(_ queue: Int) -> (UInt64, UInt64, UInt64) {
            VirtioBlock.rings(pageNumber: pages[queue], size: VirtioNet.queueLimit)
        }

        /// Un tampon de `length` octets à `address`, rendu disponible.
        mutating func post(_ queue: Int, address: UInt64, length: UInt32, writable: Bool) throws {
            let (descriptors, available, _) = rings(queue)
            let index = posted[queue]
            let at = descriptors + UInt64(index) * 16
            try memory.write(at, 8, address)
            try memory.write(at + 8, 4, UInt64(length))
            try memory.write(at + 12, 2, writable ? 2 : 0)
            try memory.write(at + 14, 2, 0)
            try memory.write(available + 4 + UInt64(index % UInt16(VirtioNet.queueLimit)) * 2, 2, UInt64(index))
            posted[queue] = index + 1
            try memory.write(available + 2, 2, UInt64(posted[queue]))
        }

        /// L'entrée `slot` de l'anneau des servies : la tête et la longueur.
        func used(_ queue: Int, _ slot: UInt64) throws -> (head: UInt64, length: UInt64, index: UInt64) {
            let (_, _, used) = rings(queue)
            return (try memory.read(used + 4 + slot * 8, 4), try memory.read(used + 8 + slot * 8, 4),
                    try memory.read(used + 2, 2))
        }

        func bytes(at address: UInt64, count: Int) throws -> [UInt8] {
            try (0..<count).map { UInt8(truncatingIfNeeded: try memory.read(address + UInt64($0), 1)) }
        }

        func write(_ bytes: [UInt8], at address: UInt64) throws {
            for (index, byte) in bytes.enumerated() { try memory.write(address + UInt64(index), 1, UInt64(byte)) }
        }
    }

    static let frame: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + VirtioNet.defaultMAC + [0x08, 0x06]
        + [UInt8](repeating: 0xAB, count: 28)

    /// L'adresse se lit dans l'espace de configuration, à toute largeur, et
    /// la seule fonction annoncée est `MAC`.
    func testTheAddressAndTheFeatureAreAnnounced() {
        let nic = VirtioNet()
        XCTAssertEqual(nic.readPort(0x00, 4), 1 << 5)
        XCTAssertEqual((0..<6).map { UInt8(nic.readPort(0x14 + UInt16($0), 1)) }, VirtioNet.defaultMAC)
        XCTAssertEqual(nic.readPort(0x14, 4), 0x7369_7702)
        XCTAssertEqual(nic.readPort(0x0C, 2), UInt64(VirtioNet.queueLimit))
    }

    /// **Envoyer** : l'en-tête de dix octets retiré, la trame au câble, la
    /// requête rendue et l'interruption levée.
    func testATransmittedFrameReachesTheCableWithoutItsHeader() throws {
        let cable = Cable()
        var driver = Driver(VirtioNet(backend: cable))
        try driver.write([UInt8](repeating: 0, count: 10) + Self.frame, at: 0x40000)
        try driver.post(1, address: 0x40000, length: UInt32(10 + Self.frame.count), writable: false)
        driver.nic.writePort(0x10, 2, 1, driver.memory)

        XCTAssertEqual(cable.sent, [Self.frame])
        XCTAssertEqual(try driver.used(1, 0).index, 1)
        XCTAssertTrue(driver.nic.interrupting)
        XCTAssertEqual(driver.nic.readPort(0x13, 1), 1, "l'état d'interruption…")
        XCTAssertFalse(driver.nic.interrupting, "…s'acquitte en le lisant")
    }

    /// **Recevoir** : la trame derrière un en-tête nul, dans le tampon posé,
    /// la longueur servie, et l'interruption.
    func testAReceivedFrameLandsInThePostedBuffer() throws {
        let cable = Cable()
        var driver = Driver(VirtioNet(backend: cable))
        try driver.post(0, address: 0x50000, length: 2048, writable: true)
        cable.incoming = [Self.frame]
        driver.nic.poll(driver.memory)

        let served = try driver.used(0, 0)
        XCTAssertEqual(served.index, 1)
        XCTAssertEqual(served.length, UInt64(10 + Self.frame.count))
        XCTAssertEqual(try driver.bytes(at: 0x50000, count: 10 + Self.frame.count),
                       [UInt8](repeating: 0, count: 10) + Self.frame)
        XCTAssertTrue(driver.nic.interrupting)
    }

    /// Sans tampon, la trame attend ; le tampon posé et la file notifiée, elle
    /// arrive.
    func testAFrameWaitsForABuffer() throws {
        let cable = Cable()
        var driver = Driver(VirtioNet(backend: cable))
        cable.incoming = [Self.frame]
        driver.nic.poll(driver.memory)
        XCTAssertEqual(try driver.used(0, 0).index, 0)
        XCTAssertFalse(driver.nic.interrupting)

        try driver.post(0, address: 0x50000, length: 2048, writable: true)
        driver.nic.writePort(0x10, 2, 0, driver.memory)
        XCTAssertEqual(try driver.used(0, 0).index, 1)
        XCTAssertEqual(driver.nic.delivered, 1)
    }

    /// Un tampon trop petit ne reçoit pas une trame tronquée : elle est
    /// perdue, et le tampon rendu vide.
    func testATooSmallBufferGetsNothingRatherThanHalf() throws {
        let cable = Cable()
        var driver = Driver(VirtioNet(backend: cable))
        try driver.post(0, address: 0x50000, length: 20, writable: true)
        cable.incoming = [Self.frame]
        driver.nic.poll(driver.memory)
        XCTAssertEqual(try driver.used(0, 0).length, 0)
        XCTAssertEqual(driver.nic.dropped, 1)
        XCTAssertEqual(driver.nic.delivered, 0)
    }

    /// Sur le bus : une carte Ethernet virtio à l'emplacement cinq, à côté du
    /// pont et du disque, qui ne changent pas.
    func testTheCardAnswersOnSlotFiveAndNothingElseMoves() {
        let bus = X86PCIHost(storage: VirtioBlock(image: [UInt8](repeating: 0, count: 512)))
        bus.network = X86PCIHost(network: VirtioNet())
        func read(slot: UInt32, register: UInt32) -> UInt32 {
            bus.writeAddress(0x8000_0000 | (slot << 11) | register)
            return bus.configuration()
        }
        XCTAssertEqual(read(slot: 5, register: 0x00), 0x1000_1AF4)
        XCTAssertEqual(read(slot: 5, register: 0x08), 0x0200_0000)
        XCTAssertEqual(read(slot: 5, register: 0x2C), 0x0001_1AF4)
        XCTAssertEqual(read(slot: 5, register: 0x3C) & 0xFF, UInt32(X86PCIHost.networkInterruptLine))
        XCTAssertEqual(read(slot: 3, register: 0x00), 0x1001_1AF4)
        XCTAssertEqual(read(slot: 0, register: 0x00), 0x1237_8086)
        XCTAssertEqual(read(slot: 6, register: 0x00), 0xFFFF_FFFF)
    }

    /// **La carte se reprend**, ses files à leur place, branchée sur l'autre
    /// bout de la machine qui reprend ; un instantané sans carte n'en rend pas.
    func testTheCardSurvivesASnapshotAndAnOldOneHasNone() throws {
        let saved = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        let nic = VirtioNet(mac: [0x02, 1, 2, 3, 4, 5], backend: Cable())
        saved.attach(network: nic)
        // Un disque branché **après** la carte ne la débranche pas, et sa
        // section, lue après celle de la carte, revient elle aussi.
        saved.attach(disk: [UInt8](repeating: 0x5A, count: 4096))
        XCTAssertTrue(saved.memory.bus?.network?.nic === nic, "le disque a gardé la carte")
        for queue in 0..<2 {
            nic.writePort(0x0E, 2, UInt64(queue), saved.memory)
            nic.writePort(0x08, 4, UInt64(0x30 + queue), saved.memory)
        }
        nic.writePort(0x12, 1, 7, saved.memory)
        let data = saved.snapshot()

        let cable = Cable()
        let resumed = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        resumed.attach(network: VirtioNet(backend: cable))
        try resumed.restore(data)
        let card = try XCTUnwrap(resumed.network)
        XCTAssertEqual(card.mac, [0x02, 1, 2, 3, 4, 5])
        XCTAssertEqual(card.queues, nic.queues)
        XCTAssertEqual(card.status, 7)
        XCTAssertTrue(card.backend === cable, "le réseau est celui de la machine qui reprend")
        XCTAssertTrue(resumed.memory.bus?.network?.nic === card)
        XCTAssertEqual(resumed.disk?.image, [UInt8](repeating: 0x5A, count: 4096))
        XCTAssertEqual(resumed.snapshot(), data)

        let plain = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in }).snapshot()
        let again = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        again.attach(network: VirtioNet(backend: cable))
        try again.restore(plain)
        XCTAssertNil(again.network)
        XCTAssertNil(again.memory.bus?.network)
    }
}
