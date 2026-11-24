import CWisqVM
import Foundation
import WisqVM

/// **La machine PC native, en Rust**, derrière `GuestMachine` : la même carte
/// que `X86Machine` (deux 8259, le 8253, le 16550, l'horloge CMOS, l'i8042, le
/// pont PCI, les disques virtio, l'écran de Bochs et sa tablette), un cœur
/// x86-64 interprété en Rust (`crates/wisq-vm/src/pc`), atteint par l'ABI C
/// (`wisq_pc_*`, `include/wisq_vm.h`) ; et la carte réseau virtio, branchée
/// sur le même `NetworkBackend` que le cœur Swift (`attachNetwork`).
///
/// **La surface est celle que `LocalVMModel` emploie sur `X86Machine`** :
/// `GuestMachine`, l'écran (`display`, une `RustPCScreen` qui rend les mêmes
/// `frame()` et `revision`), le clavier (`ScreenKeyboard`), la tablette
/// (`touch`, `scroll`), la souris PS/2 (`mouse`), et le pas de l'horloge
/// murale quand l'invité dort (`pacesIdleToWallClock`).
///
/// **Derrière un réglage allumé par défaut** (`RustPCSetting`) : une machine
/// PC neuve démarre ici, sur le cœur le plus rapide ; l'éteindre rend le cœur
/// Swift. Ce qui manque encore par rapport à lui est dit dans `RustPCSetting`.
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
        case networkAlreadyAttached
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
        case olderSnapshot
        case snapshotOfOtherDisks
        case unknown(Int32)

        public var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "La machine est déjà démarrée : on la branche éteinte."
            case .displayAlreadyAttached: return "Cette machine a déjà un écran."
            case .networkAlreadyAttached: return "Cette machine a déjà une carte réseau."
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
            case .olderSnapshot:
                return "Cet instantané vient d'une version de wisq dont la machine PC en Rust ne sauvait pas "
                    + "encore ses périphériques : il ne se reprend pas."
            case .snapshotOfOtherDisks:
                return "Cet instantané a été pris avec d'autres disques que ceux de cette machine : il se "
                    + "reprend sur les mêmes fichiers, aux mêmes places."
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
    /// **ne tient pas la machine** (voir `RustPCScreen`) — et la machine ne
    /// la tient pas non plus.
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
    /// alors les mêmes instructions (`X86Machine.frozenHostTime`). Le cœur la
    /// borne du 1er janvier 1970 au 31 décembre 9999 (`wisq_pc_set_time`) ;
    /// une date hors de `Int64` (ou un NaN) est d'abord bornée ici, où
    /// `Int64(_:)` planterait.
    public func freezeHostTime(at date: Date) {
        _ = wisq_pc_set_time(pc, Self.seconds(since1970: date.timeIntervalSince1970))
    }

    /// Les secondes entières d'une date, saturées à `Int64` (NaN : 1970).
    static func seconds(since1970 interval: TimeInterval) -> Int64 {
        guard !interval.isNaN else { return 0 }
        let down = interval.rounded(.down)
        // `Double(Int64.max)` vaut 2^63, déjà hors de `Int64` : la borne
        // haute est donc stricte.
        if down >= Double(Int64.max) { return .max }
        if down <= Double(Int64.min) { return .min }
        return Int64(down)
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

    // MARK: - Le réseau

    /// **L'autre bout du câble**, une fois la carte branchée : celui du cœur
    /// Swift (`UserNetwork`, `MachineNetwork.backend`), réutilisé tel quel.
    /// Posé avant le démarrage et plus jamais changé : la course le lit
    /// sans verrou.
    public private(set) var networkBackend: NetworkBackend?

    /// La plus grande trame qui passe (`WISQ_PC_FRAME_MAX`).
    static let largestFrame = Int(WISQ_PC_FRAME_MAX)

    /// **Brancher la carte réseau** (virtio, 00:05.0, ligne 3), avant `load`,
    /// sur `backend` : ce que l'invité émet lui est donné (`send`), ce qu'il
    /// rend (`receive`) est remis à l'invité — à chaque tranche de `run`,
    /// voir `pumpNetwork`. Sans carte, la machine n'a pas de réseau du tout.
    public func attachNetwork(_ backend: NetworkBackend, mac: [UInt8] = VirtioNet.defaultMAC) throws {
        guard mac.count == 6 else { throw Refusal.unknown(-1) }
        switch mac.withUnsafeBufferPointer({ wisq_pc_attach_network(pc, $0.baseAddress) }) {
        case 0: networkBackend = backend
        case -2: throw Refusal.alreadyStarted
        case -3: throw Refusal.networkAlreadyAttached
        case let code: throw Refusal.unknown(code)
        }
    }

    /// **Le réseau que le réglage de cette machine demande** — l'hôte, ou la
    /// passerelle qui ne mène nulle part si son réseau est coupé
    /// (`MachineNetwork`) : le même backend que `GuestMachineFactory.make`
    /// donne au cœur Swift.
    public func attachNetwork(forKernel kernel: String, in directory: URL? = nil) throws {
        try attachNetwork(MachineNetwork.backend(forKernel: kernel, in: directory))
    }

    /// **Relayer un port de l'hôte vers l'invité** — `X86Machine.forward`,
    /// le même code : le relais vit dans `UserNetwork` (`HostStreams.forward`),
    /// pas dans la carte. Rend le port qui écoute sur `127.0.0.1`, ou rien
    /// sans ce réseau.
    public func forward(hostPort: UInt16 = 0, toGuestPort guestPort: UInt16) throws -> UInt16? {
        guard let streams = (networkBackend as? UserNetwork)?.streams else { return nil }
        return try streams.forward(hostPort: hostPort, toGuestPort: guestPort)
    }

    /// **Faire passer les trames**, dans les deux sens : ce que l'invité a
    /// émis depuis la dernière fois, donné au backend dans son ordre ; puis
    /// ce que le backend a pour lui, remis à la machine. Une trame que la
    /// file pleine refuse est perdue, comme sur un réseau, et comptée par la
    /// machine (`networkCounts.refused`). Rend combien sont passées.
    ///
    /// `run` l'appelle avant chaque tranche ; de n'importe quel fil, c'est
    /// sûr aussi (les deux files sont « tout fil »).
    @discardableResult
    public func pumpNetwork() -> (sent: Int, given: Int) {
        guard let backend = networkBackend else { return (0, 0) }
        var sent = 0
        var buffer = [UInt8](repeating: 0, count: Self.largestFrame)
        while true {
            let length = buffer.withUnsafeMutableBufferPointer {
                wisq_pc_net_take(pc, $0.baseAddress, $0.count)
            }
            guard length > 0, length <= buffer.count else { break }
            backend.send(Array(buffer[0..<length]))
            sent += 1
        }
        var given = 0
        for frame in backend.receive() {
            let code = frame.withUnsafeBufferPointer { wisq_pc_net_give(pc, $0.baseAddress, $0.count) }
            if code == 1 { given += 1 }
        }
        return (sent, given)
    }

    /// Les compteurs du réseau, ou rien sans carte.
    public var networkCounts: WisqPCNetwork? {
        var counts = WisqPCNetwork()
        guard wisq_pc_net_stats(pc, &counts) == 1 else { return nil }
        return counts
    }

    /// **Un disque sur fichier**, en premier disque (`which` 0) ou en second
    /// (1). Une image brute, le cœur Rust la lit lui-même, octet pour octet.
    /// **Un qcow2, un VMDK, un VDI, un VHD, un VHDX ou une appliance OVA** :
    /// ses octets ne sont pas ceux du disque, et ce sont les lecteurs du cœur
    /// Swift qui les traduisent (`VirtualDiskImages`, ceux que
    /// `FileDiskStore` met sous sa couche) — tendus au cœur Rust par l'ABI
    /// (`wisq_pc_attach_disk_reader`), qui leur demande les secteurs que
    /// l'invité n'a pas écrits. **Un seul lecteur par format pour les deux
    /// cœurs** : la couche d'une machine, écrite sur l'un, repose sur les
    /// mêmes octets de base sous l'autre. Une image reconnue mais refusée
    /// (chiffrée, à fichier de base…) l'est sous la phrase de son format,
    /// comme `FileDiskStore` la dit.
    private func attachFile(
        _ base: URL, writes: URL, which: UInt32,
        _ attach: (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    ) throws {
        if VirtualDiskImages.recognizes(fileAt: base) {
            let image: (any VirtualDiskImage)?
            do {
                image = try VirtualDiskImages.disk(fileAt: base)
            } catch {
                throw FileDiskStore.Failure.unreadableImage(
                    (error as? LocalizedError)?.errorDescription ?? "image de disque illisible.")
            }
            guard let image else { throw FileDiskStore.Failure.cannotOpenBase }
            return try attachImage(image, writes: writes, which: which)
        }
        let code = base.withUnsafeFileSystemRepresentation { basePath in
            writes.withUnsafeFileSystemRepresentation { writesPath -> Int32 in
                guard let basePath, let writesPath else { return -1 }
                return attach(pc, basePath, writesPath)
            }
        }
        try Self.check(diskCode: code)
    }

    /// Le lecteur d'une image, tenu par la bibliothèque tant que le disque vit
    /// (`Unmanaged`, lâché par le rappel `release`).
    private final class ImageReader {
        let image: any VirtualDiskImage
        init(_ image: any VirtualDiskImage) { self.image = image }
    }

    /// **Brancher un disque lu par `image`.** Ce que `read` reçoit est copié
    /// dans le tampon de la bibliothèque ; un `false` du lecteur devient une
    /// erreur d'entrée-sortie pour l'invité. Le rappel est appelé du fil de
    /// `run`, le verrou de la carte tenu : il ne touche qu'au lecteur, jamais
    /// à la machine.
    func attachImage(_ image: any VirtualDiskImage, writes: URL, which: UInt32) throws {
        let reader = Unmanaged.passRetained(ImageReader(image)).toOpaque()
        let code = writes.withUnsafeFileSystemRepresentation { writesPath -> Int32 in
            // La bibliothèque lâche le lecteur à chaque refus, même ici.
            wisq_pc_attach_disk_reader(
                pc, which, image.virtualSize,
                { context, offset, buffer, length in
                    guard let context, let buffer else { return 0 }
                    let reader = Unmanaged<ImageReader>.fromOpaque(context).takeUnretainedValue()
                    var bytes = [UInt8](repeating: 0, count: length)
                    guard reader.image.read(into: &bytes, at: offset) else { return 0 }
                    bytes.withUnsafeBufferPointer { read in
                        guard let source = read.baseAddress else { return }
                        buffer.update(from: source, count: length)
                    }
                    return 1
                },
                { context in
                    guard let context else { return }
                    Unmanaged<ImageReader>.fromOpaque(context).release()
                },
                reader, writesPath)
        }
        try Self.check(diskCode: code)
    }

    /// Les codes de `wisq_pc_attach_disk_file` et `wisq_pc_attach_disk_reader`.
    static func check(diskCode code: Int32) throws {
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
        var slices: UInt64 = 0
        var samePage: UInt64 = 0
        guard wisq_pc_progress_pages(pc, &slices, &samePage) == 1 else {
            return GuestProgress(retired: retired, rip: rip)
        }
        return GuestProgress(retired: retired, rip: rip, slices: slices, slicesOnSamePage: samePage)
    }

    /// **Faire tourner l'invité** jusqu'à ce qu'il s'arrête, qu'on le lui
    /// demande, ou que le budget (son temps, sommeil compris) s'épuise.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        // Une tranche de l'hôte : un million d'instructions de l'invité, trois
        // millisecondes de son temps. Entre deux, l'arrêt, le sommeil, et les
        // trames : avec une carte réseau, deux cent mille, la tranche de
        // `X86Machine` — une trame attend au plus une tranche de chaque côté.
        let slice: UInt64 = networkBackend == nil ? 1_000_000 : 200_000
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
            pumpNetwork()
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

    /// La molette, en crans positifs vers le haut ; faux sans tablette prise,
    /// ou pour zéro cran — la carte le refuse elle-même (`Carte::defiler`).
    @discardableResult
    public func scroll(notches: Int) -> Bool {
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
    /// 2, `RustPCSnapshot`) : la RAM, le processeur, le système, les puces de
    /// la machine, les entrées pas encore données à l'invité, et **la carte
    /// des périphériques entière** (l'i8042, l'horloge de la carte, le PCI,
    /// les disques et leurs files, l'écran et sa mémoire vidéo, la tablette) :
    /// voir `wisq_pc_snapshot`. Les octets d'un disque sur fichier n'y sont
    /// pas : `flushDisk()` d'abord, comme l'application le fait avant chaque
    /// instantané. Vide quand rien n'est encore démarré.
    public func snapshot() -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard wisq_pc_snapshot(pc, &bytes, &length) == 0, let bytes else { return Data() }
        defer { wisq_pc_free_snapshot(bytes, length) }
        return Data(UnsafeBufferPointer(start: bytes, count: length))
    }

    /// **L'instantané écrit dans un fichier, page par page**
    /// (`wisq_pc_snapshot_to_file`) : les mêmes octets que `snapshot()`, sans
    /// tampon de la taille de la RAM que l'invité a servie. C'est ce que
    /// l'application emploie pour sauver : une machine de 4 Gio tenait sinon
    /// plusieurs gibioctets de plus, et iOS la tuait.
    public func writeSnapshot(to url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return wisq_pc_snapshot_to_file(pc, path) == 0
        }
    }

    /// **Reprend un instantané** ; refusé, rien n'a changé. L'écran se
    /// branche avant (`attachDisplay`), et les disques sur fichier aussi, les
    /// mêmes aux mêmes places (`attachDisk(fileAt:writes:)`) : l'instantané
    /// les dit « ailleurs », et la reprise refuse d'autres disques.
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
        case -7: throw Refusal.olderSnapshot
        case -8: throw Refusal.snapshotOfOtherDisks
        case let code: throw Refusal.unknown(code)
        }
    }
}

