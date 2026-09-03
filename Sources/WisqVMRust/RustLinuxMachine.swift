import CWisqVM
import Foundation

/// The same machine as `WisqVM.LinuxMachine` — 64 MB of RAM by default, one
/// rv32ima hart, an 8250 UART, a CLINT timer and a syscon — with the
/// interpreter in Rust.
///
/// The public surface is deliberately identical to the Swift core's, method for
/// method and case for case, so the app can be pointed at either one by changing
/// a name. That is not tidiness: it is what makes the differential test possible,
/// because a test can drive both through the same script and compare.
///
/// This type is `@unchecked Sendable` for the same reason the Swift core is: the
/// C ABI's threading contract is that `run` blocks on one thread at a time while
/// `send` and `stop` are safe from any thread, and that is exactly how the app
/// uses it.
public final class RustLinuxMachine: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case powerOff
        case reboot
        case stopped
    }

    /// The reference machine's memory — mini-rv32ima's 64 MB, the size every
    /// saved machine made before the setting existed was filed under.
    public static let defaultRAMSize: UInt32 = 64 * 1024 * 1024

    /// The same architectural limit the Swift core states, for the same
    /// reason: guest RAM starts at `0x8000_0000` and the hart addresses memory
    /// with thirty-two bits, so two gibibytes is the last byte it can own.
    public static let maximumRAMSize: UInt32 = 2 * 1024 * 1024 * 1024

    /// This machine's memory. Fixed for its lifetime: the crate allocates the
    /// buffer in `wisq_vm_new` and lays the guest's address space out from it,
    /// so a change means a new machine.
    public let ramSize: UInt32

    /// Keeps the output closure alive for the machine's lifetime and gives the C
    /// side a stable address to hand back. A closure cannot cross a
    /// `@convention(c)` boundary; a pointer to this can.
    private final class Sink {
        let onOutput: @Sendable (Data) -> Void
        init(_ onOutput: @escaping @Sendable (Data) -> Void) { self.onOutput = onOutput }
    }

    private let vm: OpaquePointer
    private let sink: Unmanaged<Sink>

    public init(
        ramSize: UInt32 = RustLinuxMachine.defaultRAMSize,
        onOutput: @escaping @Sendable (Data) -> Void
    ) {
        let sink = Unmanaged.passRetained(Sink(onOutput))
        self.sink = sink
        self.ramSize = ramSize
        guard let vm = wisq_vm_new(
            Int(ramSize),
            { context, bytes, length in
                guard let context, let bytes, length > 0 else { return }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                sink.onOutput(Data(UnsafeBufferPointer(start: bytes, count: length)))
            },
            sink.toOpaque()
        ) else {
            // The only way this returns null is a failed allocation, which is
            // the same condition the Swift core traps on when mmap fails.
            fatalError("RAM invitée : impossible d'allouer \(ramSize) octets")
        }
        self.vm = vm
    }

    deinit {
        wisq_vm_free(vm)
        sink.release()
    }

    // MARK: - Boot

    /// Loads a kernel image and prepares the hart the way the reference firmware
    /// would. Same layout, same registers, same command-line patching as the
    /// Swift core — the two agree on the machine before the first instruction.
    public func load(kernelImage: Data, commandLine: String? = nil) throws {
        let code: Int32 = kernelImage.withUnsafeBytes { bytes in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress
            if let commandLine {
                return commandLine.withCString { line in
                    wisq_vm_load(vm, base, bytes.count, line)
                }
            }
            return wisq_vm_load(vm, base, bytes.count, nil)
        }
        switch code {
        case WISQ_VM_LOAD_OK: return
        case WISQ_VM_LOAD_IMAGE_EMPTY, WISQ_VM_LOAD_IMAGE_TOO_LARGE:
            throw RustLinuxMachineError.imageTooLarge
        case WISQ_VM_LOAD_COMMAND_LINE_LONG, WISQ_VM_LOAD_COMMAND_LINE_UTF8:
            throw RustLinuxMachineError.commandLineTooLong
        case WISQ_VM_LOAD_RAM_UNSUPPORTED:
            throw RustLinuxMachineError.ramSizeUnsupported
        default:
            throw RustLinuxMachineError.loadFailed(code)
        }
    }

    // MARK: - Running

    /// Runs until shutdown, reboot, stop, or the instruction budget runs out.
    /// Blocks the calling thread; the caller owns a thread for it.
    @discardableResult
    public func run(instructionBudget: UInt64 = .max) -> Outcome {
        switch wisq_vm_run(vm, instructionBudget) {
        case WISQ_VM_POWER_OFF: return .powerOff
        case WISQ_VM_REBOOT: return .reboot
        default: return .stopped
        }
    }

    /// Instructions actually retired since boot.
    public var retiredInstructions: UInt64 {
        wisq_vm_retired_instructions(vm)
    }

    /// Asks a running `run()` to return. Safe from any thread.
    public func stop() {
        wisq_vm_stop(vm)
    }

    /// The whole machine as bytes, in the format the Swift core also writes.
    ///
    /// The buffer comes from Rust and goes straight back to it; copying it
    /// into `Data` before freeing is what keeps the ownership rule from
    /// leaking into every caller.
    public func snapshot() -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard wisq_vm_snapshot(vm, &bytes, &length) == WISQ_VM_SNAPSHOT_OK,
              let bytes else {
            fatalError("instantané impossible")
        }
        defer { wisq_vm_free_snapshot(bytes, length) }
        return Data(UnsafeBufferPointer(start: bytes, count: length))
    }

    /// Puts a saved machine back. On failure nothing has changed.
    public func restore(_ data: Data) throws {
        let code: Int32 = data.withUnsafeBytes { raw in
            wisq_vm_restore(vm, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        switch code {
        case WISQ_VM_SNAPSHOT_OK: return
        case WISQ_VM_SNAPSHOT_NOT_A_SNAPSHOT: throw RustLinuxMachineError.notASnapshot
        case WISQ_VM_SNAPSHOT_RAM_MISMATCH: throw RustLinuxMachineError.snapshotRamMismatch
        default: throw RustLinuxMachineError.snapshotCorrupt
        }
    }

    /// Feeds keyboard bytes to the guest's UART. Safe from any thread.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            wisq_vm_send(vm, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
    }
}

public enum RustLinuxMachineError: Error, Sendable, Equatable {
    case imageTooLarge
    case commandLineTooLong
    case notASnapshot
    case snapshotCorrupt
    case snapshotRamMismatch
    /// More memory than a thirty-two-bit hart can address. Same limit and same
    /// reason as `LinuxMachine.maximumRAMSize`, held by both cores.
    case ramSizeUnsupported
    /// A code the header defines but this wrapper does not name yet — reported
    /// rather than swallowed, so a new failure mode in the crate surfaces here
    /// as a readable error instead of a silent success.
    case loadFailed(Int32)
}
