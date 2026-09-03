import XCTest
@testable import WisqCore

final class MachineStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisq-test-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testRoundTrip() throws {
        let store = MachineStore(fileURL: fileURL)
        let machine = Machine(name: "Debian", host: "10.0.0.5", proto: .vnc, guestOS: .linux)
        _ = try store.upsert(machine)

        let reloaded = try MachineStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.name, "Debian")
        XCTAssertEqual(reloaded.first?.port, 5900)
    }

    func testUpsertReplacesRatherThanAppends() throws {
        let store = MachineStore(fileURL: fileURL)
        var machine = Machine(name: "Debian", host: "10.0.0.5")
        _ = try store.upsert(machine)
        machine.name = "Debian 13"
        let result = try store.upsert(machine)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Debian 13")
    }

    func testDeleteRemovesTheMachine() throws {
        let store = MachineStore(fileURL: fileURL)
        let machine = Machine(name: "Debian", host: "10.0.0.5")
        _ = try store.upsert(machine)
        XCTAssertTrue(try store.delete(id: machine.id).isEmpty)
    }

    /// Twenty machines added at once, and all twenty survive.
    ///
    /// `upsert` used to read the list and write it back in two separate trips
    /// through its queue. Two writers then both read the same list, both write
    /// their own version, and whichever lands second erases the other's
    /// machine — nothing crashes, nothing is logged, the machine the user just
    /// added is simply not there.
    ///
    /// Twenty concurrent writers rather than two, because one interleaving out
    /// of two is a coin flip and twenty is a certainty: with the split version
    /// this loses machines on every run. It is a real store on a real
    /// temporary file, so what it exercises is the actual read-modify-write and
    /// not a model of it.
    func testMachinesAddedAtTheSameTimeDoNotEraseEachOther() {
        let store = MachineStore(fileURL: fileURL)
        let count = 20

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let machine = Machine(
                name: "machine-\(index)", host: "10.0.0.\(index)", proto: .vnc, guestOS: .linux
            )
            _ = try? store.upsert(machine)
        }

        let stored = (try? MachineStore(fileURL: fileURL).load()) ?? []
        XCTAssertEqual(
            stored.count, count,
            "\(count - stored.count) machine(s) perdue(s) : une écriture en a écrasé une autre"
        )
        XCTAssertEqual(Set(stored.map(\.name)).count, count, "des noms manquent")
    }

    /// The same for removal: deleting one machine while another is being
    /// deleted must not bring the first one back.
    func testDeletingTwoMachinesAtOnceRemovesBoth() throws {
        let store = MachineStore(fileURL: fileURL)
        let machines: [Machine] = (0..<10).map { index in
            Machine(name: "machine-\(index)", host: "10.0.0.\(index)", proto: .vnc, guestOS: .linux)
        }
        for machine in machines { _ = try store.upsert(machine) }
        let identifiers = machines.map(\.id)

        DispatchQueue.concurrentPerform(iterations: identifiers.count) { index in
            _ = try? store.delete(id: identifiers[index])
        }

        XCTAssertEqual(try MachineStore(fileURL: fileURL).load().count, 0)
    }

    /// A machine created without a port inherits its protocol's default.
    ///
    /// The numbers are repeated here rather than read from `defaultPort`,
    /// which would make the assertion tautological; `DefaultPortTests` says
    /// where each one comes from. SPICE said 5930 until a real libvirt was
    /// measured — it allocates from 5900.
    func testDefaultPortFollowsTheProtocol() {
        XCTAssertEqual(Machine(name: "a", host: "h", proto: .rdp).port, 3389)
        XCTAssertEqual(Machine(name: "a", host: "h", proto: .spice).port, 5900)
        XCTAssertEqual(Machine(name: "a", host: "h", port: 5905, proto: .vnc).port, 5905)
    }
}
