import Foundation
import XCTest

@testable import WisqVM

/// **La première reprise d'un bureau prêt** : ce qu'elle tape, ce qu'elle ne
/// rattrape pas, et la marque qui la fait arriver une fois et une seule. Voir
/// `FirstResume`.
final class FirstResumeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-premiere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Une machine qui retient ce qu'on lui tape et le temps qu'on lui fait
    /// rattraper, et rien d'autre.
    private final class RecordingMachine: GuestMachine, @unchecked Sendable {
        private(set) var typed = Data()
        private(set) var elapsed: [TimeInterval] = []
        var ramSizeBytes: Int { 0 }
        var retiredInstructions: UInt64 { 0 }
        var diskBytesWritten: Int { 0 }
        var diskActivity: (served: UInt64, refused: UInt64)? { nil }
        func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws {}
        func attachDisk(_ image: Data) throws {}
        func attachDisk(fileAt base: URL, writes: URL) throws {}
        func flushDisk() {}
        func runGuest(instructionBudget: UInt64) -> GuestOutcome { .stopped }
        func stop() {}
        func send(_ data: Data) { typed += data }
        func snapshot() -> Data { Data() }
        func restore(_ data: Data) throws {}
        func elapse(seconds: TimeInterval) { elapsed.append(seconds) }
    }

    /// Le 14 novembre 2026 à minuit, en UTC : l'heure figée de la fabrique.
    private let madeAt = Date(timeIntervalSince1970: 1_794_614_400)
    private let entropy = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 9 &+ 1) }

    // MARK: - Ce qu'on tape

    /// **L'heure lue par l'invité à son horloge CMOS, puis l'aléa** : la
    /// ligne exacte, pour qu'un changement se voie. Pas un nombre tapé par
    /// l'hôte, qui serait en retard du temps que met l'invité à l'exécuter.
    func testTheLineSetsTheClockFromTheGuestsRTCAndMixesTheEntropy() {
        let hex = entropy.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(FirstResume.commands(entropy: entropy),
                       "date -s @$(cat /sys/class/rtc/rtc0/since_epoch) >/dev/null; echo \(hex) > /dev/urandom\n")
        // L'horloge est celle que le guetteur des clés surveille déjà : la
        // fabrique refuse de sauver un bureau où elle manque.
        XCTAssertEqual(FirstResume.rtcSeconds, ReadyDesktopBuild.rtcSeconds)
        XCTAssertTrue(ReadyDesktopBuild.prepare.contains("test -r \(FirstResume.rtcSeconds)"))
    }

    /// L'aléa du téléphone : trente-deux octets, et pas deux fois les mêmes.
    func testTheHostEntropyIsThirtyTwoFreshBytes() {
        let first = FirstResume.hostEntropy(), second = FirstResume.hostEntropy()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second.count, 32)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - La reprise

    /// **Une première reprise ne rattrape rien et tape la ligne** : rattraper
    /// le temps depuis l'import laissait l'invité au jour de la fabrique.
    func testAFirstResumeTypesTheLineAndCatchesNothingUp() {
        let machine = RecordingMachine()
        let now = madeAt.addingTimeInterval(30 * 86_400)
        let typed = FirstResume.resumed(machine, first: FirstResume(madeAt: madeAt),
                                        savedAt: now.addingTimeInterval(-600), now: now) { self.entropy }
        XCTAssertEqual(typed, FirstResume.commands(entropy: entropy))
        XCTAssertEqual(String(decoding: machine.typed, as: UTF8.self), FirstResume.commands(entropy: entropy))
        XCTAssertEqual(machine.elapsed, [], "une première reprise ne rattrape pas")
    }

    /// Une reprise ordinaire rattrape le temps passé depuis la sauvegarde,
    /// et ne tape rien ; sans heure de sauvegarde, elle ne rattrape rien.
    func testAnOrdinaryResumeCatchesUpAndTypesNothing() {
        let machine = RecordingMachine()
        let now = madeAt.addingTimeInterval(3600)
        XCTAssertNil(FirstResume.resumed(machine, first: nil, savedAt: madeAt, now: now) { self.entropy })
        XCTAssertEqual(machine.elapsed, [3600])
        XCTAssertTrue(machine.typed.isEmpty)
        FirstResume.resumed(machine, first: nil, savedAt: nil, now: now) { self.entropy }
        XCTAssertEqual(machine.elapsed, [3600], "sans heure, rien d'inventé")
    }

    /// **La ligne voyage avec la machine** : sauvée avant que l'invité l'ait
    /// lue, elle est dans l'instantané (les octets tapés en attente), et la
    /// reprise suivante l'exécute. C'est ce qui permet de retirer la marque
    /// dès la première sauvegarde.
    func testTheTypedLineIsInTheNextSnapshot() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        let line = try XCTUnwrap(FirstResume.resumed(machine, first: FirstResume(madeAt: madeAt),
                                                     savedAt: nil) { self.entropy })
        let resumed = X86Machine(ramSize: X86Machine.minimumRAMSize, onOutput: { _ in })
        try resumed.restore(machine.snapshot())
        XCTAssertEqual(resumed.core.serialInput, Array(line.utf8))
    }

    /// La phrase de la console dit le jour de la fabrication, et ce qui se
    /// passe ; sans date, elle s'en passe.
    func testTheNoteSaysTheDayAndWhatHappens() {
        XCTAssertEqual(FirstResume(madeAt: madeAt).note,
                       "Bureau prêt du 14 novembre 2026, repris pour la première fois : l'heure du téléphone "
                       + "et un aléa neuf lui sont donnés par la ligne qui suit.")
        XCTAssertTrue(FirstResume(madeAt: nil).note.hasPrefix("Bureau prêt, repris pour la première fois"))
    }

    // MARK: - Une fois et une seule

    /// **La marque tient jusqu'à la première écriture de la session**, et
    /// pas plus : la session réécrite n'est plus celle qui a été téléchargée.
    func testTheMarkerHoldsUntilTheSessionIsWrittenAgain() throws {
        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: "bureau-ab12", in: folder)
        XCTAssertNil(FirstResume.pending(kernel: "bureau-ab12", in: folder), "pas de marque, pas de première reprise")
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: "bureau-ab12", in: folder)
        XCTAssertEqual(FirstResume.pending(kernel: "bureau-ab12", in: folder), FirstResume(madeAt: madeAt))
        // Rouverte sans avoir été sauvée (l'application tuée) : encore une
        // première reprise.
        XCTAssertEqual(FirstResume.pending(kernel: "bureau-ab12", in: folder), FirstResume(madeAt: madeAt))
        try SuspendedMachine.save(Data(repeating: 2, count: 100), kernel: "bureau-ab12", in: folder)
        XCTAssertNil(FirstResume.pending(kernel: "bureau-ab12", in: folder), "la sauvegarde n'a pas retiré la marque")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("machine-bureau-ab12.wisqvm.premiere").path))
    }

    /// Une écriture qui échoue laisse le fichier téléchargé, et sa marque.
    func testAFailedWriteKeepsTheMarker() throws {
        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: "bureau-ab12", in: folder)
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: "bureau-ab12", in: folder)
        let missing = folder.appendingPathComponent("absent", isDirectory: true)
        XCTAssertThrowsError(try SuspendedMachine.savePacked(Data([1]), kernel: "bureau-ab12", in: missing))
        XCTAssertEqual(FirstResume.pending(kernel: "bureau-ab12", in: folder), FirstResume(madeAt: madeAt))
    }

    /// Une marque sans session n'est pas une première reprise ; une marque
    /// illisible en est une, sans date.
    func testAMarkerWithoutASessionIsNothingAndAnUnreadableOneStillCounts() throws {
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: "bureau-ab12", in: folder)
        XCTAssertNil(FirstResume.pending(kernel: "bureau-ab12", in: folder))
        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: "bureau-ab12", in: folder)
        try Data("pas du JSON".utf8).write(to: folder.appendingPathComponent("machine-bureau-ab12.wisqvm.premiere"))
        XCTAssertEqual(FirstResume.pending(kernel: "bureau-ab12", in: folder), FirstResume(madeAt: nil))
    }

    /// **Oublier la session oublie la marque** — « Arrêter », comme l'oubli de
    /// toutes les sessions d'une machine —, et la marque n'est jamais prise
    /// pour une session.
    func testTheMarkerGoesWithTheSessionAndIsNeverASession() throws {
        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: "bureau-ab12", in: folder)
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: "bureau-ab12", in: folder)
        XCTAssertEqual(SuspendedMachine.savedMachineFiles(named: "bureau", in: folder), ["machine-bureau-ab12.wisqvm"])
        XCTAssertEqual(SuspendedMachine.allSavedMachineFiles(in: folder), ["machine-bureau-ab12.wisqvm"])
        SuspendedMachine.clear(kernel: "bureau-ab12", in: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "clear")

        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: "bureau-ab12", in: folder)
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: "bureau-ab12", in: folder)
        XCTAssertEqual(SuspendedMachine.clearAll(named: "bureau", in: folder), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "clearAll")
    }

    /// **La copie d'un bureau jamais repris l'attend aussi** : sa session est
    /// la session téléchargée.
    func testADuplicateOfAnUnresumedDesktopWaitsForItsFirstResumeToo() throws {
        let source = try InstalledMachines.install(image: "void.iso", name: "Void Xfce (prêt)", in: folder,
                                                   id: "aaaaaaaaaaaa")
        let identity = SuspendedMachine.identity(digest: "d63775f2e341116a", named: source.key)
        try SuspendedMachine.save(Data(repeating: 1, count: 100), kernel: identity, in: folder)
        try FirstResume.arm(FirstResume(madeAt: madeAt), kernel: identity, in: folder)
        let copy = try InstalledMachines.duplicate(id: source.id, in: folder, newID: "bbbbbbbbbbbb")
        let copied = SuspendedMachine.identity(digest: "d63775f2e341116a", named: copy.key)
        XCTAssertEqual(FirstResume.pending(kernel: copied, in: folder), FirstResume(madeAt: madeAt))
        // La source reprise et sauvée ne retire pas la marque de la copie.
        try SuspendedMachine.save(Data(repeating: 2, count: 100), kernel: identity, in: folder)
        XCTAssertNil(FirstResume.pending(kernel: identity, in: folder))
        XCTAssertEqual(FirstResume.pending(kernel: copied, in: folder), FirstResume(madeAt: madeAt))
    }

    /// L'identité d'une empreinte déjà connue est celle qu'on calcule du
    /// noyau : c'est par elle que l'installation pose la marque.
    func testTheIdentityOfADigestIsTheIdentityOfTheKernel() {
        let kernel = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 29) })
        XCTAssertEqual(
            SuspendedMachine.identity(digest: ReadyDesktopBuild.kernelDigest(kernel), named: "installee-0123"),
            SuspendedMachine.identity(of: kernel, named: "installee-0123"))
    }
}
