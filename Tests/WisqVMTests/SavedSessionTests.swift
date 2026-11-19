import Foundation
import XCTest
@testable import WisqVM

/// **« Pas de session » n'est pas « session illisible »** : la seconde est
/// gardée et dite, jamais remplacée par un démarrage à froid muet. Voir
/// `SavedSession` et `PendingSession`.
final class SavedSessionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var sessionFile: URL {
        folder.appendingPathComponent(SuspendedMachine.fileName(kernel: "noyau-1"))
    }

    private static func pcSnapshot() throws -> Data {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try machine.memory.load(Array("la session".utf8), at: 0x10_0000)
        return machine.snapshot()
    }

    /// Le niveau d'un instantané, remplacé par `level`.
    private static func withLevel(_ level: UInt64, _ snapshot: Data) throws -> Data {
        var bytes = [UInt8](snapshot)
        let needle = withUnsafeBytes(of: Snapshot.levelSection.littleEndian, Array.init)
        let at = try XCTUnwrap((0...(bytes.count - 8)).first { Array(bytes[$0..<($0 + 8)]) == needle })
        bytes.replaceSubrange((at + 8)..<(at + 16), with: withUnsafeBytes(of: level.littleEndian, Array.init))
        return Data(bytes)
    }

    func testNoFileIsNoSession() {
        guard case .none = SavedSession.find(kernel: "noyau-1", in: folder, core: .x86_64) else {
            return XCTFail("aucun fichier : pas de session")
        }
    }

    /// Une session écrite comme l'application l'écrit — compressée — revient
    /// telle quelle.
    func testASavedSessionIsReadable() throws {
        let snapshot = try Self.pcSnapshot()
        try SuspendedMachine.save(snapshot, kernel: "noyau-1", in: folder)
        let found = SavedSession.find(kernel: "noyau-1", in: folder, core: .x86_64)
        XCTAssertEqual(found.snapshot, snapshot)
    }

    /// Et un fichier d'avant la compression, l'instantané tel quel, aussi.
    func testAFileFromBeforeCompressionIsReadable() throws {
        let snapshot = try Self.pcSnapshot()
        try snapshot.write(to: sessionFile)
        XCTAssertEqual(SavedSession.find(kernel: "noyau-1", in: folder, core: .x86_64).snapshot, snapshot)
    }

    /// **Un fichier abîmé est illisible, et il est gardé.** Trois sortes :
    /// une compression tronquée, des octets qui ne sont pas un instantané, un
    /// instantané coupé avant la fin de sa mémoire.
    func testADamagedFileIsUnreadableAndKept() throws {
        let snapshot = try Self.pcSnapshot()
        let packed = SnapshotFile.pack(snapshot)
        // Coupé au milieu des octets que la mémoire porte.
        let carried = try XCTUnwrap(snapshot.range(of: Data("la session".utf8)))
        let truncated = snapshot.prefix(upTo: carried.lowerBound + 4)
        for (name, bytes) in [("compression tronquée", packed.prefix(packed.count / 2)),
                              ("pas un instantané", Data("bonjour".utf8)),
                              ("instantané tronqué", Data(truncated))] {
            try Data(bytes).write(to: sessionFile)
            let found = SavedSession.find(kernel: "noyau-1", in: folder, core: .x86_64)
            guard case .unreadable(.damaged) = found else {
                XCTFail("\(name) : attendu illisible, obtenu \(found)")
                continue
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path), "\(name) : gardé")
        }
    }

    /// **Pris par une machine plus récente** : illisible ici, nommé comme tel,
    /// gardé pour la version qui saura le reprendre.
    func testASessionFromANewerMachineIsUnreadableByName() throws {
        let newer = X86Machine.snapshotLevel + 3
        try SuspendedMachine.save(try Self.withLevel(newer, try Self.pcSnapshot()), kernel: "noyau-1", in: folder)
        let found = SavedSession.find(kernel: "noyau-1", in: folder, core: .x86_64)
        guard case .unreadable(.newerMachine(let saved, let supported)) = found else {
            return XCTFail("attendu une machine plus récente, obtenu \(found)")
        }
        XCTAssertEqual(saved, newer)
        XCTAssertEqual(supported, X86Machine.snapshotLevel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    /// La machine RISC-V se juge par son propre cœur.
    func testARISCVSessionIsJudgedByItsCore() throws {
        let machine = LinuxMachine(ramSize: 1 << 20, onOutput: { _ in })
        let snapshot = machine.snapshot()
        XCTAssertEqual(SavedSession.judge(snapshot, core: .riscv32).snapshot, snapshot)
        guard case .unreadable(.damaged) = SavedSession.judge(Data("non".utf8), core: .riscv32) else {
            return XCTFail("des octets quelconques ne sont pas une session")
        }
    }

    /// **Une session que `judge` lit et que la machine refuse** : privée de
    /// son dernier octet, une session RISC-V garde son en-tête (le jugement
    /// la dit lisible, et l'application lance le fil d'émulation), mais sa
    /// dernière section s'arrête court, et la reprise lève « abîmée ». C'est le chemin du
    /// refus `.session` sur le fil, que `LocalVMModelTests` fait de bout en
    /// bout avec cette même coupure ; ce test-ci, qui tourne sous Linux, dit
    /// que la coupure mène bien là.
    func testARISCVSessionCutShortIsJudgedReadableButRefusedOnResume() throws {
        let saved = LinuxMachine(ramSize: 1 << 20, onOutput: { _ in }).snapshot()
        let cut = saved.dropLast(1)
        XCTAssertEqual(SavedSession.judge(cut, core: .riscv32).snapshot, cut, "le jugement ne lit que l'en-tête")
        let pending = PendingSession(cut)
        XCTAssertThrowsError(try pending.resume(into: LinuxMachine(ramSize: 1 << 20, onOutput: { _ in }))) { error in
            XCTAssertEqual(error as? SavedSession.Unreadable, .damaged)
        }
        XCTAssertTrue(pending.awaited)
    }

    /// La phrase dit les trois choses : gardée, pourquoi, et le geste qui
    /// repart de zéro.
    func testTheExplanationSaysKeptWhyAndWhatToDo() {
        let damaged = SavedSession.explanation(.damaged, name: "void.iso")
        let newer = SavedSession.explanation(.newerMachine(saved: 4, supported: 1), name: "void.iso")
        for text in [damaged, newer] {
            XCTAssertTrue(text.contains("void.iso"), text)
            XCTAssertTrue(text.contains("gardée"), text)
            XCTAssertTrue(text.contains("« Oublier »"), text)
        }
        XCTAssertTrue(damaged.contains("abîmé"), damaged)
        XCTAssertTrue(newer.contains("mettez wisq à jour"), newer)
        XCTAssertTrue(newer.contains("niveau 4") && newer.contains("niveau 1"), newer)
    }

    /// Une reprise refusée par la machine elle-même — une section abîmée que
    /// `judge` n'a pas lue — devient « illisible » ; une machine plus récente
    /// le reste avec ses deux niveaux.
    func testARefusedRestoreBecomesUnreadable() {
        XCTAssertEqual(SavedSession.unreadable(after: Snapshot.Failure.corrupt), .damaged)
        XCTAssertEqual(SavedSession.unreadable(after: Snapshot.Failure.newerMachine(saved: 5, supported: 1)),
                       .newerMachine(saved: 5, supported: 1))
        XCTAssertEqual(SavedSession.unreadable(after: CocoaError(.fileReadCorruptFile)), .damaged)
    }

    // MARK: - La session en attente

    /// Reprise : la machine revient, la boîte est vide, et un second appel
    /// dit « rien à reprendre » — c'est alors un démarrage à froid.
    func testAPendingSessionResumesOnceAndLetsGo() throws {
        let pending = PendingSession(try Self.pcSnapshot())
        XCTAssertFalse(pending.isEmpty)
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertTrue(try pending.resume(into: machine))
        XCTAssertEqual(machine.memory.bytes[0x10_0000], UInt8(ascii: "l"))
        XCTAssertTrue(pending.isEmpty, "les octets sont relâchés")
        XCTAssertFalse(try pending.resume(into: machine), "plus rien : démarrage à froid")
    }

    /// **La boîte sait qu'une session attendait, même vidée.** L'échec du
    /// démarrage sur le fil le lit pour promettre la session gardée : une
    /// reprise réussie ou refusée vide la boîte, et la promesse ne doit pas
    /// tomber avec elle.
    func testABoxRemembersThatASessionWasAwaited() throws {
        XCTAssertFalse(PendingSession(nil).awaited, "aucune session : rien à promettre")
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })

        let resumed = PendingSession(try Self.pcSnapshot())
        XCTAssertTrue(resumed.awaited)
        XCTAssertTrue(try resumed.resume(into: machine))
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertTrue(resumed.awaited, "vidée par la reprise, elle sait encore qu'une session attendait")

        let refused = PendingSession(try X86RestoreAllOrNothingTests.damagedSnapshot())
        XCTAssertThrowsError(try refused.resume(into: machine))
        XCTAssertTrue(refused.isEmpty)
        XCTAssertTrue(refused.awaited, "vidée par un refus aussi")
    }

    func testNoSessionMeansAColdBoot() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertFalse(try PendingSession(nil).resume(into: machine))
    }

    /// **Une reprise refusée ne démarre rien** : elle lève « illisible »,
    /// relâche les octets, et la machine reste vierge.
    func testARefusedResumeSaysUnreadable() throws {
        let damaged = try X86RestoreAllOrNothingTests.damagedSnapshot()
        let pending = PendingSession(damaged)
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        XCTAssertThrowsError(try pending.resume(into: machine)) { error in
            XCTAssertEqual(error as? SavedSession.Unreadable, .damaged)
        }
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(machine.memory.bytes[0x10_0000], 0)

        let newer = PendingSession(try Self.withLevel(X86Machine.snapshotLevel + 1, try Self.pcSnapshot()))
        XCTAssertThrowsError(try newer.resume(into: machine)) { error in
            XCTAssertEqual(error as? SavedSession.Unreadable,
                           .newerMachine(saved: X86Machine.snapshotLevel + 1, supported: X86Machine.snapshotLevel))
        }
    }
}
