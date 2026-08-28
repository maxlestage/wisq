import Foundation
import XCTest

@testable import WisqVM

/// Every field a snapshot carries, put in and taken back out.
///
/// `Snapshot.swift` makes a flat claim: "RAM, the hart's registers and the
/// bytes queued for the UART are ours; putting them back returns the guest to
/// exactly where it was." Fifty-one things are saved — thirty-two integer
/// registers, sixteen control registers, RAM, the keystrokes not yet read and
/// the console bytes not yet flushed — and until this file, dropping most of
/// them from `restore` broke no test.
///
/// **The measurement.** Each of the fifty-one assignments in `restore` was
/// removed in turn, one at a time, and the whole suite run against it — the
/// read still happened, so the reader still balanced and the snapshot was
/// still accepted; the field simply kept whatever the machine already had.
/// **Thirty-five of the fifty-one went unnoticed** by all 1 137 tests. One of
/// the thirty-five is `x0`, which is hardwired to zero and therefore a real
/// equivalence rather than a gap. The other thirty-four were gaps, `mepc` and
/// twenty-six of the integer registers among them.
///
/// **Why the existing tests miss so much.** Two of them look like they should
/// catch everything, and each is blind in its own way:
///
///   - `SuspendedMachineTests.testARealMachineSurvivesTheFile` compares the two
///     snapshots byte for byte, which is the right assertion — but its machine
///     runs four bytes of `nop` and then traps in a loop, so most of its
///     registers and half its control registers are zero. Dropping the restore
///     of a field that is already zero changes nothing. A probe that cannot
///     distinguish proves nothing.
///   - `SnapshotAgreementTests.testEachCoreResumesFromTheOthersSnapshot`
///     restores a real booted Linux and carries it on. It cannot hold an
///     individual register at all, and not for want of a better assertion:
///     whether a register is live at the one instant the snapshot is taken is
///     an accident of where the boot had got to. Its assertions were sharpened
///     in the same change that added this file — the console it compares was
///     empty — and re-measured afterwards: all thirty-five still survive it.
///     Thirteen fields it does hold, and holds properly.
///
/// So this file does not run anything. It builds a snapshot in which **every
/// saved field holds a different non-zero value**, restores it, and writes it
/// out again. Anything the restore drops comes back as zero, and the word that
/// names it is the one that fails. The expected values are fixed in the test
/// rather than read back from a second call, so the same assertions hold the
/// writing side too: zeroing a field in `snapshot()` fails here as well —
/// checked, on `mtval` and on a register.
///
/// Each assertion was verified the only way that counts: by removing the
/// matching line and confirming this file goes red. Thirty-four of the
/// thirty-four gaps are caught; `x0` is not, and cannot be.
final class SnapshotFieldWitnessTests: XCTestCase {
    /// The forty-eight words, in the order both cores write them.
    ///
    /// `x0` is in the list and deliberately not given a value: it is hardwired
    /// to zero, so a valid snapshot always carries zero there and dropping its
    /// restore is a real equivalence rather than a gap. Naming it keeps the
    /// list a full description of the format instead of a list of the parts
    /// that happen to be testable.
    private static let words: [String] = (0..<32).map { "x\($0)" } + [
        "pc", "mstatus", "cyclel", "cycleh",
        "timerl", "timerh", "timermatchl", "timermatchh",
        "mscratch", "mtvec", "mie", "mip",
        "mepc", "mtval", "mcause", "extraflags",
    ]

    /// A value no field would hold by accident, distinct per slot.
    ///
    /// Distinctness is the point. Filling every word with the same constant
    /// would pass just as well against a `restore` that put the last word into
    /// all forty-eight, and would say nothing about which field went where —
    /// which is exactly the mistake a saved-state format makes when two
    /// adjacent slots get swapped.
    private static func value(forSlot slot: Int) -> UInt32 {
        0xC5A0_0000 | UInt32(slot)
    }

    /// Keystrokes typed and not yet read by the guest.
    private static let queuedInput = Data([0x71, 0x75, 0x65, 0x75, 0x65])
    /// Console bytes the machine has produced and not yet handed to its owner.
    private static let queuedOutput = Data([0xF0, 0x0D, 0xBA, 0xBE])

    // MARK: - Building a snapshot with nothing left at zero

