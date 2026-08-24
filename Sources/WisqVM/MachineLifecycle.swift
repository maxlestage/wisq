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
    /// Meaningful only while the machine was running: after a suspension the
    /// exit is one we asked for, and after a stop it is one we already told the
    /// user about. Reporting either would show "Arrêtée." over a screen the
    /// user is leaving.
    ///
    /// It takes no outcome because none of them change the answer. A machine
    /// that powered off or rebooted has no session worth keeping, and one that
    /// stopped was never saved, so nothing on disk matches where it is now —
    /// the saved machine goes in every case.
    public mutating func guestFinished() -> Action {
        guard state == .running else { return .nothing }
        state = .ended
        return .forget
    }

    /// Whether coming back to this screen should resume the machine rather
    /// than leave the user looking at a dead terminal.
    public var shouldResumeOnReturn: Bool { state == .suspended }

    /// Whether the guest's own exit should be shown to the user.
    public var reportsGuestExit: Bool { state == .running }
}

