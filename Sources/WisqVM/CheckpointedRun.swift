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
    private let raw: RawSaving?
    private let pause: @Sendable (TimeInterval) -> Void

    /// **Sauver sans tenir l'instantané en mémoire** : le cœur l'écrit dans
    /// un fichier brut (`take`, sur le fil d'émulation), il est compressé à
    /// côté (`compress`), puis mis à la place de la session sous le verrou
    /// (`install`). Une machine de 4 Gio dont l'invité remplit son cache
    /// disque tenait sinon plusieurs gibioctets de plus le temps d'une
    /// sauvegarde, et iOS tuait l'application à la première, cinq minutes
    /// après le démarrage.
    public struct RawSaving: Sendable {
        public let take: @Sendable () -> URL?
        public let compress: @Sendable (URL) throws -> URL
        public let install: @Sendable (URL) throws -> Void
        public let discard: @Sendable (URL) -> Void

        public init(take: @escaping @Sendable () -> URL?,
                    compress: @escaping @Sendable (URL) throws -> URL,
                    install: @escaping @Sendable (URL) throws -> Void,
                    discard: @escaping @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
            self.take = take
            self.compress = compress
            self.install = install
            self.discard = discard
        }
    }

    /// Tenu pendant chaque écriture, et par `stop` pour poser son drapeau.
    /// Voir `stop`.
    private let lock = NSLock()
    private var stopRequested = false
    /// `stopSaving` : la machine continue, mais plus rien n'est écrit.
    private var savingStopped = false
    /// Une sauvegarde est partie et n'a pas fini : la suivante attend.
    private var writing = false
    private var written = 0
    /// `checkpointNow` : la prochaine tranche sauve sans attendre l'intervalle.
    private var checkpointRequested = false
    /// `setRestShare` : la part du temps où le fil d'émulation se repose.
    private var restShare = 0.0

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
                raw: RawSaving? = nil,
                pause: @escaping @Sendable (TimeInterval) -> Void = { seconds in
                    if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
                },
                write: @escaping @Sendable (Data) throws -> Void) {
        self.machine = machine
        self.interval = interval
        self.minimumWork = minimumWork
        self.slice = slice
        self.clock = clock
        self.pack = pack
        self.perform = perform
        self.raw = raw
        self.pause = pause
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
            let sliceStart = DispatchTime.now().uptimeNanoseconds
            let outcome = machine.runGuest(instructionBudget: slice)
            guard outcome == .stopped else {
                // **L'invité a fini de lui-même** (extinction, redémarrage,
                // faute) : une sauvegarde encore en compression ne doit plus
                // s'écrire. La tâche de fin efface la session juste après ;
                // écrite ensuite, elle ferait reprendre la machine à l'instant
                // d'avant son extinction, ou, après un redémarrage, une
                // mémoire d'avant sur un disque déjà réécrit. Pris sous le
                // verrou : une écriture en cours finit avant le retour.
                stopSaving()
                return outcome
            }
            guard !stopWasRequested else { return outcome }
            lock.lock()
            let share = restShare
            let asked = checkpointRequested
            lock.unlock()
            if share > 0 {
                let ran = Double(DispatchTime.now().uptimeNanoseconds &- sliceStart) / 1e9
                pause(Self.rest(after: ran, share: share))
            }
            let now = clock()
            let work = machine.retiredInstructions &- workAtSave
            guard asked || (now.timeIntervalSince(savedAt) >= interval && work >= minimumWork) else { continue }
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
            // La demande est servie par cette sauvegarde-ci ; gardée tant
            // qu'une écriture en cours la faisait attendre.
            checkpointRequested = false
            lock.unlock()
            // Le disque d'abord, comme à la suspension : ses écritures sont
            // déjà sur le stockage, ceci les y scelle avant que l'instantané
            // ne prétende les connaître.
            machine.flushDisk()
            if let raw {
                guard let file = raw.take() else {
                    lock.lock()
                    writing = false
                    lock.unlock()
                    savedAt = clock()
                    workAtSave = machine.retiredInstructions
                    continue
                }
                perform { [self] in
                    let packed = try? raw.compress(file)
                    lock.lock()
                    // Relu au moment d'installer, comme plus bas : un `stop`
                    // a peut-être déjà effacé la sauvegarde.
                    if let packed {
                        if !stopRequested, !savingStopped, (try? raw.install(packed)) != nil {
                            written += 1
                        } else {
                            raw.discard(packed)
                        }
                    }
                    writing = false
                    lock.unlock()
                }
                savedAt = clock()
                workAtSave = machine.retiredInstructions
                continue
            }
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

    /// **Sauver à la prochaine tranche**, sans attendre l'intervalle ni le
    /// travail minimal. C'est ce que fait l'application quand elle part en
    /// arrière-plan en laissant la machine tourner : si iOS l'arrête quand
    /// même, la session reprend de là, pas de cinq minutes plus tôt.
    public func checkpointNow() {
        lock.lock()
        checkpointRequested = true
        lock.unlock()
    }

    /// **La part du temps où le fil d'émulation se repose**, entre zéro
    /// (pleine vitesse) et `maximumRestShare`. En arrière-plan, iOS arrête une
    /// application qui tient un cœur à plus de 80 % pendant une minute : la
    /// machine y tourne à une allure qui reste sous ce seuil, au lieu d'être
    /// arrêtée.
    public func setRestShare(_ share: Double) {
        lock.lock()
        restShare = min(max(share, 0), Self.maximumRestShare)
        lock.unlock()
    }

    public static let maximumRestShare = 0.9

    /// Combien se reposer après une tranche de `seconds` secondes pour que le
    /// repos fasse `share` du temps total.
    public static func rest(after seconds: Double, share: Double) -> Double {
        guard share > 0, seconds > 0 else { return 0 }
        let bounded = min(share, maximumRestShare)
        return seconds * bounded / (1 - bounded)
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