/// **Ce qu'une reprise refusée dit de la session** : d'autres disques que
/// ceux de l'instantané, ce n'est pas une session abîmée — rebranchée sur ses
/// disques, elle se reprend, et la console le dit (`SavedSession.Unreadable`).
/// Les autres refus restent « abîmée » : `SavedSession.judge` a déjà lu
/// l'en-tête, et ce qui échoue plus loin est le fichier lui-même.
extension RustPCMachine.Refusal: SavedSession.RefusalOfResume {
    public var unreadableSession: SavedSession.Unreadable {
        self == .snapshotOfOtherDisks ? .otherDisks : .damaged
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
        try attachFile(base, writes: writes, which: 0) { wisq_pc_attach_disk_file($0, $1, $2) }
    }

    public func attachSecondDisk(fileAt base: URL, writes: URL) throws {
        try attachFile(base, writes: writes, which: 1) { wisq_pc_attach_second_disk_file($0, $1, $2) }
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
    /// **L'écran ne tient pas la machine en vie.** Il la tenait, et c'est ce
    /// qui refusait une session au retour dans l'application : la machine
    /// mise de côté, le modèle et la vue gardaient encore son écran, donc ses
    /// cinq gibioctets, et la reprise ne trouvait plus de mémoire libre (« 256
    /// Mo de libre »). Chaque lecture prend la machine le temps de lire ;
    /// partie, l'écran n'a plus d'image, et rien n'est lu dans une mémoire
    /// rendue.
    private weak var owner: RustPCMachine?

    init(pc: OpaquePointer, owner: RustPCMachine) {
        self.pc = pc
        self.owner = owner
    }

    /// La machine, tenue le temps d'une lecture ; `nil` une fois partie.
    private func reading<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard let owner else { return nil }
        return withExtendedLifetime(owner) { body(pc) }
    }

