#if os(iOS)
import WisqVM
#if WISQ_RUST_CORE
import WisqVMRust
#endif

/// Which rv32ima interpreter the app actually runs.
///
/// There are two, and they are held to being interchangeable: the differential
/// test in `WisqVMRustTests` boots the same kernel through both and compares
/// them instruction count by instruction count and console byte by console
/// byte. That test is what makes a one-line switch defensible instead of
/// reckless — without it, swapping the engine under the app would be a change
/// nobody could check.
///
/// The Rust one is the faster of the two — about +8 % over a full boot — so it
/// is the default, and the one the app ships with. `WISQ_SWIFT_CORE=1` picks
/// the Swift one instead, for someone who has Swift and nothing else and only
/// wants to work on the protocol side; the manifest stops the build with the
/// command to run rather than quietly falling back, because which interpreter
/// ships must not depend on whether the build machine happened to have cargo.
///
/// Only the CPU changes. The console is `TerminalGrid` either way — the
/// terminal was never the part that needed rewriting.
#if WISQ_RUST_CORE
typealias LocalMachine = RustLinuxMachine
#else
typealias LocalMachine = LinuxMachine
#endif

/// How much memory the local machine gets, and therefore what size a kernel
/// image is judged against.
///
/// One place, because three call sites ask the same question: the boot path,
/// the import path, and the sentence that refuses a file. The core takes a
/// size per machine now — both cores do — so this is the one line a memory
/// setting has to move, rather than three that could disagree.
///
/// It used to be read off the type (`LinuxMachine.maximumKernelImageBytes`),
/// which only worked while every machine had the same memory. It no longer
/// does, and a bound that comes from a type instead of a machine is exactly
/// the drift this file exists to prevent.
public enum LocalMachineMemory {
    public static let size = LinuxMachine.defaultRAMSize

    /// The largest kernel image that machine can hold. Not a policy: the image
    /// is copied into guest RAM below the device tree, and anything larger has
    /// nowhere to go.
    public static var maximumKernelImageBytes: Int {
        LinuxMachine.maximumKernelImageBytes(forRAMSize: size)
    }
}
#endif
