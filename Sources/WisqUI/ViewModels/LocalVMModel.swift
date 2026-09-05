#if os(iOS)
import Foundation
import Observation
import SwiftUI
import WisqVM

/// Drives one local Linux VM: owns the machine, runs it on its own thread, and
/// mirrors the console into observable state for the terminal view.
@Observable
@MainActor
public final class LocalVMModel {
    public enum Status: Equatable {
        case idle
        case running
        case finished(String)

        public var isRunning: Bool { self == .running }
    }

    public private(set) var status: Status = .idle
    /// Console text, ANSI-stripped and line-edited, bounded in lines.
    public private(set) var consoleText = ""

    private var machine: GuestMachine?
    private let sink = ConsoleSink()
    /// Signalled when the emulation thread leaves `run()`. Suspending has to
    /// wait for that: `snapshot()` reads the machine's state, and reading it
    /// while the interpreter is writing it would save something that never
    /// existed.
    private var runFinished: DispatchSemaphore?
    /// What becomes of the saved machine on each event, decided by a type that
    /// builds on Linux and is therefore covered by tests — this wiring is not.
    private var life = MachineLifecycle()
    private var kernelName = ""
    /// Which run a thread's completion belongs to. Suspending releases the
    /// machine while its thread is still unwinding, so a completion can arrive
    /// after the next machine has already booted; without this it would report
    /// the old machine's exit over the new one and delete its saved state.
    private var run = 0

    /// Where suspended machines are written. `nil` means Application Support,
    /// which is what the app uses; a test passes its own directory so a run
    /// cannot see — or outlive — another one's saved machine.
    private let storage: URL?

    public init(storageDirectory: URL? = nil) {
        storage = storageDirectory
    }

    /// Whether leaving and coming back would resume rather than restart.
    public var willResume: Bool { SuspendedMachine.exists(kernel: kernelName, in: storage) }

    /// Whether returning to the foreground should pick the machine back up.
    /// The view asks, because iOS can take the app away and give it back
    /// without the screen ever disappearing.
    public var shouldResumeOnReturn: Bool { life.shouldResumeOnReturn }

