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
/// The Rust one is the faster of the two (measured at about +8 % on a full
/// boot), so it is what ships when the package is built with WISQ_RUST_CORE.
/// The Swift one remains the default, because linking the other presumes a
/// `cargo build` and an XCFramework, and `swift build` has to keep working for
/// someone who has only Swift.
///
/// Only the CPU changes. The console is `TerminalGrid` either way — the
/// terminal was never the part that needed rewriting.
#if WISQ_RUST_CORE
typealias LocalMachine = RustLinuxMachine
#else
typealias LocalMachine = LinuxMachine
#endif
#endif
