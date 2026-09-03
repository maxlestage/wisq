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

    public static let ramSize: UInt32 = 64 * 1024 * 1024
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
    public static var maximumKernelImageBytes: Int {
        Int(ramSize - UInt32(DefaultDTB.bytes.count) - stateReserve)
    }

    /// Why a file is refused, in the terms of the machine that refuses it.
    ///
    /// It lives here, with the two numbers it names, rather than in the view
    /// that shows it: the sentence is about this machine's memory, and a copy
    /// written next to a button would drift from `maximumKernelImageBytes` the
    /// first time that changes. It also makes the wording testable on every
    /// platform, where the app layer only runs in a simulator.
    ///
    /// It names both sizes because only the pair explains anything — a file is
    /// not "too big" in the abstract, it is bigger than the RAM of the machine
    /// meant to hold it — and it says where a real distribution belongs,
    /// because someone who arrives with one has learned the useful thing only
    /// when they know that.
    public static func tooLargeExplanation(size: Int, name: String) -> String {
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

    private let lock = NSLock()
    private var inputQueue = [UInt8]()
    private var stopRequested = false
    /// Delivered on the emulation thread. Batched: whatever the guest wrote
    /// during one timeslice arrives as one Data.
    private let onOutput: @Sendable (Data) -> Void
    private var pendingOutput = Data()

    public init(onOutput: @escaping @Sendable (Data) -> Void) {
        self.onOutput = onOutput
        self.ram = Self.allocateGuestRAM(Int(Self.ramSize))
        self.core = RV32Core(ram: ram, ramSize: Self.ramSize, bus: self)
    }

    deinit {
        munmap(ram, Int(Self.ramSize))
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
        var dtb = DefaultDTB.bytes
        if let commandLine {
            let bytes = Array(commandLine.utf8)
            guard bytes.count < DefaultDTB.commandLineCapacity else {
                throw LinuxMachineError.commandLineTooLong
            }
            for (index, byte) in bytes.enumerated() {
                dtb[DefaultDTB.commandLineOffset + index] = byte
            }
            dtb[DefaultDTB.commandLineOffset + bytes.count] = 0
        }

        let dtbPointer = Self.ramSize - UInt32(dtb.count) - Self.stateReserve
        // Compared in `Int`, deliberately. `UInt32(kernelImage.count)` traps on
        // anything from four gibibytes up — the guard against an image too
        // large was itself a crash for the largest images of all. Nothing
        // reaches this line with such a file any more, because the app refuses
        // it from its size on disk, but a guard that traps instead of refusing
        // is not a guard.
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
        writer.ram(UnsafeRawBufferPointer(start: ram, count: Int(Self.ramSize)))
        lock.lock()
        let queued = inputQueue
        let pending = Array(pendingOutput)
        lock.unlock()
        writer.blob(queued)
        writer.blob(pending)
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

        var scratch = [UInt8](repeating: 0, count: Int(Self.ramSize))
        try scratch.withUnsafeMutableBytes { try reader.ram($0) }
        let queued = try reader.blob()
        let pending = try reader.blob()
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
    case commandLineTooLong
}

extension LinuxMachine: RV32Bus {
    public func mmioLoad(_ address: UInt32) -> UInt32 {
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
