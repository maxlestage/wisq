#if os(iOS)
import SwiftUI
import WisqUI
import WisqVM
import XCTest

/// The layer that used to be described as "the part CI cannot check".
///
/// It can. `LocalVMModel` is iOS-only, so it needs an iOS runtime — and CI has
/// one: this bundle runs in a booted simulator, driving a real interpreter on
/// a real thread, writing real files. Two defects lived here undetected long
/// enough to reach a pull request, both of them things a compiler cannot see:
/// "Arrêter" saved the machine it had just ended, and a machine put away when
/// the app went to the background was never picked up when it came back.
///
/// The guest is four bytes — a `nop` the machine executes forever. Nothing here
/// is about Linux; the boot is covered elsewhere. What is under test is the
/// wiring: a thread that has to be waited for, a file that has to be written
/// while iOS is taking the app away, and a machine that has to come back.
final class LocalVMModelTests: XCTestCase {
    private var folder: URL!
    private var kernel: URL!

    /// `nop`, and nothing else. `run()` never returns on its own, which is
    /// exactly the shape a real guest has: the model must stop it to save it.
    private static let nop = Data([0x13, 0x00, 0x00, 0x00])

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        kernel = folder.appendingPathComponent("Image")
        try Self.nop.write(to: kernel)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func model() -> LocalVMModel {
        LocalVMModel(storageDirectory: folder)
    }

    /// The emulator runs on its own thread and reports back through the main
    /// actor, so a test has to let the run loop turn rather than assert
    /// immediately. This waits for a condition instead of sleeping a fixed
    /// amount, so a slow simulator makes it slower rather than flaky.
    @MainActor
    private func waitUntil(
        _ description: String, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private var savedMachine: Data? {
        SuspendedMachine.load(kernel: "Image", in: folder)
    }

    /// The feature, end to end: run, leave, and find a machine on disk that a
    /// real interpreter will take back.
    ///
    /// The size of the file is deliberately not asserted. A machine running
    /// four bytes of `nop` has 64 MB of zeroed RAM, which the snapshot folds
    /// away to almost nothing — an assertion on bytes would be an assertion
    /// about the compression, not about the machine.
    @MainActor
    func testLeavingTheScreenWritesTheMachineToDisk() throws {
        let model = self.model()
        model.boot(kernelURL: kernel)
        XCTAssertTrue(model.status.isRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        model.suspend()
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.willResume)

        let saved = try XCTUnwrap(savedMachine, "aucune machine n'a été écrite")
        let restored = LinuxMachine { _ in }
        try restored.restore(saved)
        XCTAssertGreaterThan(
            restored.retiredInstructions, 0,
            "l'instantané doit venir d'une machine qui avait tourné"
        )
    }

    /// And the machine that comes back is the one that left: a restored guest
    /// has already retired the instructions the first one did, so it is ahead
    /// of anything a fresh boot could be.
    @MainActor
    func testTheMachineThatComesBackIsTheOneThatLeft() throws {
        let first = model()
        first.boot(kernelURL: kernel)
        // Let it retire a meaningful number of instructions before saving.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        first.suspend()

        let saved = try XCTUnwrap(savedMachine)
        let reference = LinuxMachine { _ in }
        try reference.restore(saved)
        XCTAssertGreaterThan(
            reference.retiredInstructions, 0,
            "l'instantané doit venir d'une machine qui avait déjà tourné"
        )

        // A second model, as if the app had been killed and relaunched.
        let second = model()
        second.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        second.suspend()
        let again = try XCTUnwrap(savedMachine)
        let resumed = LinuxMachine { _ in }
        try resumed.restore(again)
        XCTAssertGreaterThan(
            resumed.retiredInstructions, reference.retiredInstructions,
            "la reprise doit continuer la machine, pas la redémarrer"
        )
    }

    /// "Arrêter" closes the console, so the stop and the departure arrive one
    /// after the other. Before the lifecycle, the departure wrote a snapshot of
    /// the machine the stop had just ended — and the machine the user stopped
    /// was waiting for them at the next launch.
    @MainActor
    func testStoppingThenLeavingLeavesNothingBehind() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.suspend()
        XCTAssertNotNil(savedMachine, "préalable : il y a bien quelque chose à effacer")

        model.boot(kernelURL: kernel)
        model.stop()
        model.suspend()   // exactly what dismissing the screen does next
        XCTAssertNil(savedMachine, "un arrêt ne doit rien laisser derrière lui")
        XCTAssertFalse(model.willResume)
    }

