import Foundation

/// A complete virtual machine that boots Linux on the phone itself: 64 MB of
/// RAM, one rv32ima hart, an 8250 UART, a CLINT timer, and a syscon — the
/// minimal machine a nommu RISC-V kernel is happy to run on.
///
/// This is the local counterpart to the remote sessions: no host, no network,
/// a real kernel with a real shell, entirely inside the app. The console is a
/// byte stream both ways; the UI wraps it in a terminal view.
public final class LinuxMachine: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case powerOff
        case reboot
        case stopped
    }

    /// The reference machine's memory, and the default when nothing is asked.
    ///
    /// mini-rv32ima's `sixtyfourmb.dtb` describes exactly this, which is why
    /// it is the size every saved machine made before the setting existed was
    /// filed under.
    public static let defaultRAMSize: UInt32 = 64 * 1024 * 1024

    /// The largest machine this architecture can have, and it is not a policy.
    ///
    /// Guest RAM starts at `0x8000_0000` and the hart addresses memory with
    /// thirty-two bits, so the last byte a machine can own is `0xFFFF_FFFF`.
    /// Two gibibytes lands exactly there — `0x8000_0000 + 2 GiB == 2^32` — and
    /// one byte more has nowhere to live.
    ///
    /// Measured rather than reasoned, because the failure is silent: a machine
    /// built with three gibibytes **loaded without complaint**, handed the
    /// guest a device tree announcing 3 221 209 088 bytes, and then produced
    /// nothing at all — no banner, no console, no error. A kernel told about
    /// memory outside its own address space dies before it can say so.
    ///
    /// Two gibibytes itself boots all the way to its login prompt; it just
    /// takes about 120 million instructions instead of 46, because Linux
    /// spends the difference initialising the pages.
    public static let maximumRAMSize: UInt32 = 2 * 1024 * 1024 * 1024

    /// This machine's memory. Fixed for its lifetime: the buffer is mapped in
    /// `init` and the guest's whole address space is laid out from it, so a
    /// change means a new machine, which is what the app does when the setting
    /// moves.
    public let ramSize: UInt32
    /// Reserved space at the top of RAM, matching the reference layout: the DTB
    /// sits below it, and the kernel must not allocate over either.
    private static let stateReserve: UInt32 = 192

    /// The largest kernel image this machine can hold, in bytes.
    ///
    /// It is not a policy: the image is copied into guest RAM, below the DTB,
    /// which sits below the reserved state. Anything larger has nowhere to go.
    ///
    /// It is public because the app has to refuse an oversized file **before**
    /// reading it, and a second number written by hand would drift from this
    /// one. `LocalVMModel` asks the filesystem for a size and compares it here;
    /// `load` compares again on the bytes it actually got, since a file can
    /// change between the two.
    public var maximumKernelImageBytes: Int {
        Self.maximumKernelImageBytes(forRAMSize: ramSize)
    }

    /// The same bound for a machine that does not exist yet — what the import
    /// screen needs, since it judges a file before any machine is built.
    public static func maximumKernelImageBytes(forRAMSize ramSize: UInt32) -> Int {
        Int(ramSize) - treeBytes(forRAMSize: ramSize) - Int(stateReserve)
    }

    /// Ce que l'arbre occupe pour cette machine, avec la ligne de commande par
    /// défaut.
    ///
    /// **C'est une estimation, et elle n'a besoin que de l'être.** Une ligne de
    /// commande plus longue fait un arbre plus gros ; `load` recalcule alors la
    /// place réellement prise et refuse une image qui ne rentre pas. Ce
    /// nombre-ci sert à l'écran d'import, qui juge un fichier avant qu'aucune
    /// machine n'existe et donc avant qu'aucune ligne de commande n'ait été
    /// demandée.
    static func treeBytes(forRAMSize ramSize: UInt32) -> Int {
        RV32DeviceTree.tree(ramSize: Int(ramSize)).flatten().count
    }

    /// Why a file is refused, in the terms of the machine that refuses it.
    ///
    /// It lives here, with the number it names, rather than in the view that
    /// shows it: the sentence is about this machine's memory, and a copy
    /// written next to a button would drift from `ramSize` the first time that
    /// changes. It also makes the wording testable on every platform, where
    /// the app layer only runs in a simulator.
    ///
    /// It sets the file's size against the machine's, because a file is not
    /// "too big" in the abstract — it is bigger than the RAM meant to hold it —
    /// and it says where a real distribution belongs, because someone who
    /// arrives with one has learned the useful thing only when they know that.
    ///
    /// **One number for the machine, not two.** The first draft also quoted the
    /// share left for the kernel, and a sabotage refused to bite: that share is
    /// 1728 bytes short of the whole, so at one decimal both render `64.0 Mo`.
    /// The sentence read "n'a que 64.0 Mo de mémoire au total, dont 64.0 Mo
    /// pour le noyau" — a typo to a reader, and two facts no test could tell
    /// apart, since it found either number by looking for the other.
    public static func tooLargeExplanation(
        size: Int, name: String, ramSize: UInt32 = defaultRAMSize
    ) -> String {
        let mega = { (bytes: Int) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        // Un seul chiffre pour la machine, pas deux. La part réservée au
        // noyau ne diffère du total que de mille octets — le DTB et l'état —
        // donc les deux s'affichaient « 64.0 Mo » côte à côte, ce qui ne se
        // lit pas comme une contrainte mais comme une coquille. Le sabordage
        // l'a montré autrement : le test passait en trouvant l'un pour
        // l'autre.
        return """
            \(name) fait \(mega(size)) Mo. La machine émulée n'a que \
            \(mega(Int(ramSize))) Mo de mémoire en tout.

            wisq fait tourner ici un noyau Linux rv32ima « nommu » — quelques \
            mégaoctets. Une image de distribution ne peut pas y entrer, quelle \
            que soit la patience : ce n'est ni la même architecture, ni la même \
            échelle, et il n'y a pas de disque. Pour une vraie distribution, \
            faites-la tourner sur un hôte et connectez-vous dessus avec wisq.
            """
    }

    private let ram: UnsafeMutableRawPointer
    private var core: RV32Core!

    // MARK: - Le disque

    /// Le disque, quand il y en a un.
    ///
    /// **Cette machine n'en avait pas, et la feuille de route disait pourquoi
    /// : les noyaux rv32 « nommu » de cette famille n'ont aucun pilote bloc.**
    /// C'est vrai du noyau de référence, et c'était la mauvaise conclusion —
    /// un noyau compilé avec `CONFIG_VIRTIO_MMIO` et `CONFIG_VIRTIO_BLK` ne
    /// trouvait rien ici parce que la carte ne déclarait aucun périphérique et
    /// que le cœur n'avait qu'une source d'interruption. Les deux manques sont
    /// comblés ; celui-ci est le périphérique lui-même.
    public private(set) var disk: VirtioBlock?

    /// Brancher un disque. À faire **avant** `load` : c'est lui qui décide si
    /// l'arbre déclare le nœud, et un arbre déjà posé ne se réécrit pas.
    public func attach(disk image: [UInt8]) { disk = VirtioBlock(image: image) }

    /// Le même disque, lu depuis un fichier, avec sa couche d'écriture à
    /// côté — voir `FileDiskStore`. À faire avant `load`, pour la même
    /// raison.
    public func attach(diskFileAt base: URL, writes: URL) throws {
        disk = VirtioBlock(store: try FileDiskStore(base: base, writes: writes))
    }

    /// Le retirer, et baisser sa ligne avec lui. Une interruption qui reste
    /// levée sans personne pour la servir enferme l'invité dans son
    /// gestionnaire.
    public func detachDisk() {
        disk = nil
        core.mip &= ~RV32Core.externalBit
    }

    /// Porter à `mip` ce que les périphériques demandent.
    ///
    /// **Appelé entre deux tranches d'instructions**, comme le fait le
    /// contrôleur du PC : le périphérique sert ses requêtes au moment où le
    /// pilote sonne la file, et le cœur doit l'apprendre avant de reprendre.
    /// Un sondage vaut mieux qu'un rappel ici — il n'y a qu'une source, et
    /// elle est déjà interrogée une fois par tranche.
    /// La ligne externe est-elle levée ?
    ///
    /// Exposée plutôt que `core` : ce qu'on veut savoir est une question, pas
    /// un champ, et ouvrir l'interprète entier pour la poser donnerait à
    /// n'importe qui de quoi écrire `mip` à la main.
    var externalInterruptPending: Bool { core.mip & RV32Core.externalBit != 0 }

    func pollDevices() {
        if disk?.interrupting == true {
            core.mip |= RV32Core.externalBit
        } else {
            core.mip &= ~RV32Core.externalBit
        }
    }

    /// La mémoire de l'invité telle qu'un périphérique la voit.
    ///
    /// Les adresses des descripteurs sont celles que le pilote a écrites,
    /// c'est-à-dire des adresses physiques de l'invité : elles commencent à
    /// `0x8000_0000` sur cette machine. La conversion vit ici, une fois.
    final class RAMView: GuestMemory {
        let bytes: UnsafeMutableRawPointer
        let size: UInt32
        init(_ bytes: UnsafeMutableRawPointer, _ size: UInt32) {
            self.bytes = bytes
            self.size = size
        }

        /// Où cette adresse tombe dans le tampon, ou `nil` si elle en sort.
        ///
        /// Le périphérique lit des adresses que l'invité a écrites : une
        /// adresse folle est un pilote qui se trompe, pas une raison de sortir
        /// du tampon. Elle est refusée, et `VirtioBlock` traite le refus comme
        /// une requête qui échoue.
        private func offset(_ address: UInt64, _ width: Int) -> Int? {
            guard address >= UInt64(RV32Core.ramBase) else { return nil }
            let at = address - UInt64(RV32Core.ramBase)
            guard at &+ UInt64(width) <= UInt64(size) else { return nil }
            return Int(at)
        }

        func read(_ address: UInt64, _ width: Int) throws -> UInt64 {
            guard let at = offset(address, width) else { throw LinuxMachineError.imageTooLarge }
            var value: UInt64 = 0
            for byte in 0..<width {
                value |= UInt64(bytes.load(fromByteOffset: at + byte, as: UInt8.self))
                    << (8 * byte)
            }
            return value
        }

        func write(_ address: UInt64, _ width: Int, _ value: UInt64) throws {
            guard let at = offset(address, width) else { throw LinuxMachineError.imageTooLarge }
            for byte in 0..<width {
                bytes.storeBytes(of: UInt8(truncatingIfNeeded: value >> (8 * byte)),
                                 toByteOffset: at + byte, as: UInt8.self)
            }
        }
    }

    /// Construite une fois : elle ne porte qu'un pointeur et une taille, tous
    /// deux fixés pour la vie de la machine.
    lazy var guestMemory: RAMView = RAMView(ram, ramSize)

    private let lock = NSLock()
    private var inputQueue = [UInt8]()
    private var stopRequested = false
    /// Delivered on the emulation thread. Batched: whatever the guest wrote
    /// during one timeslice arrives as one Data.
    private let onOutput: @Sendable (Data) -> Void
    private var pendingOutput = Data()

    public init(ramSize: UInt32 = LinuxMachine.defaultRAMSize, onOutput: @escaping @Sendable (Data) -> Void) {
        self.onOutput = onOutput
        self.ramSize = ramSize
        self.ram = Self.allocateGuestRAM(Int(ramSize))
        self.core = RV32Core(ram: ram, ramSize: ramSize, bus: self)
    }

    deinit {
        munmap(ram, Int(ramSize))
    }

    /// 64 MB of guest RAM, mapped rather than allocated-and-cleared.
    ///
    /// `malloc` makes no promise about contents, so the buffer had to be
    /// memset — 64 MB of stores that also make every page resident before the
    /// guest has touched one. An anonymous mapping is zero-filled by
    /// definition, so the clear disappears and the pages fault in as the
    /// kernel actually uses them. On a phone that is both the tap-to-boot
    /// pause and the resident footprint the system judges the app on.
    private static func allocateGuestRAM(_ bytes: Int) -> UnsafeMutableRawPointer {
        let mapping = mmap(nil, bytes, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        guard let mapping, mapping != MAP_FAILED else {
            fatalError("RAM invitée : impossible de mapper \(bytes) octets")
        }
        return mapping
    }

    // MARK: - Boot

    /// Loads a kernel image and prepares the hart exactly the way the reference
    /// firmware would: image at the base of RAM, DTB near the top, a0 = hart id,
    /// a1 = DTB address, machine mode, PC at the image's first instruction.
    public func load(kernelImage: Data, commandLine: String? = nil) throws {
        // **L'arbre est construit, plus recopié.** Il dit la mémoire de cette
        // machine-ci et porte la ligne de commande demandée — deux choses qui
        // s'écrivaient à des décalages trouvés à la main dans un blob, la
        // seconde plafonnée à cinquante-quatre caractères par la place qu'elle
        // s'y trouvait avoir. Le blob de référence n'a pas disparu : il est
        // devenu le témoin contre lequel `DeviceTreeAgainstTheReferenceTests`
        // juge celui-ci.
        let dtb = RV32DeviceTree.tree(
            ramSize: Int(ramSize), commandLine: commandLine,
            disk: disk != nil).flatten()
        handedTreeBytes = dtb.count

        let dtbPointer = ramSize - UInt32(dtb.count) - Self.stateReserve
        // Compared in `Int`, deliberately. `UInt32(kernelImage.count)` traps on
        // anything from four gibibytes up — the guard against an image too
        // large was itself a crash for the largest images of all. Nothing
        // reaches this line with such a file any more, because the app refuses
        // it from its size on disk, but a guard that traps instead of refusing
        // is not a guard.
        // A machine larger than the address space cannot boot, and used to try
        // in silence. Refused here rather than in `init` because that would
        // mean a failable initialiser for a condition no caller can recover
        // from differently — and because this is where the guest is told what
        // it has.
        guard ramSize <= Self.maximumRAMSize else {
            throw LinuxMachineError.ramSizeUnsupported
        }
        guard !kernelImage.isEmpty, kernelImage.count <= Int(dtbPointer) else {
            throw LinuxMachineError.imageTooLarge
        }

        kernelImage.withUnsafeBytes { bytes in
            ram.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        dtb.withUnsafeBytes { bytes in
            (ram + Int(dtbPointer)).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }

        core.pc = RV32Core.ramBase
        core.regs[10] = 0                                   // a0: hart id
        core.regs[11] = dtbPointer &+ RV32Core.ramBase      // a1: DTB
        core.extraflags |= 3                                // machine mode
    }

    /// The device tree as the guest will actually read it: the bytes at the
    /// address `load` put in a1, from the guest's own memory.
    ///
    /// Internal, and only tests use it. A sabotage put `DefaultDTB.bytes` back
    /// verbatim in `load` — the whole resize undone — and every test that did
    /// not boot a real kernel still passed, because they all questioned
    /// the tree-building function and none questioned what `load` handed over.
    /// Answering that needs to look where the kernel looks.
    ///
    /// Empty when a1 points outside RAM, so a wild pointer fails a test
    /// instead of reading past the mapping.
    var deviceTreeHandedToTheGuest: [UInt8] {
        let offset = Int(core.regs[11] &- RV32Core.ramBase)
        let count = handedTreeBytes
        guard count > 0, offset >= 0, offset + count <= Int(ramSize) else { return [] }
        return Array(UnsafeRawBufferPointer(start: ram + offset, count: count))
    }

    /// Combien d'octets d'arbre le dernier `load` a posés. Zéro avant le
    /// premier : rien n'a été remis, et il n'y a rien à relire.
    private var handedTreeBytes = 0

    /// Où l'arbre a été posé, dans l'espace d'adressage de l'invité.
    ///
    /// **Ce que ça sert à mesurer, c'est l'alignement.** Le noyau reçoit cette
    /// adresse dans `a1` et son analyseur exige qu'elle tombe sur huit ; un
    /// arbre dont la taille ne tombe pas sur huit la décale, et le seul
    /// symptôme est une sortie parfaitement vide.
    var deviceTreeAddress: UInt32 { core.regs[11] }

    // MARK: - Running

    /// Runs until shutdown, reboot, stop, or the instruction budget runs out.
    ///
    /// The budget counts instructions the guest actually retired. Counting
    /// slices offered instead would let an idle guest spend the whole budget
    /// without executing anything.
    ///
    /// Blocking by design: the caller owns the thread (a Task in the app, the
    /// test runner in CI). The virtual clock advances with executed
    /// instructions rather than wall time, so a boot is deterministic on every
    /// machine that runs it.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        let slice = 1024
        let startCycles = retiredInstructions
        var slicesSinceFlush = 0

        while retiredInstructions &- startCycles < instructionBudget {
            lock.lock()
            let stopped = stopRequested
            lock.unlock()
            if stopped { flushOutput(); return .stopped }

            let result = core.step(elapsedMicroseconds: UInt32(slice / 16), count: slice)

            // Prompts end without a newline; without a periodic flush they
            // would sit in the batch buffer forever and the console would look
            // hung at exactly the moment it is waiting for the user.
            slicesSinceFlush += 1
            if slicesSinceFlush >= 32 {
                slicesSinceFlush = 0
                flushOutput()
            }

            switch result {
            case .ran:
                continue
            case .waiting:
                // The hart sleeps until the timer fires, and the timer is the
                // only thing that can wake it: a parked hart executes nothing,
                // so it cannot poll the UART either.
                //
                // With no timer armed, nothing ever will — and the budget
                // cannot end the wait, because it counts *retired*
                // instructions and a parked hart retires none. The loop would
                // spin at full speed for ever, on a phone, for a guest that
                // has stopped asking for anything. Measured before it was
                // written: a two-instruction guest that runs `wfi` retires one
                // instruction and then never returns.
                if core.timermatchl == 0, core.timermatchh == 0 {
                    flushOutput()
                    return .stopped
                }
                // Otherwise the wait is finite: the clock is jumped to the
                // moment already written in mtimecmp.
                continue
            case .halted(let code):
                flushOutput()
                return code == 0x7777 ? .reboot : .powerOff
            }
        }
        flushOutput()
        return .stopped
    }

    /// Instructions actually retired since boot.
    ///
    /// Not the same as the budget spent: a hart in WFI burns wall time without
    /// retiring anything, so a throughput figure computed from the budget
    /// flatters an idle guest and punishes one that stops idling. This is the
    /// honest denominator.
    public var retiredInstructions: UInt64 {
        (UInt64(core.cycleh) << 32) | UInt64(core.cyclel)
    }

    /// Asks a running `run()` to return. Safe from any thread.
    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    /// Feeds keyboard bytes to the guest's UART. Safe from any thread.
    public func send(_ data: Data) {
        lock.lock()
        inputQueue.append(contentsOf: data)
        lock.unlock()
    }

    // MARK: - Saving and restoring

    /// The whole machine as bytes: RAM, the hart, and whatever is queued for
    /// the UART.
    ///
    /// Not the console output — that has already gone to the callback and
    /// belongs to whoever draws the terminal, not to the machine. The bytes
    /// are the same ones the Rust core writes, so a machine saved by one
    /// interpreter opens in the other.
    public func snapshot() -> Data {
        var writer = Snapshot.Writer()
        for index in 0..<32 { writer.u32(core.regs[index]) }
        writer.u32(core.pc)
        writer.u32(core.mstatus)
        writer.u32(core.cyclel)
        writer.u32(core.cycleh)
        writer.u32(core.timerl)
        writer.u32(core.timerh)
        writer.u32(core.timermatchl)
        writer.u32(core.timermatchh)
        writer.u32(core.mscratch)
        writer.u32(core.mtvec)
        writer.u32(core.mie)
        writer.u32(core.mip)
        writer.u32(core.mepc)
        writer.u32(core.mtval)
        writer.u32(core.mcause)
        writer.u32(core.extraflags)
        writer.ram(UnsafeRawBufferPointer(start: ram, count: Int(ramSize)))
        lock.lock()
        let queued = inputQueue
        let pending = Array(pendingOutput)
        lock.unlock()
        writer.blob(queued)
        writer.blob(pending)
        // **Le disque en dernier, et seulement s'il y en a un.** Son absence
        // est ce qui distingue un instantané d'avant le disque, et la reprise
        // la lit comme « pas de disque » plutôt que comme un dégât — sinon les
        // machines déjà sauvées sur les téléphones seraient perdues. Même
        // disposition que la machine PC, pour la même raison.
        if let disk { disk.save(into: &writer) }
        return Data(writer.bytes)
    }

    /// Puts a saved machine back, replacing everything this one holds.
    ///
    /// On failure the machine is left as it was rather than half-written: RAM
    /// is read into a scratch buffer that only replaces the live one once the
    /// whole snapshot has been accepted. A guest holding half of yesterday's
    /// memory is worse than a refused restore.
    public func restore(_ data: Data) throws {
        var reader = try Snapshot.Reader(Array(data))
        var words = [UInt32](repeating: 0, count: Snapshot.coreWords)
        for index in 0..<Snapshot.coreWords { words[index] = try reader.u32() }

        var scratch = [UInt8](repeating: 0, count: Int(ramSize))
        try scratch.withUnsafeMutableBytes { try reader.ram($0) }
        let queued = try reader.blob()
        let pending = try reader.blob()
        // Le disque, s'il reste des octets. Construit à part et posé tout à la
        // fin : une lecture qui échoue ici laisse à la machine le disque
        // qu'elle avait, plutôt qu'un disque à moitié repris.
        var restoredDisk: VirtioBlock?
        if !reader.isAtEnd {
            restoredDisk = try VirtioBlock.restored(from: &reader, keeping: disk?.store)
        }
        try reader.finish()

        for index in 0..<32 { core.regs[index] = words[index] }
        core.pc = words[32]
        core.mstatus = words[33]
        core.cyclel = words[34]
        core.cycleh = words[35]
        core.timerl = words[36]
        core.timerh = words[37]
        core.timermatchl = words[38]
        core.timermatchh = words[39]
        core.mscratch = words[40]
        core.mtvec = words[41]
        core.mie = words[42]
        core.mip = words[43]
        disk = restoredDisk
        core.mepc = words[44]
        core.mtval = words[45]
        core.mcause = words[46]
        core.extraflags = words[47]

        scratch.withUnsafeBytes { ram.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        lock.lock()
        inputQueue = queued
        pendingOutput = Data(pending)
        // `stopRequested` is deliberately left alone. It is not part of the
        // guest's state — it is the owner asking this machine to come back —
        // and clearing it here threw away a stop that arrived while the
        // machine was resuming. That is not a corner: the app restores on a
        // background thread and can be told to stop from the main one before
        // the restore finishes, and the machine then ran forever with nothing
        // able to end it.
        lock.unlock()
    }

    // MARK: - Output batching

    private func flushOutput() {
        guard !pendingOutput.isEmpty else { return }
        let batch = pendingOutput
        pendingOutput = Data()
        onOutput(batch)
    }
}

public enum LinuxMachineError: Error, Sendable {
    case imageTooLarge
    // **`commandLineTooLong` a disparu**, et ce n'est pas un oubli : la ligne
    // de commande était écrite dans un trou de cinquante-quatre octets ménagé
    // par le blob de référence, et ce plafond n'existait qu'à cause de lui.
    // Elle est maintenant une propriété de l'arbre, qui grandit avec elle ;
    // il ne reste que le plafond de la mémoire, qui est `imageTooLarge`.
    /// More memory than a thirty-two-bit hart can address. See
    /// `LinuxMachine.maximumRAMSize`.
    case ramSizeUnsupported
}

extension LinuxMachine: RV32Bus {
    public func mmioLoad(_ address: UInt32) -> UInt32 {
        // La fenêtre du disque en premier : elle est contiguë et testée d'un
        // coup, là où le reste est une poignée d'adresses isolées.
        if let disk, VirtioBlock.riscv.contains(UInt64(address)) {
            let value = disk.read(UInt64(address) - VirtioBlock.riscv.base, 4)
            pollDevices()
            return UInt32(truncatingIfNeeded: value)
        }
        switch address {
        case 0x1000_0005:                        // UART LSR: TX empty | RX ready
            lock.lock()
            let hasByte = !inputQueue.isEmpty
            lock.unlock()
            return 0x60 | (hasByte ? 1 : 0)
        case 0x1000_0000:                        // UART RX
            lock.lock()
            let byte = inputQueue.isEmpty ? nil : inputQueue.removeFirst()
            lock.unlock()
            return byte.map(UInt32.init) ?? 0
        case 0x1100_BFFC:                        // CLINT mtime high
            return core.timerh
        case 0x1100_BFF8:                        // CLINT mtime low
            return core.timerl
        default:
            return 0
        }
    }

    public func mmioStore(_ address: UInt32, _ value: UInt32) -> UInt32? {
        if let disk, VirtioBlock.riscv.contains(UInt64(address)) {
            disk.write(UInt64(address) - VirtioBlock.riscv.base, 4,
                       UInt64(value), guestMemory)
            // **Le sondage est ici, juste après l'écriture.** C'est la
            // notification de file qui fait servir les requêtes, donc c'est le
            // seul instant où la ligne peut monter — et le pilote acquitte par
            // une écriture aussi, donc le seul où elle peut descendre.
            pollDevices()
            return nil
        }
        switch address {
        case 0x1000_0000:                        // UART TX
            pendingOutput.append(UInt8(truncatingIfNeeded: value))
            // Deliver on line breaks or when a burst accumulates, so the
            // console feels live without a callback per byte.
            if value == 0x0A || pendingOutput.count >= 256 {
                flushOutput()
            }
            return nil
        case 0x1100_4004:                        // CLINT mtimecmp high
            core.timermatchh = value
            return nil
        case 0x1100_4000:                        // CLINT mtimecmp low
            core.timermatchl = value
            return nil
        case 0x1110_0000:                        // syscon: poweroff / reboot
            return value
        default:
            return nil
        }
    }
}