    private var current: WisqPCDisplay {
        var display = WisqPCDisplay()
        _ = reading { wisq_pc_display($0, &display) }
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
        let copied = reading { pc in
            Self.frame { pixels, display in
                wisq_pc_display_copy(
                    pc, pixels?.bindMemory(to: UInt8.self).baseAddress, pixels?.count ?? 0, &display)
            }
        }
        return copied.flatMap { $0 } ?? (mode, Data())
    }

    /// **La boucle de `frame()`**, la copie donnée (`wisq_pc_display_copy`,
    /// ou celle d'un test) : rien quand la copie échoue quatre fois.
    ///
    /// Le mode peut changer entre la mesure et la copie, puisque l'invité
    /// tourne pendant qu'on lit. Plus grand, la copie refuse le tampon et dit
    /// la taille qu'il faut : on recommence à celle-là. Plus petit, elle copie
    /// le nouveau mode dans le tampon de l'ancien : l'image est coupée à la
    /// taille du mode qu'elle rend, sinon la vue lirait des octets de trop
    /// sous un mode qui ne les a pas.
    static func frame(
        copying copy: (UnsafeMutableRawBufferPointer?, inout WisqPCDisplay) -> Int32
    ) -> (mode: X86Framebuffer.Mode, data: Data)? {
        var display = WisqPCDisplay()
        _ = copy(nil, &display)
        for _ in 0..<4 {
            var data = Data(count: Int(display.width) * Int(display.height) * 4)
            let code = data.withUnsafeMutableBytes { copy($0, &display) }
            if code == 0 {
                data.count = Int(display.width) * Int(display.height) * 4
                return (X86Framebuffer.Mode(
                    width: Int(display.width), height: Int(display.height),
                    bytesPerRow: Int(display.bytes_per_row), start: Int(display.start)), data)
            }
        }
        return nil
    }