    /// A real snapshot, edited so that every field carries its own marker.
    ///
    /// Built from a real one rather than assembled from scratch on purpose:
    /// the RAM section is run-length encoded, and a hand-written encoder in a
    /// test would be a second implementation of the thing under test. Editing
    /// the fixed-width words in place, and rewriting the trailing blob, leaves
    /// the RAM section exactly as the real writer produced it.
    private func snapshotWithEveryFieldDistinct() throws -> Data {
        let machine = LinuxMachine { _ in }
        // Four bytes that are not zero, so the RAM section carries a literal
        // run and a lost `ram` shows up as a difference rather than as two
        // equally empty machines.
        try machine.load(kernelImage: Data([0xEF, 0xBE, 0xAD, 0xDE]))
        machine.send(Self.queuedInput)

        var bytes = Array(machine.snapshot())
        for slot in 1..<Snapshot.coreWords {
            let value = Self.value(forSlot: slot).littleEndian
            withUnsafeBytes(of: value) { encoded in
                for (offset, byte) in encoded.enumerated() {
                    bytes[Snapshot.magic.count + slot * 4 + offset] = byte
                }
            }
        }

        // The pending-output blob is the last section, and a machine that has
        // not run has none. Replacing the empty blob at the end is the whole
        // edit: an eight-byte length followed by the bytes themselves.
        let empty = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(
            Array(bytes.suffix(8)), empty,
            "l'instantané d'une machine qui n'a pas tourné doit finir sur un blob vide"
        )
        bytes.removeLast(8)
        withUnsafeBytes(of: UInt64(Self.queuedOutput.count).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        bytes.append(contentsOf: Self.queuedOutput)
        return Data(bytes)
    }

    private func word(_ snapshot: Data, _ slot: Int) -> UInt32 {
        let at = Snapshot.magic.count + slot * 4
        return snapshot[at..<(at + 4)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    // MARK: - The witnesses

    /// The forty-eight words, one assertion each, named.
    ///
    /// A single comparison of the two blobs would catch everything this loop
    /// catches and report "1 234 567 octets diffèrent". The loop is here so the
    /// failure says `mscratch`.
    func testEveryCoreWordComesBackFromASnapshot() throws {
        let saved = try snapshotWithEveryFieldDistinct()
        let machine = LinuxMachine { _ in }
        try machine.restore(saved)
        let round = machine.snapshot()

        for slot in 1..<Snapshot.coreWords {
            XCTAssertEqual(
                word(round, slot), Self.value(forSlot: slot),
                "\(Self.words[slot]) n'est pas revenu de l'instantané"
            )
        }
        XCTAssertEqual(
            word(round, 0), 0,
            "x0 est câblé à zéro : un instantané valide n'en porte rien d'autre"
        )
    }

    /// The rest of the snapshot: RAM, and the two queues.
    ///
    /// Byte-for-byte on the whole thing, which subsumes the loop above and
    /// covers the three sections a word index cannot name.
    func testTheWholeSnapshotComesBackByteForByte() throws {
        let saved = try snapshotWithEveryFieldDistinct()
        let machine = LinuxMachine { _ in }
        try machine.restore(saved)
        XCTAssertEqual(
            machine.snapshot(), saved,
            "l'instantané réécrit après restauration doit être celui qui a été lu"
        )
    }

    /// Input typed and not yet read is machine state: dropping it loses a
    /// keystroke the user has already made.
    ///
    /// The Rust core has had this test since the format existed; the Swift one
    /// did not, and dropping `inputQueue = queued` broke nothing.
    func testQueuedKeystrokesSurviveTheRoundTrip() throws {
        let machine = LinuxMachine { _ in }
        try machine.load(kernelImage: Data([0x13, 0x00, 0x00, 0x00]))
        machine.send(Data("echo bonjour\n".utf8))
        let saved = machine.snapshot()

        let back = LinuxMachine { _ in }
        try back.restore(saved)
        XCTAssertEqual(
            back.snapshot(), saved,
            "la file d'entrée doit revenir telle quelle"
        )
    }

    /// Output produced and not yet flushed is machine state too, and it is the
    /// half nobody thinks of: the bytes are gone from the guest's UART and have
    /// not reached the terminal, so losing them loses a line the guest believes
    /// it printed.
    func testConsoleBytesNotYetFlushedSurviveTheRoundTrip() throws {
        let saved = try snapshotWithEveryFieldDistinct()
        let machine = LinuxMachine { _ in }
        try machine.restore(saved)

        let tail = machine.snapshot().suffix(Self.queuedOutput.count)
        XCTAssertEqual(
            Data(tail), Self.queuedOutput,
            "les octets en attente pour la console doivent survivre à la restauration"
        )
    }

    // MARK: - The guard the Rust side gets from its compiler

    /// A register added to the core and forgotten in the snapshot.
    ///
    /// This is the failure the format is most exposed to, because it boots: the
    /// machine comes back, runs, and is quietly not the one that was saved. The
    /// Rust core cannot make it — `snapshot.rs` asserts
    /// `size_of::<Core>() == CORE_WORDS * 4` at compile time, so adding a field
    /// stops the crate from compiling. Swift has no equivalent: `RV32Core` is a
    /// class, so its size is a pointer's, and `Snapshot.coreWords` is a
    /// constant with nothing tying it to the type.
    ///
    /// A test is the weaker instrument — it fails at run time rather than at
    /// build time — but it is the same alarm. Adding a stored property to
    /// `RV32Core` fails here with its name, and the fix is either to carry it
    /// in the snapshot or to list it below as something a guest does not own.
    func testTheCoreDeclaresNoStateTheSnapshotDoesNotCarry() {
        let bus = SilentBus()
        let ram = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 8)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: 1 << 16)
        defer { ram.deallocate() }
        let core = RV32Core(ram: ram, ramSize: 1 << 16, bus: bus)

        /// Wiring rather than guest state, and deliberately not saved: where
        /// this machine's memory happens to live, how much of it there is, and
        /// which devices it is plugged into. All three are supplied afresh by
        /// whoever restores.
        let notGuestState: Set<String> = ["ram", "ramSize", "bus"]
        /// The register file is one stored property holding thirty-two words,
        /// so it counts once here and thirty-two times in the format.
        let registerFile = "x"

        let declared = Mirror(reflecting: core).children.compactMap(\.label)
        let saved = Set(declared).subtracting(notGuestState)
        let expected = Set(Self.words.dropFirst(32)).union([registerFile])

        XCTAssertEqual(
            saved, expected,
            """
            RV32Core et l'instantané ne décrivent plus la même machine. \
            Un champ ajouté au cœur doit être porté par Snapshot, ou déclaré \
            ici comme n'appartenant pas à l'invité.
            """
        )
        XCTAssertEqual(
            Snapshot.coreWords, Self.words.count,
            "le nombre de mots sauvés et la liste nommée ici doivent rester d'accord"
        )
    }

    private final class SilentBus: RV32Bus {
        func mmioLoad(_ address: UInt32) -> UInt32 { 0 }
        func mmioStore(_ address: UInt32, _ value: UInt32) -> UInt32? { nil }
    }
}
