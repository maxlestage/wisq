import CWisqVM
import Foundation
import WisqVM

/// **La machine PC native, en Rust**, derrière `GuestMachine` : la même carte
/// que `X86Machine` (deux 8259, le 8253, le 16550, l'horloge CMOS, l'i8042, le
/// pont PCI, les disques virtio, l'écran de Bochs et sa tablette), un cœur
/// x86-64 interprété en Rust (`crates/wisq-vm/src/pc`), atteint par l'ABI C
/// (`wisq_pc_*`, `include/wisq_vm.h`).
///
/// **La surface est celle que `LocalVMModel` emploie sur `X86Machine`** :
/// `GuestMachine`, l'écran (`display`, une `RustPCScreen` qui rend les mêmes
/// `frame()` et `revision`), le clavier (`ScreenKeyboard`), la tablette
/// (`touch`, `scroll`), la souris PS/2 (`mouse`), et le pas de l'horloge
/// murale quand l'invité dort (`pacesIdleToWallClock`).
///
/// **Derrière un réglage éteint par défaut** (`RustPCSetting`) : l'application
/// garde le cœur Swift. Ce qui manque encore pour basculer est dit dans
/// `RustPCSetting`.
///
/// `@unchecked Sendable` pour la raison de `X86Machine` : `runGuest` tient un
/// fil à lui, et `send`, `stop`, les frappes, les touchers et l'écran sont
/// sûrs de n'importe quel fil — le contrat de l'en-tête, fonction par
/// fonction.
public final class RustPCMachine: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case powerOff
        case reboot
        case stopped
        case faulted(String)
    }

    /// Ce qu'une machine refuse, nommé.
    public enum Refusal: Error, Equatable, LocalizedError {
        case alreadyStarted
        case displayAlreadyAttached
        case displayTooLarge(width: Int, height: Int)
        case diskTooSmall
        case commandLineNotUTF8
        case commandLineHasNUL
        case notAKernel
        case no64BitEntry
        case protocolTooOld
        case notEnoughMemory
        case truncatedKernel
        case notASnapshot
        case newerSnapshot
        case damagedSnapshot
        case snapshotOfOtherMemory
        case snapshotOfOtherScreen
        case unknown(Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "La machine est déjà démarrée : on la branche éteinte."
            case .displayAlreadyAttached: return "Cette machine a déjà un écran."
            case .displayTooLarge(let width, let height):
                return "Un écran de \(width) × \(height) ne tient pas dans les seize mébioctets de la carte."
            case .diskTooSmall: return "Le disque fait moins d'un secteur."
            case .commandLineNotUTF8: return "La ligne de commande n'est pas de l'UTF-8."
            case .commandLineHasNUL: return "La ligne de commande contient un octet nul."
            case .notAKernel: return "Ce fichier n'est pas un noyau Linux pour PC."
            case .no64BitEntry: return "Ce noyau n'a pas de point d'entrée 64 bits."
            case .protocolTooOld: return "Le protocole de démarrage de ce noyau est trop ancien (2.06 au moins)."
            case .notEnoughMemory: return "La mémoire de la machine ne suffit pas à ce noyau."
            case .truncatedKernel: return "Le noyau est plus court que son en-tête ne l'annonce."
            case .notASnapshot: return "Ce n'est pas un instantané de la machine PC en Rust."
            case .newerSnapshot: return "Cet instantané vient d'une version plus récente de wisq."
            case .damagedSnapshot: return "Cet instantané est abîmé ou tronqué."
            case .snapshotOfOtherMemory: return "Cet instantané vient d'une machine d'une autre taille de mémoire."
            case .snapshotOfOtherScreen: return "Cet instantané vient d'une machine d'un autre écran."
            case .unknown(let code): return "La machine PC en Rust a refusé (code \(code))."
            }
        }
    }

    /// Le plancher de la machine, celui de `X86Machine` : en dessous, la
    /// bibliothèque prend celui-ci.
    public static let minimumRAMSize = 128 << 20

    /// La mémoire de la machine, plancher compris.
    public let ramSize: Int

    /// **L'écran**, une fois branché : une vue neuve à chaque lecture, qui
    /// tient la machine en vie autant qu'elle — la machine, elle, ne la tient
    /// pas, et rien ne fait de cycle.
    public var display: RustPCScreen? {
        hasDisplay ? RustPCScreen(pc: pc, owner: self) : nil
    }
    private var hasDisplay = false

    /// Comme `X86Machine.pacesIdleToWallClock` : quand l'invité dort sur
    /// `hlt` et que son temps a pris de l'avance sur l'horloge murale, le fil
    /// d'émulation dort l'écart, par tranches d'un dixième de seconde au plus ;
    /// une frappe, un toucher ou un arrêt le réveillent. Éteint par défaut :
    /// les tests vont aussi vite que l'hôte. L'application l'allume.
    public var pacesIdleToWallClock = false

    private final class Sink {
        let onOutput: @Sendable (Data) -> Void
        init(_ onOutput: @escaping @Sendable (Data) -> Void) { self.onOutput = onOutput }
    }

    private let pc: OpaquePointer
    private let sink: Unmanaged<Sink>
    /// Réveille un fil d'émulation qui dort l'avance de l'invité.
    private let nudge = DispatchSemaphore(value: 0)
    /// **L'arrêt demandé, collant** — la règle de `X86Machine` : ce n'est pas
    /// l'état de l'invité, c'est celui qui possède la machine qui lui demande
    /// de rendre la main, et chaque course suivante la rend aussitôt.
    private let lock = NSLock()
    private var stopRequested = false

    /// Une machine de `ramSize` octets ; `nil` quand l'hôte ne peut pas
    /// donner la mémoire.
    public init?(ramSize: Int, onOutput: @escaping @Sendable (Data) -> Void) {
        let sink = Unmanaged.passRetained(Sink(onOutput))
        guard let pc = wisq_pc_new(
            UInt64(max(ramSize, 0)),
            { context, bytes, length in
                guard let context, let bytes, length > 0 else { return }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                sink.onOutput(Data(UnsafeBufferPointer(start: bytes, count: length)))
            },
            sink.toOpaque())
        else {
            sink.release()
            return nil
        }
        self.pc = pc
        self.sink = sink
        self.ramSize = max(ramSize, Self.minimumRAMSize)
    }

    deinit {
        wisq_pc_free(pc)
        sink.release()
    }

    // MARK: - Avant le démarrage

    /// Fige l'heure de l'horloge CMOS : deux courses du même noyau retirent
    /// alors les mêmes instructions (`X86Machine.frozenHostTime`).
    public func freezeHostTime(at date: Date) {
        _ = wisq_pc_set_time(pc, Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    /// La graine de `RDRAND` et `RDSEED`. L'application en donne une neuve :
    /// un bureau repris du même fichier sur deux téléphones ne doit pas tirer
    /// les mêmes nombres.
    public func seed(_ value: UInt64) {
        _ = wisq_pc_seed(pc, value)
    }

    /// **Donner un écran à la machine**, et sa tablette, avant `load`.
    public func attachDisplay(width: Int, height: Int) throws {
        guard let width32 = UInt32(exactly: width), let height32 = UInt32(exactly: height) else {
            throw Refusal.displayTooLarge(width: width, height: height)
        }
        switch wisq_pc_attach_display(pc, width32, height32) {
        case 0: hasDisplay = true
        case -2: throw Refusal.alreadyStarted
        case -3: throw Refusal.displayAlreadyAttached
        case -4: throw Refusal.displayTooLarge(width: width, height: height)
        case let code: throw Refusal.unknown(code)
        }
    }

    /// Le cœur Rust lit sa base octet pour octet : un qcow2, un VMDK, un VDI,
    /// un VHD dynamique, un VHDX ou une appliance n'en sont pas les octets.
    /// Leurs lecteurs sont côté Swift, sous `X86Machine`.
    private func refuseImageFormats(_ base: URL) throws {
        guard VirtualDiskImages.recognizes(fileAt: base) else { return }
        throw FileDiskStore.Failure.unreadableImage(
            "ce disque est dans un format d'image (qcow2, VMDK, VDI, VHD, VHDX ou OVA) que la "
                + "machine PC en Rust ne lit pas encore ; le cœur Swift le lit, ou il se convertit "
                + "avec `qemu-img convert -O raw`.")
    }

    private func attachFile(
        _ base: URL, writes: URL,
        _ attach: (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    ) throws {
        try refuseImageFormats(base)
        let code = base.withUnsafeFileSystemRepresentation { basePath in
            writes.withUnsafeFileSystemRepresentation { writesPath -> Int32 in
                guard let basePath, let writesPath else { return -1 }
                return attach(pc, basePath, writesPath)
            }
        }
        switch code {
        case 0: return
        case -2: throw FileDiskStore.Failure.cannotOpenBase
        case -3: throw FileDiskStore.Failure.notADisk
        case -5: throw FileDiskStore.Failure.overlayBelongsToAnotherDisk
        case -6: throw FileDiskStore.Failure.overlayIsTruncated
        case -7: throw Refusal.alreadyStarted
        default: throw FileDiskStore.Failure.cannotOpenOverlay
        }
    }

    // MARK: - Ce que la machine rend pendant qu'elle tourne

    /// Où en est la course, publié à chaque tranche : voir `liveProgress`.
    public var progress: GuestProgress? {
        var retired: UInt64 = 0
        var rip: UInt64 = 0
        guard wisq_pc_progress(pc, &retired, &rip) == 1 else { return nil }
        return GuestProgress(retired: retired, rip: rip)
    }

    /// **Faire tourner l'invité** jusqu'à ce qu'il s'arrête, qu'on le lui
    /// demande, ou que le budget (son temps, sommeil compris) s'épuise.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        // Une tranche de l'hôte : un million d'instructions de l'invité, trois
        // millisecondes de son temps. Entre deux, l'arrêt et le sommeil.
        let slice: UInt64 = 1_000_000
        let start = wisq_pc_guest_time(pc)
        let hertz = Double(max(wisq_pc_guest_hertz(pc), 1))
        let wallStart = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock()
            let stopped = stopRequested
            lock.unlock()
            if stopped { return .stopped }
            let done = wisq_pc_guest_time(pc) &- start
            guard done < instructionBudget else { return .stopped }
            switch wisq_pc_run(pc, min(slice, instructionBudget - done)) {
            case WISQ_PC_BUDGET: break
            case WISQ_PC_STOPPED: return .stopped
            case WISQ_PC_POWER_OFF: return .powerOff
            case WISQ_PC_REBOOT: return .reboot
            case WISQ_PC_FAULT: return .faulted(fault)
            case WISQ_PC_NOT_READY: return .faulted("rien à faire tourner : ni noyau chargé, ni machine reprise")
            case let code: return .faulted("la machine PC en Rust a rendu le code \(code)")
            }
            if pacesIdleToWallClock, wisq_pc_halted(pc) != 0 {
                let guest = Double(wisq_pc_guest_time(pc) &- start) / hertz
                let wall = Double(DispatchTime.now().uptimeNanoseconds &- wallStart) / 1e9
                let ahead = guest - wall
                if ahead > 0.001 {
                    while nudge.wait(timeout: .now()) == .success {}
                    _ = nudge.wait(timeout: .now() + min(ahead, 0.1))
                }
            }
        }
    }

    /// Le nom de la dernière faute.
    private var fault: String {
        let length = wisq_pc_fault(pc, nil, 0)
        guard length > 0 else { return "une faute sans nom" }
        var buffer = [CChar](repeating: 0, count: length + 1)
        _ = wisq_pc_fault(pc, &buffer, buffer.count)
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Ce que l'invité a retiré. Course arrêtée.
    public var retiredInstructions: UInt64 { wisq_pc_retired(pc) }

    /// Demande à une course de rendre la main. De n'importe quel fil.
    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        wisq_pc_stop(pc)
        nudge.signal()
    }

    /// Des octets tapés au port série. De n'importe quel fil.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            wisq_pc_send(pc, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        nudge.signal()
    }

    // MARK: - Le clavier, la tablette et la souris

    /// **Des événements du clavier en codes du jeu 1**, `E0` devant une
    /// touche étendue, `| 0x80` pour le relâchement.
    public static func setOneCodes(_ events: [X86Keystrokes.Event]) -> [UInt8] {
        events.flatMap { event -> [UInt8] in
            let code = event.down ? event.code.set1 & 0x7F : event.code.set1 | 0x80
            return event.code.extended ? [0xE0, code] : [code]
        }
    }

    /// Des frappes qui vont ensemble, admises toutes ou aucune. De n'importe
    /// quel fil.
    @discardableResult
    public func press(_ events: [X86Keystrokes.Event]) -> Bool {
        let codes = Self.setOneCodes(events)
        let taken = codes.withUnsafeBufferPointer { wisq_pc_keys(pc, $0.baseAddress, $0.count) } == 1
        if taken { nudge.signal() }
        return taken
    }

    /// **Un texte tapé au clavier PS/2**, caractère par caractère, chacun
    /// entier ou pas du tout, jusqu'au premier qui ne tient plus — la règle
    /// de `X86Machine.type`. De n'importe quel fil.
    public func type(_ text: Substring) -> X86TypingReport {
        var report = X86TypingReport()
        var index = text.startIndex
        while index < text.endIndex {
            let events = X86Keystrokes.character(text[index])
            if events.isEmpty {
                report.skipped += 1
            } else if press(events) {
                report.typed += 1
            } else {
                break
            }
            index = text.index(after: index)
        }
        report.untyped = text[index...]
        return report
    }

    /// Les frappes que l'invité n'a pas encore reçues.
    public var pendingKeystrokes: Int { Int(wisq_pc_keys_pending(pc)) }

    /// **Annuler la frappe en cours** : ce qui attend est jeté, et les
    /// touches que la file laissait enfoncées sont relâchées.
    public func abandonTyping() {
        wisq_pc_keys_abandon(pc)
        nudge.signal()
    }

    /// Un toucher, de 0 à 1 ; faux quand l'invité n'a pas pris la tablette.
    @discardableResult
    public func touch(x: Double, y: Double, buttons: UInt8) -> Bool {
        let taken = wisq_pc_touch(pc, x, y, buttons) == 1
        if taken { nudge.signal() }
        return taken
    }

    /// La molette, en crans positifs vers le haut ; faux sans tablette prise.
    @discardableResult
    public func scroll(notches: Int) -> Bool {
        guard notches != 0 else { return false }
        let taken = wisq_pc_scroll(pc, Int32(clamping: notches)) == 1
        if taken { nudge.signal() }
        return taken
    }

    /// Un mouvement de la souris PS/2, Y vers le bas ; boutons : 1 gauche,
    /// 2 droit, 4 milieu.
    public func mouse(dx: Int, dy: Int, buttons: UInt8) {
        wisq_pc_mouse(pc, Int32(clamping: dx), Int32(clamping: dy), buttons)
        nudge.signal()
    }

    // MARK: - Sauver et reprendre

    /// **L'instantané, au format de cette machine** (`WISQPC\r\n`, version
    /// 1) : la RAM, le processeur, le système, les puces de la machine. **Pas
    /// la carte des périphériques** : voir `wisq_pc_snapshot`. Vide quand rien
    /// n'est encore démarré.
    public func snapshot() -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard wisq_pc_snapshot(pc, &bytes, &length) == 0, let bytes else { return Data() }
        defer { wisq_pc_free_snapshot(bytes, length) }
        return Data(UnsafeBufferPointer(start: bytes, count: length))
    }

    /// Reprend un instantané ; refusé, rien n'a changé.
    public func restore(_ data: Data) throws {
        let code: Int32 = data.withUnsafeBytes { raw in
            wisq_pc_restore(pc, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        switch code {
        case 0: return
        case -2: throw Refusal.notASnapshot
        case -3: throw Refusal.newerSnapshot
        case -4: throw Refusal.damagedSnapshot
        case -5: throw Refusal.snapshotOfOtherMemory
        case -6: throw Refusal.snapshotOfOtherScreen
        case let code: throw Refusal.unknown(code)
        }
    }
}

// MARK: - La machine vue par l'application

extension RustPCMachine: GuestMachine {
    public var ramSizeBytes: Int { ramSize }

    public var liveProgress: GuestProgress? { progress }

    public func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws {
        // `withCString` couperait la ligne à son premier nul, sans rien dire.
        if let commandLine, commandLine.utf8.contains(0) { throw Refusal.commandLineHasNUL }
        let code: Int32 = kernelImage.withUnsafeBytes { kernel in
            let kernelBase = kernel.bindMemory(to: UInt8.self).baseAddress
            let load = { (line: UnsafePointer<CChar>?) -> Int32 in
                guard let initialRamdisk else {
                    return wisq_pc_load(self.pc, kernelBase, kernel.count, line, nil, 0)
                }
                return initialRamdisk.withUnsafeBytes { ramdisk in
                    wisq_pc_load(self.pc, kernelBase, kernel.count, line,
                                 ramdisk.bindMemory(to: UInt8.self).baseAddress, ramdisk.count)
                }
            }
            guard let commandLine else { return load(nil) }
            return commandLine.withCString { load($0) }
        }
        switch code {
        case 0: return
        case -2: throw Refusal.commandLineNotUTF8
        case -3: throw Refusal.notAKernel
        case -4: throw Refusal.no64BitEntry
        case -5: throw Refusal.protocolTooOld
        case -6: throw Refusal.notEnoughMemory
        case -7: throw Refusal.truncatedKernel
        case -8: throw Refusal.alreadyStarted
        case let code: throw Refusal.unknown(code)
        }
    }

    public func attachDisk(_ image: Data) throws {
        guard !image.isEmpty else { throw Refusal.diskTooSmall }
        let code: Int32 = image.withUnsafeBytes { raw in
            wisq_pc_attach_disk(pc, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        switch code {
        case 0: return
        case -2: throw Refusal.alreadyStarted
        case -3: throw Refusal.diskTooSmall
        case let code: throw Refusal.unknown(code)
        }
    }

    public func attachDisk(fileAt base: URL, writes: URL) throws {
        try attachFile(base, writes: writes) { wisq_pc_attach_disk_file($0, $1, $2) }
    }

    public func attachSecondDisk(fileAt base: URL, writes: URL) throws {
        try attachFile(base, writes: writes) { wisq_pc_attach_second_disk_file($0, $1, $2) }
    }

    public func flushDisk() { _ = wisq_pc_flush_disks(pc) }

    public var diskBytesWritten: Int { Int(clamping: wisq_pc_disk_bytes_written(pc)) }

    public var diskActivity: (served: UInt64, refused: UInt64)? {
        var served: UInt64 = 0
        var refused: UInt64 = 0
        guard wisq_pc_disk_activity(pc, &served, &refused) == 1 else { return nil }
        return (served, refused)
    }

    @discardableResult
    public func runGuest(instructionBudget: UInt64) -> GuestOutcome {
        switch run(instructionBudget: instructionBudget) {
        case .powerOff: return .powerOff
        case .reboot: return .reboot
        case .stopped: return .stopped
        case .faulted(let reason): return .faulted(reason)
        }
    }

    /// Le geste de `X86Machine.elapse(seconds:)` : borné, puis payé par pas
    /// de dix secondes pendant que l'invité dort.
    public func elapse(seconds: TimeInterval) {
        guard let seconds = GuestClock.catchUp(seconds) else { return }
        wisq_pc_elapse(pc, seconds)
    }
}

extension RustPCMachine: ScreenKeyboard {}

/// **L'écran de la machine PC en Rust**, tel qu'une vue le lit : la même
/// surface que `X86Framebuffer` (`revision`, `width`, `height`, `mode`,
/// `frame()`, `pixelData()`), lue à travers l'ABI. L'image est copiée sous le
/// verrou de la carte (`wisq_pc_display_copy`) : le mode, les pixels et la
/// révision vont ensemble.
public final class RustPCScreen: @unchecked Sendable {
    private let pc: OpaquePointer
    /// La machine vit au moins autant que son écran : l'écran garde la
    /// mémoire vidéo qu'il lit.
    private let owner: RustPCMachine

    init(pc: OpaquePointer, owner: RustPCMachine) {
        self.pc = pc
        self.owner = owner
    }

    private var current: WisqPCDisplay {
        var display = WisqPCDisplay()
        _ = wisq_pc_display(pc, &display)
        return display
    }

    /// Le mode montré.
    public var mode: X86Framebuffer.Mode {
        let display = current
        return X86Framebuffer.Mode(
            width: Int(display.width), height: Int(display.height),
            bytesPerRow: Int(display.bytes_per_row), start: Int(display.start))
    }

    public var width: Int { Int(current.width) }
    public var height: Int { Int(current.height) }
    /// La taille de la mémoire vidéo.
    public var memorySize: Int { current.memory_size }

    /// **Combien de fois l'image a changé** : égal, rien à repeindre.
    public var revision: UInt64 { current.revision }

    /// **Le mode et son image, pris ensemble**, sans remplissage.
    public func frame() -> (mode: X86Framebuffer.Mode, data: Data) {
        var display = WisqPCDisplay()
        _ = wisq_pc_display_copy(pc, nil, 0, &display)
        // Le mode peut changer entre la mesure et la copie : la copie le dit,
        // et l'on recommence à la taille qu'elle rend.
        for _ in 0..<4 {
            let count = Int(display.width) * Int(display.height) * 4
            var data = Data(count: count)
            let code = data.withUnsafeMutableBytes { raw in
                wisq_pc_display_copy(
                    pc, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &display)
            }
            if code == 0 {
                data.count = Int(display.width) * Int(display.height) * 4
                return (X86Framebuffer.Mode(
                    width: Int(display.width), height: Int(display.height),
                    bytesPerRow: Int(display.bytes_per_row), start: Int(display.start)), data)
            }
        }
        return (mode, Data())
    }

    public func pixelData() -> Data { frame().data }
}

/// **Le réglage qui fait tourner une machine PC sur le cœur Rust**, éteint
/// par défaut — à côté de celui de l'émetteur (`EmitterSetting`), sur le
/// modèle de celui-ci.
///
/// La clé est celle de `UserDefaults`, que la vue lit par `@AppStorage`. Le
/// verdict est ici, jugé sous Linux : le réglage allumé, un noyau de PC, **ni
/// session sauvée ni machine installée**. Une session sauvée est un
/// instantané du cœur Swift, que cette machine ne relit pas ; une machine
/// installée garde son disque et sa session. Les deux restent au cœur Swift.
///
/// **Et la machine du cœur Rust ne sauve rien** (`savesSessions`) : son
/// instantané ne porte pas encore la carte des périphériques, et une reprise
/// rendrait à l'invité des pilotes devant des files oubliées. Quitter
/// l'écran l'arrête ; la revoir la redémarre.
///
/// **Ce qui manque pour basculer** : l'instantané de la carte (`wisq-carte`
/// n'a ni sauvegarde ni reprise), puis les bureaux prêts refabriqués à son
/// format ; le réseau (la carte virtio-net de `wisq-carte` n'est pas branchée
/// par le poste) et le relais du port 5900 (`X86Machine.forward`) ; les
/// formats d'image de disque (qcow2, VMDK…), que seul le cœur Swift lit ; les
/// refus des programmes, que `X86Machine` dit dans la console.
public enum RustPCSetting {
    public static let key = "wisq.machine.pc-rust"
    /// Éteint : l'application ne bascule pas.
    public static let defaultValue = false
    /// La machine du cœur Rust ne sauve pas de session.
    public static let savesSessions = false

    /// Le cœur Rust prend-il cette machine ?
    public static func runs(
        _ core: GuestArchitecture.Core, enabled: Bool, hasSession: Bool, installed: Bool
    ) -> Bool {
        enabled && core == .x86_64 && !hasSession && !installed
    }
}
