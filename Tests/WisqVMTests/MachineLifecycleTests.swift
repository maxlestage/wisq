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

    /// The exit after "Arrêter" is a different matter, and treating it like a
    /// suspension is a bug this assertion exists to hold shut. That button only
    /// *asks* the interpreter to stop; the machine is gone when the thread
    /// comes back. Swallowing that exit leaves the model still holding a
    /// machine it will never let go of.
    func testTheExitAfterStoppingStillCounts() {
        var life = MachineLifecycle()
        life.booted()
        _ = life.userStopped()
        XCTAssertTrue(life.reportsGuestExit, "l'arrêt doit encore être conclu")
        XCTAssertEqual(life.guestFinished(), .forget)
        XCTAssertEqual(life.state, .ended)
    }

    /// And once concluded it stays concluded: a machine already suspended is
    /// the only state whose exit is ignored.
    func testOnlyASuspensionSwallowsTheExit() {
        var suspended = MachineLifecycle()
        suspended.booted()
        _ = suspended.steppedAway()
        XCTAssertFalse(suspended.reportsGuestExit)

        let fresh = MachineLifecycle()
        XCTAssertFalse(fresh.reportsGuestExit, "rien n'a tourné : rien à conclure")
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

    /// **« Oublier » tient jusqu'au départ** : quitter l'écran n'écrit plus
    /// la machine, elle s'arrête — et la course suivante se sauve de nouveau.
    func testAForgottenMachineIsNotSavedOnTheWayOut() {
        var life = MachineLifecycle()
        life.booted()
        life.userForgot()
        XCTAssertEqual(life.steppedAway(), .forget)
        XCTAssertEqual(life.state, .ended)
        XCTAssertFalse(life.shouldResumeOnReturn)
        life.booted()
        XCTAssertFalse(life.forgotten, "une nouvelle course n'est pas oubliée")
        XCTAssertEqual(life.steppedAway(), .save)
    }

    // MARK: - Une session refusée est gardée

    /// **« Arrêter » n'efface pas une session refusée.** La console vient de
    /// dire « gardée telle quelle », rien ne tourne, et le bouton reste dans
    /// la barre : il effaçait le fichier sans avertissement — pour un bureau
    /// prêt sauvé par une version plus récente, la perte que tout le refus
    /// voulait empêcher.
    func testStoppingARefusedSessionKeepsIt() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.sessionRefused(), .nothing)
        XCTAssertEqual(life.state, .refused)
        XCTAssertEqual(life.userStopped(), .nothing, "la session refusée est promise gardée")
        XCTAssertEqual(life.state, .refused)
        // « Arrêter » ferme aussi l'écran : le départ qui suit n'écrit rien.
        XCTAssertEqual(life.steppedAway(), .nothing)
        XCTAssertEqual(life.guestFinished(), .nothing)
        XCTAssertFalse(life.shouldResumeOnReturn, "rien à reprendre : rien n'a tourné")
        XCTAssertFalse(life.reportsGuestExit)
    }

    /// **La course du refus.** Quand c'est `restore` qui refuse, le fil
    /// d'émulation le dit au fil principal par une tâche qui passe plus
    /// tard ; une mise en arrière-plan dans l'intervalle trouve encore
    /// `running`. Le fil, lui, a déjà noté le refus : `suspend` le lit après
    /// l'avoir attendu, et n'écrit pas la machine vide par-dessus la session.
    func testARefusalSeenOnlyByTheThreadIsNotSavedOver() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save, "le fil principal n'a encore rien vu")
        XCTAssertEqual(life.interpreterStopped(after: .refused), .nothing, "la machine vide ne s'écrit pas")
        XCTAssertEqual(life.state, .refused)
        XCTAssertFalse(life.shouldResumeOnReturn, "le retour au premier plan ne relance rien")
        // La tâche du fil arrive ensuite, puis « Arrêter » : toujours rien.
        XCTAssertEqual(life.sessionRefused(), .nothing)
        XCTAssertEqual(life.guestFinished(), .nothing)
        XCTAssertEqual(life.userStopped(), .nothing)
    }

    /// Le cas ordinaire n'a pas changé : une machine reprise ou chargée se
    /// sauve en partant, et revient.
    func testAMachineTheInterpreterHadIsSavedOnTheWayOut() {
        var life = MachineLifecycle()
        life.booted()
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.interpreterStopped(after: .running), .save)
        XCTAssertEqual(life.state, .suspended)
        XCTAssertTrue(life.shouldResumeOnReturn)
    }

    /// Un démarrage qui a échoué n'a pas de machine à sauver ; ce qu'on
    /// aurait écrit est une machine neuve, jamais chargée, que la visite
    /// suivante « reprendrait ». La session qu'il n'a pas pu reprendre ne
    /// décrit plus rien non plus : elle part, comme la tâche du fil le fait
    /// pour ce même échec.
    func testABootThatNeverRanIsNotSaved() {
        for start in [MachineLifecycle.Start.failed, .pending] {
            var life = MachineLifecycle()
            life.booted()
            XCTAssertEqual(life.steppedAway(), .save)
            XCTAssertEqual(life.interpreterStopped(after: start), .forget, "\(start)")
            XCTAssertEqual(life.state, .ended)
            XCTAssertFalse(life.shouldResumeOnReturn)
        }
        // Et hors d'une mise de côté, la question ne se pose pas.
        var running = MachineLifecycle()
        running.booted()
        XCTAssertEqual(running.interpreterStopped(after: .running), .nothing)
        XCTAssertEqual(running.state, .running)
    }

    /// Rouvrir la machine refusée la rejuge : c'est une course neuve, et un
    /// « Arrêter » sur une machine qui tourne efface de nouveau.
    func testOpeningARefusedMachineAgainStartsANewRun() {
        var life = MachineLifecycle()
        life.booted()
        life.sessionRefused()
        life.booted()
        XCTAssertEqual(life.state, .running)
        XCTAssertEqual(life.userStopped(), .forget)
        XCTAssertEqual(life.state, .ended)
    }

    /// `RunStart` passe d'un fil à l'autre : noté sur le fil d'émulation
    /// avant son signal de fin, lu par le fil principal après l'attente.
    func testWhatTheThreadRecordedIsReadAfterItSignals() {
        let start = RunStart()
        XCTAssertEqual(start.recorded, .pending)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            defer { finished.signal() }
            start.record(.refused)
        }
        thread.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(start.recorded, .refused)
    }
}
