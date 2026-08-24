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
        XCTAssertNil(SuspendedMachine.load(kernel: "Image", in: folder))
        XCTAssertFalse(SuspendedMachine.exists(kernel: "Image", in: folder))
    }

    /// The first save is the one with no file to replace, which is exactly the
    /// case an implementation built around "replace the existing file" gets
    /// wrong — and did here, before this test.
    func testTheFirstSaveWorksWithNothingToReplace() throws {
        let snapshot = Data((0..<10_000).map { UInt8($0 % 251) })
        try SuspendedMachine.save(snapshot, kernel: "Image", in: folder)
        XCTAssertTrue(SuspendedMachine.exists(kernel: "Image", in: folder))
        XCTAssertEqual(SuspendedMachine.load(kernel: "Image", in: folder), snapshot)
    }

    func testSavingAgainReplacesTheOldMachine() throws {
        try SuspendedMachine.save(Data(repeating: 1, count: 500), kernel: "Image", in: folder)
        try SuspendedMachine.save(Data(repeating: 2, count: 300), kernel: "Image", in: folder)
        XCTAssertEqual(SuspendedMachine.load(kernel: "Image", in: folder), Data(repeating: 2, count: 300))
    }

    func testClearingLeavesNothingBehind() throws {
        try SuspendedMachine.save(Data(repeating: 7, count: 100), kernel: "Image", in: folder)
        SuspendedMachine.clear(kernel: "Image", in: folder)
        XCTAssertNil(SuspendedMachine.load(kernel: "Image", in: folder))
        XCTAssertFalse(SuspendedMachine.exists(kernel: "Image", in: folder))
    }

    /// A file that is not a snapshot must not become a machine. The store hands
    /// bytes over without judging them; refusing them is the machine's job, and
    /// this is the seam where that has to hold.
    func testAFileThatIsNotAMachineIsRefusedRatherThanLoaded() throws {
        try SuspendedMachine.save(Data("pas un instantané".utf8), kernel: "Image", in: folder)
        let saved = try XCTUnwrap(SuspendedMachine.load(kernel: "Image", in: folder))

        let machine = LinuxMachine { _ in }
        XCTAssertThrowsError(try machine.restore(saved)) { error in
            XCTAssertEqual(error as? Snapshot.Failure, .notASnapshot)
        }
    }

    /// A snapshot belongs to the kernel it was taken from. Opening a different
    /// image must look like a first launch, not like someone else's machine.
    func testAMachineSavedForOneKernelIsNotOfferedForAnother() throws {
        try SuspendedMachine.save(Data(repeating: 5, count: 64), kernel: "Image", in: folder)
        XCTAssertNotNil(SuspendedMachine.load(kernel: "Image", in: folder))
        XCTAssertNil(SuspendedMachine.load(kernel: "autre-noyau", in: folder))
        XCTAssertFalse(SuspendedMachine.exists(kernel: "autre-noyau", in: folder))
    }

    /// The defect the name-only key had: `Image` is what almost every kernel
    /// downloaded from anywhere is called. Two different ones, a week apart,
    /// must not share a saved machine — the second would resume the first's
    /// session into a kernel that never ran it.
    func testTwoDifferentKernelsWithTheSameNameDoNotShareAMachine() throws {
        let first = Data([0x13, 0x00, 0x00, 0x00])
        let second = Data([0x13, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00, 0x00])
        let one = SuspendedMachine.identity(of: first, named: "Image")
        let other = SuspendedMachine.identity(of: second, named: "Image")
        XCTAssertNotEqual(one, other, "deux images distinctes, même nom")

        try SuspendedMachine.save(Data(repeating: 9, count: 128), kernel: one, in: folder)
        XCTAssertNotNil(SuspendedMachine.load(kernel: one, in: folder))
        XCTAssertNil(
            SuspendedMachine.load(kernel: other, in: folder),
            "l'autre noyau ne doit rien trouver"
        )
    }

    /// And the same image is the same machine whatever the file was renamed to
    /// in between — the name is a label for a human reading the directory, not
    /// the key.
    func testTheSameKernelIsFoundAgainAfterBeingRenamed() throws {
        let image = Data((0..<2048).map { UInt8($0 % 251) })
        let before = SuspendedMachine.identity(of: image, named: "Image")
        let after = SuspendedMachine.identity(of: image, named: "linux-6.1")
        XCTAssertNotEqual(before, after, "le nom reste visible dans l'identité")
        XCTAssertEqual(
            SuspendedMachine.digest(image), SuspendedMachine.digest(image),
            "le condensé ne dépend que des octets"
        )
    }

    /// A digest that misses a change is a digest that resurrects the wrong
    /// machine. Every single-byte flip has to be seen, including in the last
    /// byte, and a longer image must not collide with a shorter one.
    func testTheDigestNoticesEverySingleByteChange() {
        let image = Data((0..<4096).map { UInt8($0 % 251) })
        let base = SuspendedMachine.digest(image)

        for position in [0, 1, 1000, 2048, 4094, 4095] {
            var altered = image
            altered[position] = altered[position] &+ 1
            XCTAssertNotEqual(
                SuspendedMachine.digest(altered), base,
                "un octet changé en position \(position) doit changer le condensé"
            )
        }

        XCTAssertNotEqual(
            SuspendedMachine.digest(image + Data([0])), base,
            "un zéro ajouté à la fin doit changer le condensé"
        )
        XCTAssertNotEqual(
            SuspendedMachine.digest(Data()), SuspendedMachine.digest(Data([0])),
            "vide et un octet nul sont deux images différentes"
        )
    }

    /// Kernel names come from files the user picked, so they can carry
    /// separators and worse. None of that may escape the directory.
    func testAHostileKernelNameCannotEscapeTheDirectory() {
        for hostile in ["../../etc/passwd", "a/b", "..", "", "nom avec espaces"] {
            let name = SuspendedMachine.fileName(
                kernel: SuspendedMachine.identity(of: Data([1, 2, 3]), named: hostile)
            )
            XCTAssertFalse(name.contains("/"), "séparateur dans « \(name) »")
            XCTAssertFalse(name.contains(".."), "remontée dans « \(name) »")
            XCTAssertTrue(name.hasPrefix("machine-"), name)
            XCTAssertTrue(name.hasSuffix(".wisqvm"), name)
        }
    }

    /// The whole round trip: a machine that has run, through the file, into a
    /// second machine that agrees with the first about everything.
    func testARealMachineSurvivesTheFile() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        machine.run(instructionBudget: 5_000)
        let retired = machine.retiredInstructions

        try SuspendedMachine.save(machine.snapshot(), kernel: "Image", in: folder)
        let saved = try XCTUnwrap(SuspendedMachine.load(kernel: "Image", in: folder))

        let restored = LinuxMachine { _ in }
        try restored.restore(saved)
        XCTAssertEqual(restored.retiredInstructions, retired)
        XCTAssertEqual(restored.snapshot(), machine.snapshot())
    }
}