    /// iOS backgrounds the app and later gives it back without the screen ever
    /// disappearing. A machine put away on the way out has to be picked up on
    /// the way in; otherwise the user returns to a dead terminal.
    @MainActor
    func testBackgroundingAndReturningResumesTheMachine() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        model.scenePhaseChanged(to: .background, kernelURL: kernel)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNotNil(savedMachine)

        model.scenePhaseChanged(to: .active, kernelURL: kernel)
        XCTAssertEqual(model.status, .running, "revenir doit reprendre la machine")
    }

    /// Coming back through `.inactive` — the phase iOS passes through for the
    /// app switcher and for a notification banner — must not touch anything.
    @MainActor
    func testAMomentaryInterruptionDoesNotTouchTheMachine() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        model.scenePhaseChanged(to: .inactive, kernelURL: kernel)
        XCTAssertEqual(model.status, .running, "une interruption passagère n'arrête rien")
        XCTAssertNil(savedMachine, "et n'écrit rien")
    }

    /// Returning to the foreground with a machine already running must not boot
    /// a second one over it.
    @MainActor
    func testReturningToARunningMachineChangesNothing() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.scenePhaseChanged(to: .active, kernelURL: kernel)
        XCTAssertEqual(model.status, .running)
        XCTAssertNil(savedMachine, "rien n'a été suspendu, donc rien n'est écrit")
    }

    /// "Arrêter" has to actually conclude: the button asks the interpreter to
    /// stop, and the model must let the machine go when the thread comes back.
    /// A first version swallowed that exit as already-reported and stayed in
    /// `running` forever, holding a machine it would never release.
    @MainActor
    func testStoppingIsConcludedAndForgotten() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        model.suspend()
        XCTAssertNotNil(savedMachine)

        model.boot(kernelURL: kernel)
        model.stop()
        waitUntil("la fin de la machine doit être rapportée") {
            if case .finished = model.status { return true }
            return false
        }
        XCTAssertNil(savedMachine)
    }

    /// A kernel that cannot be read is reported rather than swallowed, and
    /// leaves no half-saved machine behind.
    @MainActor
    func testAKernelThatCannotBeReadIsReported() {
        let model = self.model()
        model.boot(kernelURL: folder.appendingPathComponent("absent"))
        waitUntil("un noyau illisible doit être signalé") {
            if case .finished(let message) = model.status {
                return message.contains("Démarrage impossible")
            }
            return false
        }
        XCTAssertNil(savedMachine)
    }

    /// Suspending with nothing running is what `onDisappear` does after the
    /// machine has already ended. It must be harmless.
    @MainActor
    func testSuspendingWithNothingRunningIsHarmless() {
        let model = self.model()
        model.suspend()
        XCTAssertNil(savedMachine)
        XCTAssertEqual(model.status, .idle)

        model.scenePhaseChanged(to: .background, kernelURL: kernel)
        model.scenePhaseChanged(to: .active, kernelURL: kernel)
        XCTAssertNil(savedMachine)
        XCTAssertEqual(model.status, .idle)
    }

    /// Console text survives a suspension: it is the same session, and clearing
    /// the grid would make a resumption look like the reboot this whole feature
    /// exists to avoid.
    @MainActor
    func testTheConsoleSurvivesASuspension() {
        let model = self.model()
        model.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let before = model.consoleText

        model.scenePhaseChanged(to: .background, kernelURL: kernel)
        model.scenePhaseChanged(to: .active, kernelURL: kernel)
        XCTAssertEqual(model.consoleText, before, "la console ne doit pas être vidée")
    }

    /// Two kernels, two saved machines: opening one must never resume the
    /// other's session.
    @MainActor
    func testEachKernelKeepsItsOwnMachine() throws {
        let other = folder.appendingPathComponent("autre-noyau")
        try Self.nop.write(to: other)

        let first = model()
        first.boot(kernelURL: kernel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        first.suspend()

        let second = model()
        second.boot(kernelURL: other)
        XCTAssertNotNil(savedMachine, "la machine du premier noyau est intacte")
        second.suspend()

        XCTAssertNotNil(SuspendedMachine.load(kernel: "Image", in: folder))
        XCTAssertNotNil(SuspendedMachine.load(kernel: "autre-noyau", in: folder))
        XCTAssertNotEqual(
            SuspendedMachine.load(kernel: "Image", in: folder),
            SuspendedMachine.load(kernel: "autre-noyau", in: folder)
        )
    }
}
#endif