    public func pixelData() -> Data { frame().data }
}

/// **Le réglage qui fait tourner une machine PC sur le cœur Rust**, allumé
/// par défaut : c'est le cœur le plus rapide. À côté de celui de l'émetteur
/// (`EmitterSetting`), qui reste éteint, sur le modèle de celui-ci.
///
/// La clé est celle de `UserDefaults`, que la vue lit par `@AppStorage`. Le
/// verdict est ici, jugé sous Linux (`runs`). **C'est le format d'une session
/// sauvée qui décide, pas le réglage** : une session de la machine PC en Rust
/// (`WISQPC\r\n`, `RustPCSnapshot`) se reprend sur le cœur Rust, réglage
/// éteint compris ; une session du cœur Swift, sur le cœur Swift, réglage
/// allumé compris. Sinon, toucher l'interrupteur rendrait une session
/// illisible. **Sans session** — une machine neuve, ou dont la session a été
/// jetée —, le réglage décide, **machine installée comprise** : son disque
/// est lu par les mêmes lecteurs et sa couche a le même format sur les deux
/// cœurs, et sa session, une fois sauvée par l'un, y revient. Une reprise
/// sur d'autres disques que ceux de l'instantané est refusée sans jeter la
/// session (`SavedSession.Unreadable.otherDisks`) : la console dit de
/// rebrancher le disque.
///
/// **Les disques, comme le cœur Swift** : une image brute lue sur place par
/// le cœur Rust, et les formats d'autres hyperviseurs (qcow2, VMDK, VDI,
/// VHD, VHDX, OVA) par les lecteurs du cœur Swift (`VirtualDiskImages`),
/// tendus au cœur Rust par l'ABI (`attachImage`) ; la couche d'écriture est
/// la même, au même format.
///
/// **La machine du cœur Rust sauve ses sessions** (`savesSessions`), comme
/// le cœur Swift : au départ de l'écran et toutes les cinq minutes
/// (`CheckpointedRun`), le disque scellé avant l'instantané (`flushDisk`). La
/// revoir la reprend, et le temps passé dehors se rattrape
/// (`GuestMachine.elapse(since:)`).
///
/// **Le réseau, comme le cœur Swift** : la carte virtio-net de `wisq-carte`,
/// branchée par `attachNetwork` sur le backend de `MachineNetwork` — la même
/// pile `UserNetwork` (DHCP, DNS, TCP vers l'hôte), et le même réglage qui
/// coupe le réseau d'une machine —, et le relais du port 5900
/// (`RustPCMachine.forward`, celui de `X86Machine`). Une session reprise
/// garde le sien : la carte se rebranche avant la reprise, et l'état de la
/// carte (ses files, ce que le pilote a négocié) vient de l'instantané ; les
/// trames en file n'y sont pas, comme chez le cœur Swift (`VirtioNet.save`).
///
/// **Les refus des programmes, comme le cœur Swift** : une instruction qu'un
/// programme demande et que ce processeur n'a pas lui vaut « Illegal
/// instruction », et la console le dit, une fois par forme, avec la phrase de
/// `X86Machine.refusalNote` (`Poste::dire_les_refus`).
///
/// **Les bureaux prêts à son format** : `wisq-fabrique --coeur rust` les
/// fabrique et les vérifie sur la machine de l'application
/// (`RustReadyDesktopBuild`), et l'application, ce réglage allumé, prend
/// l'entrée du cœur Rust dans l'index (`ReadyDesktop.parse`) ; reprise, la
/// machine prend l'aléa du téléphone (`reseed`). Un index qui n'a que le
/// bureau du cœur Swift le donne encore, et il se reprend sur le cœur Swift.
///
/// **Ce qui lui manque encore par rapport au cœur Swift** : une session prise
/// pendant une installation (l'image en `vda`, le disque en `vdb`) ne se
/// reprend pas une fois que `IsoBoot` démarre le disque installé — la console
/// dit quel geste remet les disques.
public enum RustPCSetting {
    public static let key = "wisq.machine.pc-rust"
    /// **Allumé** : le cœur Rust va deux fois plus vite que le cœur Swift
    /// (110 MIPS contre 62, Void Xfce jusqu'au bureau 2,8 fois plus tôt).
    public static let defaultValue = true
    /// La machine du cœur Rust sauve ses sessions.
    public static let savesSessions = true

    /// **Le réglage tel qu'il est** : sa valeur si quelqu'un l'a touché,
    /// `defaultValue` sinon. `UserDefaults.bool(forKey:)` rendrait faux pour
    /// un réglage jamais touché, et le défaut ne s'appliquerait à personne.
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// **Le cœur Rust prend-il cette machine ?** `session` est la session
    /// sauvée, décompressée, s'il y en a une : son format décide. Sans
    /// session — une machine neuve, ou dont la session a été jetée —, le
    /// réglage décide, machine installée comprise.
    public static func runs(_ core: GuestArchitecture.Core, enabled: Bool, session: Data?) -> Bool {
        guard core == .x86_64 else { return false }
        if let session { return RustPCSnapshot.recognizes(session) }
        return enabled
    }
}
