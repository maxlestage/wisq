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

#endif
