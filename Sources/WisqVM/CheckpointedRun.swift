import Foundation

/// **Une machine qui se sauve d'elle-même pendant qu'elle tourne.**
///
/// La sauvegarde n'avait lieu qu'au départ : quand iOS met l'application en
/// arrière-plan, `LocalVMModel.suspend` arrête la machine et l'écrit. Mais iOS
/// ne prévient pas toujours. Une application tuée pour la mémoire, un
/// plantage, une batterie vide : rien n'était écrit, et le démarrage d'une
/// image de cloud — vingt minutes pour Fedora sur ce cœur — était à refaire en
/// entier. C'est le seul moment où l'on perd vraiment quelque chose.
///
/// Ici la machine tourne **par tranches**, sur son propre fil, et entre deux
/// tranches elle s'écrit quand c'est dû. Sur le même fil, et c'est tout le
/// point : l'état n'est lisible qu'à l'arrêt, et entre deux tranches il l'est,
/// sans verrou ni course. Le démarrage lit déjà un instantané quand il en
/// trouve un ; une machine tuée reprend donc à sa dernière sauvegarde au lieu
/// de redémarrer.
///
/// **Quand c'est dû** : au moins `interval` secondes depuis la dernière, et
/// au moins `minimumWork` instructions retirées depuis. Une invite immobile
/// ne retire presque rien — l'attente est sautée, pas exécutée — et la
/// réécrire toutes les cinq minutes userait la mémoire flash et la batterie
/// pour une machine identique à celle déjà sauvée.
public final class CheckpointedRun: @unchecked Sendable {
    private let machine: GuestMachine
    private let interval: TimeInterval
    private let minimumWork: UInt64
    private let slice: UInt64
    private let clock: @Sendable () -> Date
    private let pack: @Sendable (Data) -> Data
    private let write: @Sendable (Data) throws -> Void
    private let perform: @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Tenu pendant chaque écriture, et par `stop` pour poser son drapeau.
    /// Voir `stop`.
    private let lock = NSLock()
    private var stopRequested = false
    /// `stopSaving` : la machine continue, mais plus rien n'est écrit.
    private var savingStopped = false
    /// Une sauvegarde est partie et n'a pas fini : la suivante attend.
    private var writing = false
    private var written = 0

    /// Combien de sauvegardes ont été écrites.
    public var checkpoints: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    /// Cinq minutes, deux milliards d'instructions. **L'invité ne s'arrête
    /// que le temps de l'instantané** — 0,73 s pour Fedora reprise à
    /// 18 milliards, sur la machine de mesure — et la compression puis
    /// l'écriture, 2,4 s de plus pour 122 Mio, se font à côté, sur `perform`
    /// : une file à elles par défaut. Les tests passent une exécution sur
    /// place, pour compter sans course.
    public init(machine: GuestMachine, interval: TimeInterval = 300,
                minimumWork: UInt64 = 2_000_000_000, slice: UInt64 = 50_000_000,
                clock: @escaping @Sendable () -> Date = { Date() },
                pack: @escaping @Sendable (Data) -> Data = SnapshotFile.pack,
                perform: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
                    DispatchQueue(label: "app.wisq.checkpoint", qos: .utility).async(execute: $0)
                },
                write: @escaping @Sendable (Data) throws -> Void) {
        self.machine = machine
        self.interval = interval
        self.minimumWork = minimumWork
        self.slice = slice
        self.clock = clock
        self.pack = pack
        self.perform = perform
        self.write = write
    }

    /// Fait tourner la machine jusqu'à sa fin ou jusqu'à `stop`. À appeler sur
    /// le fil d'émulation, à la place de `runGuest(instructionBudget: .max)`.
    ///
    /// **Une tranche épuisée rend `.stopped`, comme un arrêt demandé** : le
    /// protocole ne les distingue pas. C'est le drapeau d'ici qui tranche —
    /// posé par `stop` avant d'arrêter la machine, il est forcément vu quand
    /// la tranche rend la main.
    public func run() -> GuestOutcome {
        var savedAt = clock()
        var workAtSave = machine.retiredInstructions
        while true {
            let outcome = machine.runGuest(instructionBudget: slice)
            guard outcome == .stopped, !stopWasRequested else { return outcome }
            let now = clock()
            let work = machine.retiredInstructions &- workAtSave
            guard now.timeIntervalSince(savedAt) >= interval, work >= minimumWork else { continue }
            lock.lock()
            if stopRequested {
                lock.unlock()
                return .stopped
            }
            if savingStopped {
                lock.unlock()
                continue
            }
            // La précédente écrit encore : on réessaiera à la prochaine
            // tranche, sans repartir de zéro sur l'intervalle.
            if writing {
                lock.unlock()
                continue
            }
            writing = true
            lock.unlock()
            // Le disque d'abord, comme à la suspension : ses écritures sont
            // déjà sur le stockage, ceci les y scelle avant que l'instantané
            // ne prétende les connaître.
            machine.flushDisk()
            let snapshot = machine.snapshot()
            perform { [self] in
                let packed = pack(snapshot)
                lock.lock()
                // Relu **au moment d'écrire** : un `stop` arrivé pendant la
                // compression a peut-être déjà effacé la sauvegarde, et
                // écrire celle-ci la ferait revenir. Un échec — plus de place
                // — ne change rien à la machine, qui continue.
                if !stopRequested, !savingStopped, (try? write(packed)) != nil { written += 1 }
                writing = false
                lock.unlock()
            }
            savedAt = clock()
            workAtSave = machine.retiredInstructions
        }
    }

    /// Arrête la machine, depuis n'importe quel fil.
    ///
    /// **Ne rend la main qu'après une écriture en cours**, et aucune ne
    /// commence après. « Arrêter » efface l'instantané juste ensuite ; une
    /// écriture qui finirait plus tard ferait revenir au prochain lancement
    /// la machine que la personne vient d'arrêter, et une sauvegarde de
    /// suspension écrasée par une plus ancienne reprendrait une mémoire en
    /// retard sur son disque. Le verrou ordonne les deux. Une compression en
    /// cours, elle, n'est pas attendue : elle sera jetée.
    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        machine.stop()
    }

    /// La machine continue, mais **plus aucune sauvegarde n'est écrite** —
    /// celle qui écrivait finit avant le retour, comme pour `stop`. C'est ce
    /// que demande « Oublier » : la sauvegarde effacée juste après ne doit
    /// pas revenir avec la tranche suivante.
    public func stopSaving() {
        lock.lock()
        savingStopped = true
        lock.unlock()
    }

    private var stopWasRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }
}
