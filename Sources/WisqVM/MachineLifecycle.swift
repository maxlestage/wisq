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
        /// **La session sauvée n'a pas pu être reprise, et elle est gardée.**
        /// Rien ne tourne, et la console a promis « gardée telle quelle » :
        /// de cet état, seul « Oublier » efface le fichier. Voir
        /// `SavedSession`.
        case refused
        /// **Le démarrage a été refusé avant la première instruction**, et
        /// aucune session n'était en jeu : la console a dit pourquoi, rien ne
        /// tourne, et rien ne s'efface de cet état — ni par « Arrêter », ni
        /// par la fin tardive d'une course précédente. Voir `BootRefusal`.
        case notStarted
    }

    /// Ce que le fil d'émulation a fait avant de rendre la main — ce que
    /// `suspend` doit savoir avant d'écrire quoi que ce soit.
    ///
    /// **La raison d'être : la fenêtre entre le fil et le fil principal.**
    /// Quand c'est la reprise elle-même qui refuse la session, le fil le dit
    /// au fil principal par une tâche qui passe *plus tard* ; entre-temps,
    /// la machine neuve — jamais reprise, jamais chargée — est encore là et
    /// l'état vaut `running`. Une mise en arrière-plan dans cette fenêtre
    /// sauvait cette machine vide **par-dessus** la session promise gardée,
    /// et la réouverture suivante reprenait le vide.
    public enum Start: Equatable, Sendable {
        /// Rien de dit encore : la reprise ou le chargement est en cours.
        case pending
        /// Reprise ou chargée : l'interprète a la vraie machine, et son état
        /// vaut d'être sauvé.
        case running
        /// La reprise a refusé la session (`SavedSession.Unreadable`).
        case refused
        /// Le démarrage a échoué avant que l'interprète ne tourne.
        case failed
        /// **L'invité a fini de lui-même** : éteint, redémarré, ou arrêté par
        /// une faute. Noté par le fil dès que `run()` rend la main, avant son
        /// signal de fin : sa tâche, elle, passe plus tard, et une mise en
        /// arrière-plan entre les deux voyait encore `running` — elle
        /// écrivait l'instantané d'une machine éteinte, que la visite
        /// suivante reprenait sans un mot.
        case finished

        /// Ce que dit la fin de la course. `.stopped` est le seul arrêt qu'on
        /// a demandé (`CheckpointedRun.run` ne rend une tranche épuisée que
        /// sur demande) : la machine est intacte et vaut d'être sauvée. Tout
        /// le reste est l'invité qui a fini.
        public static func after(_ outcome: GuestOutcome) -> Start {
            outcome == .stopped ? .running : .finished
        }
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
    /// « Oublier » a été touché pendant cette course : plus rien d'elle ne
    /// doit être écrit.
    public private(set) var forgotten = false
    /// **La session que cette course peut toucher** : l'identité de l'image
    /// qu'elle a lue (`SuspendedMachine.identity`), ou `nil` tant qu'elle ne
    /// l'a pas lue.
    ///
    /// Le nom vivait dans l'application, d'une course à l'autre : un refus
    /// tombé avant la lecture de l'image laissait celui de la course d'avant,
    /// et « Oublier », offert sur cette session-là, effaçait celle d'une autre
    /// machine. Chaque démarrage l'oublie (`booted`).
    public private(set) var session: String?

    public init() {}

    public mutating func booted() {
        state = .running
        forgotten = false
        session = nil
    }

    /// L'image est lue : la course sait sous quel nom sa session est rangée.
    public mutating func identified(_ session: String) {
        self.session = session
    }

    /// **Le démarrage est refusé avant la première instruction** : rien ne
    /// tourne, et la session sauvée — de cette machine ou d'une autre — n'est
    /// pas touchée. Rend toujours `.nothing`. Voir `BootRefusal`.
    @discardableResult
    public mutating func refusedToStart(_ refusal: BootRefusal) -> Action {
        state = refusal.keepsASession ? .refused : .notStarted
        return .nothing
    }

    /// The user pressed "Oublier": keep running now, and do not come back to
    /// this machine next time.
    ///
    /// **It has to hold until the machine is gone.** Deleting the file was
    /// all it did, and the machine was still `running`: the next checkpoint,
    /// or leaving the screen, wrote it straight back, and the next visit
    /// resumed the wedged guest the user had just asked to be rid of.
    public mutating func userForgot() {
        forgotten = true
    }

    /// The user pressed "Arrêter".
    ///
    /// Ends it whatever the state, and forgets the saved machine: the word has
    /// to mean stopped rather than hidden, and a machine that reappears after
    /// being stopped is the version of this bug users would actually report.
    ///
    /// **Sauf une session refusée.** Rien ne tourne alors, donc rien à
    /// arrêter, et la console vient de dire que la session est gardée et que
    /// « Oublier » est le geste qui repart de zéro. Le bouton « Arrêter »,
    /// lui, reste dans la barre : l'effacement qu'il faisait était sans
    /// avertissement, et pour un bureau prêt sauvé par une version plus
    /// récente, c'était exactement la perte que `SavedSession` empêche.
    ///
    /// **Ni un démarrage refusé** (`notStarted`), pour la même raison.
    ///
    /// `seen` : ce que le fil d'émulation a noté de la course
    /// (`RunStart.recorded`). Un refus ou un échec qu'il a déjà vu, mais dont
    /// la tâche n'est pas encore passée sur le fil principal, compte déjà :
    /// rien n'a tourné, rien ne s'efface.
    public mutating func userStopped(seen start: Start? = nil) -> Action {
        switch start {
        case .refused?: state = .refused
        case .failed?: state = .notStarted
        default: break
        }
        if state == .refused || state == .notStarted { return .nothing }
        state = .ended
        return .forget
    }

    /// La session sauvée ne se reprend pas : elle est gardée, rien ne tourne.
    ///
    /// Dit par le fil principal quand il la juge avant de démarrer, et par
    /// la tâche que le fil d'émulation envoie quand c'est `restore` qui la
    /// refuse. Rend toujours `.nothing` : le fichier ne se touche pas.
    @discardableResult
    public mutating func sessionRefused() -> Action {
        state = .refused
        return .nothing
    }

    /// Le fil d'émulation est revenu après un `steppedAway() == .save` :
    /// l'écriture n'a lieu que si l'interprète avait vraiment la machine.
    ///
    /// Une session refusée reste gardée et l'état le dit (rien à reprendre au
    /// retour). **Un démarrage qui a échoué** n'a rien à sauver, et rien à
    /// effacer non plus : la session qu'il n'a pas pu reprendre — un disque
    /// qui ne se branchait plus — est gardée, comme la tâche du fil la garde
    /// pour ce même échec (`BootRefusal.couldNotStart`). Elle s'effaçait. Un
    /// invité qui a fini de lui-même juste avant le départ, lui, emporte sa
    /// session : elle décrit une machine qui n'existe plus, et c'est ce que
    /// sa tâche aurait effacé. L'état `ended` laisse cette tâche dire la fin
    /// (`reportsGuestExit`) sans rien relancer (`restartsOnReboot`).
    public mutating func interpreterStopped(after start: Start) -> Action {
        guard state == .suspended else { return .nothing }
        switch start {
        case .running:
            return .save
        case .refused:
            state = .refused
            return .nothing
        case .failed:
            state = .notStarted
            return .nothing
        case .pending, .finished:
            state = .ended
            return .forget
        }
    }

    /// **La taille de la machine à construire**, ou `nil` quand la session
    /// ne tient pas dans la mémoire libre (`SessionMemory.choose`).
    ///
    /// Ce refus-là aussi promet « gardée telle quelle », et il passait par
    /// `guestFinished` : l'état valait `ended`, et « Arrêter », resté dans
    /// la barre, effaçait la session sans avertissement. C'est le cas même
    /// du bureau prêt de 1 Gio sur un téléphone qui manque de mémoire libre.
    /// Il passe maintenant par `sessionRefused`, comme la session illisible.
    public mutating func machineSize(_ choice: SessionMemory.Choice) -> Int? {
        switch choice {
        case .boot(let size), .resume(let size):
            return size
        case .tooLittleRoom:
            sessionRefused()
            return nil
        }
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
        // Forgotten: there is nothing to put away, and the machine cannot
        // keep running behind a screen that is gone. It ends here.
        if forgotten {
            state = .ended
            return .forget
        }
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

    /// Si un invité qui demande à redémarrer est relancé.
    ///
    /// Seulement une machine qui tournait encore. Arrêtée par la personne, ou
    /// finie pendant un départ de l'écran (`interpreterStopped`), elle vaut
    /// `ended` : la relancer ferait tourner une machine derrière un écran
    /// parti, ou que la personne venait d'arrêter.
    public var restartsOnReboot: Bool { state == .running }
}

/// **Ce que le fil d'émulation a fait de sa course, lisible du fil
/// principal.** Le fil l'écrit avant de signaler sa fin ; `suspend` le lit
/// après l'avoir attendue, donc sans course. Voir `MachineLifecycle.Start`.
public final class RunStart: @unchecked Sendable {
    private let lock = NSLock()
    private var start: MachineLifecycle.Start = .pending

    public init() {}

    public func record(_ start: MachineLifecycle.Start) {
        lock.lock()
        defer { lock.unlock() }
        self.start = start
    }

    public var recorded: MachineLifecycle.Start {
        lock.lock()
        defer { lock.unlock() }
        return start
    }
}
