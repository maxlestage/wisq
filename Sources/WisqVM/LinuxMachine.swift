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
        self.ram = UnsafeMutableRawPointer.allocate(
            byteCount: Int(Self.ramSize), alignment: 8
        )
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: Int(Self.ramSize))
        self.core = RV32Core(ram: ram, ramSize: Self.ramSize, bus: self)
    }

    deinit {
        ram.deallocate()
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
        guard kernelImage.count > 0,
              UInt32(kernelImage.count) <= dtbPointer else {
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
    /// Blocking by design: the caller owns the thread (a Task in the app, the
    /// test runner in CI). The virtual clock advances with executed
    /// instructions rather than wall time, so a boot is deterministic on every
    /// machine that runs it.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        let slice = 1024
        var executed: UInt64 = 0
        var slicesSinceFlush = 0

        while executed < instructionBudget {
            lock.lock()
            let stopped = stopRequested
            lock.unlock()
            if stopped { flushOutput(); return .stopped }

            let result = core.step(elapsedMicroseconds: UInt32(slice / 16), count: slice)
            executed += UInt64(slice)

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
                // The hart sleeps until the timer fires; nudge virtual time
                // forward so it does.
                continue
            case .halted(let code):
                flushOutput()
                return code == 0x7777 ? .reboot : .powerOff
            }
        }
        flushOutput()
        return .stopped
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
