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

    func testDefaultPortFollowsTheProtocol() {
        XCTAssertEqual(Machine(name: "a", host: "h", proto: .rdp).port, 3389)
        XCTAssertEqual(Machine(name: "a", host: "h", proto: .spice).port, 5930)
        XCTAssertEqual(Machine(name: "a", host: "h", proto: .vnc, port: 5905).port, 5905)
    }
}
