import XCTest
@testable import WisqVM

/// La copie d'un bloc entre un périphérique et l'invité (`GuestMemory.copyIn`,
/// `copyOut`), et la carte réseau qui interroge son réseau moins souvent
/// quand le processeur travaille (`VirtioNet.busyPollInterval`).
final class GuestMemoryBlockTests: XCTestCase {
    /// Une mémoire qui ne sait que lire et écrire un octet à la fois : elle
    /// prend les copies par défaut du protocole.
    final class ByteMemory: GuestMemory {
        var bytes = [UInt8](repeating: 0, count: 64)
        func read(_ address: UInt64, _ width: Int) throws -> UInt64 {
            guard address < UInt64(bytes.count) else { throw X86Core.Fault.outsideMemory(address) }
            return UInt64(bytes[Int(address)])
        }
        func write(_ address: UInt64, _ width: Int, _ value: UInt64) throws {
            guard address < UInt64(bytes.count) else { throw X86Core.Fault.outsideMemory(address) }
            bytes[Int(address)] = UInt8(truncatingIfNeeded: value)
        }
    }

    static let pattern = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) }

    /// **En mémoire vive, d'un coup**, et la même chose qu'octet par octet.
    func testABlockInRAMIsCopiedWhole() {
        let memory = X86Memory(size: 1 << 16, base: 0)
        memory.copyIn(Self.pattern, at: 0x1000)
        XCTAssertEqual(memory.copyOut(at: 0x1000, count: Self.pattern.count), Self.pattern)
        for (index, value) in Self.pattern.enumerated() {
            XCTAssertEqual(try memory.read(0x1000 + UInt64(index), 1), UInt64(value))
        }
        XCTAssertEqual(try memory.read(0x1000 + UInt64(Self.pattern.count), 1), 0, "rien au-delà")
        XCTAssertEqual(try memory.read(0x0FFF, 1), 0, "rien avant")
        XCTAssertTrue(memory.copyOut(at: 0x1000, count: 0).isEmpty)
        XCTAssertTrue(memory.copyOut(at: 0x1000, count: -3).isEmpty)
        memory.copyIn([], at: 0x2000)
    }

    /// **Un bloc qui déborde** garde ce qui tient et perd le reste, sans
    /// erreur ; relu, le reste vaut zéro.
    func testABlockThatOverflowsKeepsWhatFits() {
        let memory = X86Memory(size: 1 << 12, base: 0)
        let start = UInt64((1 << 12) - 100)
        memory.copyIn(Self.pattern, at: start)
        let back = memory.copyOut(at: start, count: Self.pattern.count)
        XCTAssertEqual(Array(back[0..<100]), Array(Self.pattern[0..<100]))
        XCTAssertEqual(Array(back[100...]), [UInt8](repeating: 0, count: Self.pattern.count - 100))
    }

    /// Les copies par défaut, pour une mémoire qui n'en a pas de meilleures.
    func testTheDefaultCopiesGoByteByByte() {
        let memory = ByteMemory()
        memory.copyIn([1, 2, 3, 4], at: 62)
        XCTAssertEqual(Array(memory.bytes[62...]), [1, 2])
        XCTAssertEqual(memory.copyOut(at: 61, count: 4), [0, 1, 2, 0])
    }

    /// **Le réseau n'est interrogé qu'un passage sur seize** quand le
    /// processeur travaille, et à chaque passage au repos ; ce qui attend un
    /// tampon, lui, part à chaque passage.
    func testTheCardAsksTheNetworkLessOftenWhileBusy() throws {
        final class Counting: NetworkBackend {
            var asked = 0
            var incoming: [[UInt8]] = []
            func send(_ frame: [UInt8]) {}
            func receive() -> [[UInt8]] {
                asked += 1
                defer { incoming.removeAll() }
                return incoming
            }
        }
        let cable = Counting()
        var driver = VirtioNetTests.Driver(VirtioNet(backend: cable))
        for _ in 0..<(VirtioNet.busyPollInterval * 3) { driver.nic.poll(driver.memory, busy: true) }
        XCTAssertEqual(cable.asked, 3)
        for _ in 0..<5 { driver.nic.poll(driver.memory) }
        XCTAssertEqual(cable.asked, 8, "au repos, à chaque passage")

        // Une trame arrivée sans tampon attend ; le tampon posé, le passage
        // suivant la livre, même sans interroger le réseau.
        cable.incoming = [VirtioNetTests.frame]
        driver.nic.poll(driver.memory)
        XCTAssertEqual(driver.nic.delivered, 0)
        try driver.post(0, address: 0x50000, length: 2048, writable: true)
        let before = cable.asked
        driver.nic.poll(driver.memory, busy: true)
        XCTAssertEqual(cable.asked, before, "pas une question au réseau")
        XCTAssertEqual(driver.nic.delivered, 1)
        XCTAssertEqual(try driver.bytes(at: 0x5000A, count: VirtioNetTests.frame.count), VirtioNetTests.frame)
    }

    /// **Endormi, le processeur interroge le réseau à chaque passage** : une
    /// machine en `HLT` n'exécute rien, et seize passages y seraient seize
    /// battements d'attente pour un paquet déjà arrivé.
    func testAHaltedCoreAsksTheNetworkEveryPass() throws {
        final class Counting: NetworkBackend {
            var asked = 0
            func send(_ frame: [UInt8]) {}
            func receive() -> [[UInt8]] { asked += 1; return [] }
        }
        let cable = Counting()
        let machine = X86Machine(ramSize: 16 << 20, onOutput: { _ in })
        machine.attach(network: VirtioNet(backend: cable))
        machine.core.halted = true
        for _ in 0..<3 { try machine.core.serviceInterrupts() }
        XCTAssertEqual(cable.asked, 3, "endormi : à chaque passage")
        machine.core.halted = false
        for _ in 0..<3 { try machine.core.serviceInterrupts() }
        XCTAssertEqual(cable.asked, 3, "au travail : un passage sur seize")
    }
}
