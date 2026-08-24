import Foundation

/// What becomes of a local machine when the user, or iOS, or the guest itself
/// ends a session — and whether the machine that comes back next time is the
/// same one.
///
/// This is a handful of transitions, and it lives here, apart from the view
/// model that drives it, for the reason `SuspendedMachine` does: the app layer
/// only builds on Apple platforms, so nothing in it is covered by the runner
/// that runs on every commit. Two defects in exactly these transitions got as
/// far as a pull request while the logic was inline — "Arrêter" saved the
/// machine it had just ended, and a machine put away when the app went to the
/// background never came back when it returned. Neither was visible to the
/// compiler, and both are one assertion each here.
public struct MachineLifecycle: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing running: before the first boot, and after a suspension.
        case idle
        /// The interpreter has the machine.
        case running
        /// Put away deliberately, with a snapshot on disk to come back to.
        case suspended
        /// Over for good — the user stopped it, or the guest did.
        case ended
    }

    /// What the caller has to do to the saved machine on disk.
    public enum Action: Equatable, Sendable {
        case nothing
        /// Wait for the interpreter to come back, then write the snapshot.
        case save
        /// Delete the saved machine: whatever comes next is a fresh boot.
        case forget
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func booted() {
        state = .running
    }

    /// The user pressed "Arrêter".
    ///
    /// Ends it whatever the state, and forgets the saved machine: the word has
    /// to mean stopped rather than hidden, and a machine that reappears after
    /// being stopped is the version of this bug users would actually report.
    public mutating func userStopped() -> Action {
        state = .ended
        return .forget
    }

    /// The screen went away, or iOS moved the app to the background.
    ///
    /// Only a running machine is worth putting away. This returning `.nothing`
    /// for every other state is what stops a stop from being undone: pressing
    /// "Arrêter" dismisses the screen, so the two events arrive one after the
    /// other, and an unguarded save here writes a snapshot of the machine the
    /// user just ended.
    public mutating func steppedAway() -> Action {
        guard state == .running else { return .nothing }
        state = .suspended
        return .save
    }

    /// The save could not be made — the interpreter did not come back in time,
    /// or the write failed. There is nothing to return to, so the stale
    /// snapshot has to go rather than be resumed in place of this session.
    public mutating func couldNotSave() -> Action {
        state = .ended
        return .forget
    }

    /// The interpreter returned on its own.
    ///
    /// The one exit that must be ignored is the one we caused: suspending
    /// stops the interpreter on purpose, and acting on that would delete the
    /// snapshot just written and tell the user their machine stopped as they
    /// left the screen.
    ///
    /// Every other exit counts, including the one after "Arrêter". That button
    /// does not end the machine by itself — it asks the interpreter to stop,
    /// and the machine is only really gone when the thread comes back. A first
    /// version treated that exit as already-reported and swallowed it, which
    /// left the model in `running` with a machine it would never release.
    ///
    /// It takes no outcome because none of them change the answer: a machine
    /// that powered off, rebooted, or was stopped has no session on disk that
    /// matches where it is now.
    public mutating func guestFinished() -> Action {
        guard state == .running || state == .ended else { return .nothing }
        state = .ended
        return .forget
    }

    /// Whether coming back to this screen should resume the machine rather
    /// than leave the user looking at a dead terminal.
    public var shouldResumeOnReturn: Bool { state == .suspended }

    /// Whether the guest's exit is the machine's own — and so worth acting
    /// on — rather than the one suspending asked for.
    public var reportsGuestExit: Bool { state == .running || state == .ended }
}

