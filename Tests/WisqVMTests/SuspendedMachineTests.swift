import XCTest
@testable import WisqVM

/// The file a suspended machine waits in, and the states a user can actually
/// put it in: nothing saved yet, saved and coming back, saved twice, and a file
/// that is not a machine at all.
final class SuspendedMachineTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-suspended-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFirstLaunchHasNothingSaved() {
        XCTAssertNil(SuspendedMachine.load(in: folder))
        XCTAssertFalse(SuspendedMachine.exists(in: folder))
    }

    /// The first save is the one with no file to replace, which is exactly the
    /// case an implementation built around "replace the existing file" gets
    /// wrong — and did here, before this test.
    func testTheFirstSaveWorksWithNothingToReplace() throws {
        let snapshot = Data((0..<10_000).map { UInt8($0 % 251) })
        try SuspendedMachine.save(snapshot, in: folder)
        XCTAssertTrue(SuspendedMachine.exists(in: folder))
        XCTAssertEqual(SuspendedMachine.load(in: folder), snapshot)
    }

    func testSavingAgainReplacesTheOldMachine() throws {
        try SuspendedMachine.save(Data(repeating: 1, count: 500), in: folder)
        try SuspendedMachine.save(Data(repeating: 2, count: 300), in: folder)
        XCTAssertEqual(SuspendedMachine.load(in: folder), Data(repeating: 2, count: 300))
    }

    func testClearingLeavesNothingBehind() throws {
        try SuspendedMachine.save(Data(repeating: 7, count: 100), in: folder)
        SuspendedMachine.clear(in: folder)
        XCTAssertNil(SuspendedMachine.load(in: folder))
        XCTAssertFalse(SuspendedMachine.exists(in: folder))
    }

    /// A file that is not a snapshot must not become a machine. The store hands
    /// bytes over without judging them; refusing them is the machine's job, and
    /// this is the seam where that has to hold.
    func testAFileThatIsNotAMachineIsRefusedRatherThanLoaded() throws {
        try SuspendedMachine.save(Data("pas un instantané".utf8), in: folder)
        let saved = try XCTUnwrap(SuspendedMachine.load(in: folder))

        let machine = LinuxMachine { _ in }
        XCTAssertThrowsError(try machine.restore(saved)) { error in
            XCTAssertEqual(error as? Snapshot.Failure, .notASnapshot)
        }
    }

    /// The whole round trip: a machine that has run, through the file, into a
    /// second machine that agrees with the first about everything.
    func testARealMachineSurvivesTheFile() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        machine.run(instructionBudget: 5_000)
        let retired = machine.retiredInstructions

        try SuspendedMachine.save(machine.snapshot(), in: folder)
        let saved = try XCTUnwrap(SuspendedMachine.load(in: folder))

        let restored = LinuxMachine { _ in }
        try restored.restore(saved)
        XCTAssertEqual(restored.retiredInstructions, retired)
        XCTAssertEqual(restored.snapshot(), machine.snapshot())
    }
}
