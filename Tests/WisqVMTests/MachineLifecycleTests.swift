import XCTest
@testable import WisqVM

/// The sequences a user actually produces, and what each one must do to the
/// machine saved on disk.
final class MachineLifecycleTests: XCTestCase {
    /// The whole point: leave the screen, come back, find the machine where it
    /// was.
    func testLeavingTheScreenSavesTheMachineAndComingBackResumesIt() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.state, .suspended)
        XCTAssertTrue(life.shouldResumeOnReturn)
    }

    /// "Arrêter" dismisses the screen, so the stop and the departure arrive one
    /// after the other. Without the guard, the second one saves a snapshot of
    /// the machine the first one just ended — and the machine the user stopped
    /// is waiting for them on the next launch.
    func testStoppingThenLeavingTheScreenDoesNotBringTheMachineBack() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.userStopped(), .forget)
        XCTAssertEqual(life.steppedAway(), .nothing, "un arrêt ne doit pas être enregistré")
        XCTAssertEqual(life.state, .ended)
        XCTAssertFalse(life.shouldResumeOnReturn)
    }

    /// iOS sends the app to the background and later brings it back without the
    /// view ever disappearing. A machine put away on the way out has to be
    /// picked up on the way in; otherwise the user returns to a dead terminal
    /// with no way to restart it but leaving the screen.
    func testAMachineSuspendedInTheBackgroundIsResumedOnTheWayBack() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertTrue(life.shouldResumeOnReturn)

        life.booted()
        XCTAssertEqual(life.state, .running)
        XCTAssertFalse(life.shouldResumeOnReturn, "elle tourne : plus rien à reprendre")
    }

    /// The background/foreground pair can arrive twice, and a screen can
    /// disappear after already being suspended. The second event has nothing
    /// left to save.
    func testSteppingAwayTwiceSavesOnce() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.steppedAway(), .nothing)
        XCTAssertEqual(life.state, .suspended)
    }

    /// A guest that halts itself has no session worth returning to.
    func testAGuestThatEndsItselfTakesItsSavedMachineWithIt() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.guestFinished(), .forget)
        XCTAssertEqual(life.state, .ended)
        XCTAssertFalse(life.shouldResumeOnReturn)
    }

    /// Suspending stops the interpreter on purpose, so its exit comes back
    /// through the same path a real halt does. Acting on it would delete the
    /// snapshot that was just written, and tell the user their machine stopped
    /// as they left the screen.
    func testTheExitCausedBySuspendingIsNotMistakenForTheMachineStopping() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.guestFinished(), .nothing)
        XCTAssertEqual(life.state, .suspended, "l'état ne doit pas passer à « terminé »")
        XCTAssertTrue(life.shouldResumeOnReturn)
        XCTAssertFalse(life.reportsGuestExit)
    }

    /// Same for the exit that "Arrêter" causes: the user has already been told.
    func testTheExitCausedByStoppingIsNotReportedTwice() {
        var life = MachineLifecycle()
        life.booted()
        _ = life.userStopped()
        XCTAssertEqual(life.guestFinished(), .nothing)
        XCTAssertFalse(life.reportsGuestExit)
    }

    /// A save that could not be made leaves a snapshot describing a moment the
    /// machine is no longer at. Resuming it would rewind the user's session.
    func testASaveThatFailedLeavesNothingToResume() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.couldNotSave(), .forget)
        XCTAssertFalse(life.shouldResumeOnReturn)
        XCTAssertEqual(life.state, .ended)
    }

    /// Nothing has run yet: leaving has nothing to save, and stopping has
    /// nothing to stop, but both must be safe to call — the view sends them
    /// from `onDisappear` without knowing.
    func testEventsBeforeTheFirstBootAreHarmless() {
        var life = MachineLifecycle()
        XCTAssertEqual(life.state, .idle)
        XCTAssertEqual(life.steppedAway(), .nothing)
        XCTAssertEqual(life.guestFinished(), .nothing)
        XCTAssertFalse(life.shouldResumeOnReturn)
    }

    /// Stopping and booting again is a fresh machine, not a resumed one.
    func testBootingAfterAStopStartsCleanly() {
        var life = MachineLifecycle()
        life.booted()
        _ = life.userStopped()
        life.booted()
        XCTAssertEqual(life.state, .running)
        XCTAssertTrue(life.reportsGuestExit)
        XCTAssertEqual(life.guestFinished(), .forget)
    }
}