    public func boot(kernelURL: URL) {
        guard machine == nil else { return }
        // Coming back from a suspension keeps the console: this is the same
        // model instance the user was looking at a moment ago, so its grid
        // still holds their session. Clearing it would make a resumption look
        // like a reboot — the one thing the whole feature exists to avoid.
        let resuming = life.shouldResumeOnReturn
        life.booted()
        status = .running
        if !resuming {
            consoleText = ""
            sink.reset()
        }

        // One refresh in flight at a time. The guest writes on its own thread
        // and can produce console faster than the main actor can render it; a
        // hop per chunk would queue work without bound and the interface would
        // fall behind the machine it is meant to be showing.
        // La mémoire de cette machine est celle réglée pour ce noyau. Lue sur
        // le nom du fichier et non sur ses octets : cette ligne est avant la
        // lecture de l'image, exprès — c'est ce qui permet de refuser un
        // fichier trop grand sans le charger — et l'empreinte n'existe
        // qu'après.
        let ramSize = KernelMemory.size(
            forKernel: kernelURL.lastPathComponent, in: storage)

        // Ce que le téléphone a de libre **maintenant**, pas quand le réglage
        // a été posé. `KernelMemory.size` a déjà rogné sur ce plafond, donc
        // cette garde ne se déclenche que si la mémoire disponible a baissé
        // depuis — un autre programme qui a grandi, une session distante
        // ouverte à côté. Démarrer quand même ferait tuer l'application par
        // iOS au milieu du démarrage : le plantage sans cause apparente que
        // cette application a déjà infligé une fois.
        let roomNow = KernelMemory.ceiling
        if ramSize > roomNow {
            _ = life.guestFinished()
            finish(with: KernelMemory.notEnoughRoomExplanation(
                requested: ramSize, ceiling: roomNow,
                name: kernelURL.lastPathComponent))
            self.machine = nil
            runFinished = nil
            return
        }
        // **Ce que le fichier est, avant de fabriquer quoi que ce soit.**
        //
        // L'ordre a changé ici, et c'est le cœur du branchement : la machine
        // était construite d'abord, parce qu'il n'y en avait qu'une sorte.
        // Maintenant qu'un fichier peut demander un cœur x86-64 ou un cœur
        // RISC-V, il faut l'avoir lu avant de savoir quoi construire.
        //
        // L'ordre compte aussi pour une raison plus ancienne, et c'est un
        // défaut vécu : sur une image d'installation d'Arch, le refus disait
        // « fait 5939.2 Mo, la machine n'a que 64.0 Mo » — vrai mot pour mot,
        // et trompeur en entier, parce qu'il désigne un nombre et pousse donc
        // vers le réglage de mémoire. Quarante kibioctets suffisent à savoir
        // qu'aucune mémoire n'y changera rien.
        let kind = KernelImageKind.identify(fileAt: kernelURL)
        // **Un média de démarrage n'est pas un noyau, et le dire passe avant
        // tout le reste.** Depuis que l'import le garde, il apparaît dans la
        // liste ; le toucher rendait le refus d'un noyau compressé, qui envoie
        // chercher une version non compressée d'un fichier qui n'en a pas.
        if kind.core == nil, BootMedia.couldBeMedia(fileAt: kernelURL) {
            _ = life.guestFinished()
            finish(with: """
                \(kernelURL.lastPathComponent) est un fichier compressé — wisq \
                le garde comme initramfs.

                Un initramfs ne démarre pas tout seul : c'est le noyau qui le \
                déballe. Touchez le noyau — `vmlinuz…`, `bzImage` — et wisq \
                prendra celui-ci avec.
                """)
            self.machine = nil
            runFinished = nil
            return
        }
        if let refusal = KernelImageKind.cannotRunHereExplanation(
            kind, name: kernelURL.lastPathComponent) {
            _ = life.guestFinished()
            finish(with: refusal)
            self.machine = nil
            runFinished = nil
            return
        }
        // Un fichier que personne n'a reconnu part sur le cœur historique :
        // `unknown` est une permission, pas un doute, et refuser faute d'avoir
        // su lire serait pire que de laisser essayer.
        let core = kind.core ?? .riscv32

        // Une machine PC a besoin de plus que le réglage d'une machine RISC-V
        // — son noyau décompressé fait à lui seul trente-cinq mébioctets — et
        // le plafond du téléphone, lui, ne change pas. Quand les deux ne se
        // rencontrent pas, on le dit au lieu de démarrer une machine trop
        // petite qui échouerait sans expliquer pourquoi.
        var machineRAM = Int(ramSize)
        if core == .x86_64 {
            machineRAM = max(machineRAM, X86Machine.minimumRAMSize)
            if machineRAM > Int(roomNow) {
                _ = life.guestFinished()
                finish(with: """
                    \(kernelURL.lastPathComponent) est un noyau pour PC, et une \
                    machine PC a besoin d'au moins \
                    \(X86Machine.minimumRAMSize >> 20) Mo — son noyau \
                    décompressé en fait trente-cinq à lui seul.

                    Cet appareil n'a que \(roomNow >> 20) Mo de libre en ce \
                    moment. Fermez ce qui tourne à côté et réessayez.
                    """)
                self.machine = nil
                runFinished = nil
                return
            }
        }

        let machine = makeLocalMachine(
            for: core, ramSizeBytes: machineRAM
        ) { [sink] chunk in
            guard sink.append(chunk) else { return }
            Task { @MainActor [weak self] in
                self?.consoleText = sink.takeText()
            }
        }
        self.machine = machine

        // The emulator owns a whole thread for its lifetime: it is a CPU, not a
        // callback. The quality of service is explicit because the default lets
        // the scheduler park it on an efficiency core, where an interpreter
        // runs several times slower — and this is the thread whose speed the
        // user is watching.
        let finished = DispatchSemaphore(value: 0)
        runFinished = finished
        run += 1
        let thisRun = run

        // The image is read here rather than on the emulation thread because
        // its bytes are what a saved machine is filed under, and `kernelName`
        // has to be settled before `stop()` or `suspend()` can be called — both
        // of which the view can trigger the instant this returns. A few
        // megabytes off local storage is a few milliseconds, and this method
        // already read a larger snapshot synchronously.
        // Asked of the filesystem, before a single byte is read.
        //
        // This is where the app died. `Data(contentsOf:)` reads the whole file
        // into memory on this thread, and the size check lived after it, inside
        // `LinuxMachine.load`. Someone who picked a distribution image — an ISO
        // of two gigabytes, thirty-two times this machine's entire RAM — got
        // the phone's memory pressure killer instead of a refusal: the app
        // vanished with no message, on a file the next line would have rejected
        // in microseconds.
        // Ce plafond-là est celui de la machine RISC-V : son image est copiée
        // dans la RAM de l'invité, sous l'arbre de périphériques. Le chargeur
        // PC a le sien et refuse proprement, donc l'appliquer aux deux
        // refuserait des noyaux parfaitement valables.
        if core == .riscv32,
            let size = try? FileManager.default.attributesOfItem(
            atPath: kernelURL.path)[.size] as? Int,
            size > LinuxMachine.maximumKernelImageBytes(forRAMSize: ramSize) {
            _ = life.guestFinished()
            finish(with: LinuxMachine.tooLargeExplanation(
                size: size, name: kernelURL.lastPathComponent, ramSize: ramSize))
            self.machine = nil
            runFinished = nil
            return
        }

        let image: Data
        do {
            image = try Data(contentsOf: kernelURL)
        } catch {
            _ = life.guestFinished()
            finish(with: "Démarrage impossible : \(error.localizedDescription)")
            self.machine = nil
            runFinished = nil
            return
        }
        kernelName = SuspendedMachine.identity(of: image, named: kernelURL.lastPathComponent)
        let saved = SuspendedMachine.load(kernel: kernelName, in: storage)

        // **Un noyau de PC ne démarre à rien sans son initramfs.** Il n'a
        // aucun pilote de disque compilé dedans — ce sont des modules, et ils
        // vivent justement là. Sans lui, ce qui suit est un démarrage complet,
        // 262 lignes de journal, puis « VFS: Unable to mount root fs on
        // unknown-block(0,0) » : le dire ici vaut mieux que de le faire vivre.
        let ramdisk: Data?
        if core == .x86_64 {
            let media = KernelLibrary.list().filter { BootMedia.couldBeMedia(fileAt: $0) }
            guard let paired = BootMedia.pair(
                kernel: kernelURL.lastPathComponent, among: media).url,
                let bytes = try? Data(contentsOf: paired) else {
                _ = life.guestFinished()
                finish(with: """
                    \(kernelURL.lastPathComponent) est un noyau pour PC, et un \
                    noyau de PC a besoin d'un initramfs pour démarrer : ses \
                    pilotes de disque n'y sont pas compilés, ils vivent dedans.

                    Importez celui de votre distribution — il s'appelle \
                    `initramfs-…` ou `initrd.img-…`, et il est compressé — et \
                    wisq le prendra avec ce noyau.
                    """)
                self.machine = nil
                runFinished = nil
                return
            }
            ramdisk = bytes
        } else {
            ramdisk = nil
        }

        let thread = Thread { [weak self] in
            defer { finished.signal() }
            let outcome: GuestOutcome
            do {
                // A saved machine is resumed in place of booting. If the file
                // is not a snapshot — an older format, a truncated write — the
                // restore throws and the kernel is booted instead, which is the
                // only useful answer and better than refusing to start.
                if let saved, (try? machine.restore(saved)) != nil {
                    // nothing else to do: the guest is already mid-life
                } else {
                    try machine.load(
                        kernelImage: image, commandLine: nil, initialRamdisk: ramdisk)
                }
                outcome = machine.runGuest(instructionBudget: .max)
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, thisRun == self.run else { return }
                    // A boot that never happened still ends the session, so the
                    // lifecycle has to hear about it: leaving it in `running`
                    // would let a later departure try to save a machine that
                    // does not exist.
                    if self.life.guestFinished() == .forget {
                        SuspendedMachine.clear(kernel: self.kernelName, in: self.storage)
                    }
                    self.finish(with: "Démarrage impossible : \(error.localizedDescription)")
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, thisRun == self.run else { return }
                // The interpreter also returns when we asked it to — suspending
                // stops it on purpose — so the lifecycle decides whether this
                // exit is the machine's own, and only then is it reported.
                let reports = self.life.reportsGuestExit
                if self.life.guestFinished() == .forget {
                    SuspendedMachine.clear(kernel: self.kernelName, in: self.storage)
                }
                guard reports else { return }
                switch outcome {
                case .powerOff: self.finish(with: "La machine s'est éteinte.")
                case .reboot: self.finish(with: "La machine a redémarré ; relancez-la.")
                case .stopped: self.finish(with: "Arrêtée.")
                // Un refus du cœur est **nommé**. « Arrêtée » à sa place
                // enverrait chercher partout ; l'instruction qui a manqué est
                // ce qui permet de savoir quoi écrire ensuite.
                case .faulted(let reason):
                    self.finish(with: "La machine s'est arrêtée : \(reason)")
                }
            }
        }
        thread.name = "app.wisq.vm"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func send(_ text: String) {
        machine?.send(Data(text.utf8))
    }

    public func sendLine(_ line: String) {
        send(line + "\n")
    }

    /// Ends the machine for good, at the user's request. The saved state goes
    /// too: "Arrêter" has to mean stopped, not hidden.
    public func stop() {
        if life.userStopped() == .forget {
            SuspendedMachine.clear(kernel: kernelName, in: storage)
        }
        machine?.stop()
    }

    /// Throws the saved machine away without touching the one running.
    ///
    /// "Arrêter" already clears it, but only by ending the session — there was
    /// no way to say "keep running, just do not come back to this next time".
    /// A user who has wedged their guest wants exactly that: leave now, and
    /// start clean.
    public func forgetSavedMachine() {
        SuspendedMachine.clear(kernel: kernelName, in: storage)
    }

    /// Whether there is a saved machine to forget, so the interface can offer
    /// the command only when it would do something.
    public var hasSavedMachine: Bool { willResume }

    /// Saves the machine and lets it go, so the next visit resumes it.
    ///
    /// Deliberately synchronous. It runs when iOS is taking the app away or the
    /// screen is going, and both of those are moments where returning before
    /// the file is written means not writing it at all. The wait is bounded:
    /// `stop()` takes effect within one 1024-instruction slice, and the write
    /// is a few megabytes. Given the choice between a brief hitch and a machine
    /// that silently fails to save, the hitch is the right one.
    public func suspend() {
        guard let machine, let finished = runFinished else { return }
        guard life.steppedAway() == .save else { return }
        machine.stop()
        // If the interpreter has not come back in time, saving would read state
        // it is still writing. Better to lose the session than to save a
        // machine that never existed.
        guard finished.wait(timeout: .now() + 5) == .success else {
            if life.couldNotSave() == .forget { SuspendedMachine.clear(kernel: kernelName, in: storage) }
            return
        }
        do {
            try SuspendedMachine.save(machine.snapshot(), kernel: kernelName, in: storage)
        } catch {
            if life.couldNotSave() == .forget { SuspendedMachine.clear(kernel: kernelName, in: storage) }
        }
        self.machine = nil
        runFinished = nil
        status = .idle
    }

    /// What a change of scene phase means for the machine.
    ///
    /// This lives here rather than in the view because it is a decision, and
    /// decisions in a `body` are decisions nothing runs in a test. iOS can take
    /// the app away and give it back without the screen ever disappearing, so
    /// the way in matters as much as the way out: a machine put away on
    /// `.background` and not picked up on `.active` leaves the user looking at
    /// a dead terminal they can only escape by leaving the screen.
    public func scenePhaseChanged(to phase: ScenePhase, kernelURL: URL) {
        switch phase {
        case .background: suspend()
        case .active where shouldResumeOnReturn: boot(kernelURL: kernelURL)
        default: break
        }
    }

    private func finish(with message: String) {
        machine = nil
        runFinished = nil
        status = .finished(message)
        _ = sink.append(Data("\n[\(message)]\n".utf8))
        consoleText = sink.takeText()
    }
}

/// Carries console bytes from the emulation thread to the main actor.
///
/// Two jobs, both about not letting a fast guest overwhelm a slow renderer:
/// it applies each chunk to the console once, incrementally, on the thread
/// that produced it; and it reports whether a refresh is already pending, so
/// the main actor is woken once per render rather than once per write.
private final class ConsoleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var console = TerminalGrid()
    private var refreshPending = false

    /// Buffers the chunk. Returns true only for the write that should schedule
    /// a refresh — every write until that refresh happens returns false.
    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        console.append(data)
        if refreshPending { return false }
        refreshPending = true
        return true
    }

    func takeText() -> String {
        lock.lock()
        defer { lock.unlock() }
        refreshPending = false
        return console.text
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        console.removeAll()
        refreshPending = false
    }
}

/// Why an imported file was refused.
public enum KernelImportError: Error, LocalizedError {
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let explanation): return explanation
        }
    }
}

/// Where imported kernel images live, and what is in there.
public enum KernelLibrary {
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Wisq/kernels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public static func list() -> [URL] {
        guard let directory = try? directory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies a picked file into the library, keeping its name.
    ///
    /// Refuses before copying. The picker accepts any file — deliberately, a
    /// kernel arrives with whatever name its author gave it — so the only
    /// thing that can decide is the file itself. Copying a two-gigabyte image
    /// into the app's storage in order to discover on boot that it cannot fit
    /// in a sixty-four megabyte machine costs the disk and teaches nothing.
    public static func importKernel(from source: URL) throws -> URL {
        let destination = try directory().appendingPathComponent(source.lastPathComponent)
        _ = source.startAccessingSecurityScopedResource()
        defer { source.stopAccessingSecurityScopedResource() }
        // Ce que le fichier est passe avant ce qu'il pèse, ici aussi : un ISO
        // de six gigaoctets est refusé pour la bonne raison, pas pour sa
        // taille — sinon quelqu'un croit qu'un plus petit passerait.
        // **Un initramfs est gardé, pas refusé.** Il arrive compressé — celui
        // d'Alpine commence par `1f 8b` —, et `cannotRunHereExplanation` y
        // voyait donc « probablement un noyau compressé », avec le conseil de
        // prendre plutôt la version non compressée. Pour ce fichier-là il n'y
        // en a pas : c'est l'initramfs qui est demandé, et sans lui un noyau
        // de PC démarre entièrement puis panique faute de racine à monter.
        //
        // Rien n'est perdu à l'accepter : un noyau **vraiment** compressé ne
        // pouvait de toute façon pas démarrer ici, donc le garder comme média
        // de démarrage ne prend la place d'aucun usage qui marchait.
        if let refusal = KernelImageKind.cannotRunHereExplanation(
            KernelImageKind.identify(fileAt: source),
            name: source.lastPathComponent),
            BootMedia.refusal(forFileAt: source) != nil {
            throw KernelImportError.tooLarge(refusal)
        }
        if let size = try? FileManager.default.attributesOfItem(
            atPath: source.path)[.size] as? Int,
            size > KernelMemory.maximumImportableImageBytes() {
            // Jugé sur la plus grande machine que cet appareil autorise, pas
            // sur le réglage : au moment de l'import il n'y en a pas encore.
            throw KernelImportError.tooLarge(
                LinuxMachine.tooLargeExplanation(
                    size: size, name: source.lastPathComponent,
                    ramSize: KernelMemory.ceiling))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// What the local Linux feature occupies, kernel by kernel.
    ///
    /// The two directories are this type's business, not the view's: a screen
    /// that had to know where saved machines live would be a second place to
    /// get that wrong.
    public static func storageReport() -> LocalStorage.Report {
        guard let kernels = try? directory(),
              let machines = try? SuspendedMachine.directory()
        else { return .empty }
        return LocalStorage.report(kernels: kernels, machines: machines)
    }

    /// Takes back the space held by machines saved from kernels that are no
    /// longer here, and answers with how much that was.
    @discardableResult
    public static func freeOrphanedMachines() -> Int {
        guard let kernels = try? directory(),
              let machines = try? SuspendedMachine.directory()
        else { return 0 }
        return LocalStorage.freeOrphanedMachines(kernels: kernels, machines: machines)
    }

    /// Removes a kernel, and everything the app remembered about it.
    ///
    /// Three things, not one: the file, the memory it was set to run with, and
    /// any machine saved from it. Leaving the last two behind would mean a
    /// kernel re-imported under the same name silently inherits a setting its
    /// owner deleted, and a snapshot file nothing will ever read again.
    public static func delete(_ url: URL) {
        let name = url.lastPathComponent
        try? FileManager.default.removeItem(at: url)
        KernelMemory.forget(kernel: name)
        SuspendedMachine.clearAll(named: name)
    }
}
#endif
