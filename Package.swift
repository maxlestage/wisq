// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Rust interpreter is the one the app runs. It is about 8 % faster than the
// Swift one over a full boot, and the differential test in WisqVMRustTests holds
// the two to identical retired-instruction counts and identical console bytes —
// which is what makes preferring one of them a measurement rather than a taste.
//
// The cost is a second toolchain: linking it means `cargo build --release -p
// wisq-vm` (or, on Apple, `scripts/build-xcframework.sh`) must have run first.
// `WISQ_SWIFT_CORE=1` opts back out, for someone who has Swift and nothing else
// and only wants to work on the protocol side.
let rustCoreEnabled = ProcessInfo.processInfo.environment["WISQ_SWIFT_CORE"] == nil

// Where `cargo build --release` leaves libwisq_vm.a. Absolute, derived from this
// file, because the linker's working directory is not the package root during a
// test run and a relative -L silently finds nothing.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLibraryDirectory = ProcessInfo.processInfo.environment["WISQ_RUST_LIB_DIR"]
    ?? "\(packageRoot)/target/release"

#if os(macOS) || os(iOS)
// Rust's staticlib pulls in libSystem's unwinder and the objc runtime shims.
let rustSystemLibraries: [LinkerSetting] = []
#else
// On Linux the staticlib needs the pthread/dl/m symbols the Rust runtime uses;
// Swift's driver does not add them for a C library it knows nothing about.
let rustSystemLibraries: [LinkerSetting] = [
    .linkedLibrary("pthread"),
    .linkedLibrary("dl"),
    .linkedLibrary("m"),
]
#endif

// How the library reaches the linker depends on what it is being linked into.
//
// A bare `.a` carries no platform, so linking the iOS slice into a simulator
// build fails late and confusingly. On Apple the library therefore arrives as
// an XCFramework — `scripts/build-xcframework.sh` builds it — and Xcode picks
// the slice. Everywhere else, and on a Mac before that script has been run, it
// is the plain archive through a `-L`.
//
// The manifest decides by looking, rather than by asking for a second flag:
// build the XCFramework and it is used; don't and the archive is. Both vend a
// module named CWisqVM, so the Swift wrapper is the same source either way.
let xcframeworkPath = "dist/CWisqVM.xcframework"
let haveXCFramework = FileManager.default.fileExists(
    atPath: "\(packageRoot)/\(xcframeworkPath)"
)

let haveArchive = FileManager.default.fileExists(
    atPath: "\(rustLibraryDirectory)/libwisq_vm.a"
)

// Now that the Rust core is the default, a missing library has to stop the
// build and say so.
//
// The tempting alternative — fall back to the Swift core when the archive is
// absent — is the one thing that must not happen: it would make which
// interpreter ships depend on whether the machine doing the building happened
// to have run cargo, and a release cut on a machine without it would quietly
// carry the slower core with nothing to show for the difference. A build that
// stops with the command to run is worth more than one that silently gives you
// something else.
//
// Written to stderr and exited rather than raised with fatalError: a manifest
// that traps buries the one useful sentence under a Swift backtrace, and the
// point of stopping here is to be read.
if rustCoreEnabled && !haveXCFramework && !haveArchive {
    FileHandle.standardError.write(Data("""

        wisq : le cœur Rust est le défaut, et sa bibliothèque est absente.

        Construisez-la :
            cargo build --release -p wisq-vm
            scripts/build-xcframework.sh      # en plus, sur macOS, pour l'app

        Ou revenez au cœur Swift — plus lent, mais sans cargo :
            WISQ_SWIFT_CORE=1 swift build


        """.utf8))
    exit(1)
}

let rustLibraryTarget: Target = haveXCFramework
    ? .binaryTarget(name: "CWisqVM", path: xcframeworkPath)
    // The crate's own hand-written header, reached in place rather than copied.
    : .systemLibrary(name: "CWisqVM", path: "Sources/CWisqVM")

// A binary target brings its own library; only the loose archive needs pointing at.
let rustLinkerSettings: [LinkerSetting] = haveXCFramework ? [] : [
    .unsafeFlags(["-L\(rustLibraryDirectory)"]),
    .linkedLibrary("wisq_vm"),
] + rustSystemLibraries

let rustCoreTargets: [Target] = rustCoreEnabled ? [
    rustLibraryTarget,

    // Swift's view of the Rust interpreter: the same public surface as WisqVM's
    // LinuxMachine, so the app can be pointed at either.
    .target(
        name: "WisqVMRust",
        dependencies: ["CWisqVM", "WisqVM"],
        linkerSettings: rustLinkerSettings
    ),

    // Both cores, driven through the same script and compared.
    .testTarget(name: "WisqVMRustTests",
                dependencies: ["WisqVMRust", "WisqVM", "WisqVMTestKit"]),
] : []

let rustCoreProducts: [Product] = rustCoreEnabled
    ? [.library(name: "WisqVMRust", targets: ["WisqVMRust"])]
    : []

// The UI layer is UIKit/SwiftUI and only exists on Apple platforms. Dropping it on
// Linux lets the protocol work — which is where the bugs live — be built and tested
// on a runner that costs nothing, instead of waiting on a macOS one.
//
// The host agent is no longer here: it moved to Rust (crates/wisq-agent), because
// a daemon with no interface and no platform framework had no reason to carry a
// language runtime — statically linked it was a 58 MB download to serve four
// routes, and it is now 454 KB. What stays on this side is the client that talks
// to it, and a test that runs the real Rust binary against that client, so the
// two halves of the protocol cannot drift apart unnoticed.
#if os(iOS)
let agentProducts: [Product] = []
let agentTargets: [Target] = []
#else
let agentProducts: [Product] = []
let agentTargets: [Target] = [
    .executableTarget(name: "wisq-bench", dependencies: ["WisqVM"]),
    .testTarget(name: "WisqAgentTests", dependencies: ["WisqRemote", "WisqCore"]),
]
#endif

#if os(Linux)
let uiProducts: [Product] = []
let uiTargets: [Target] = []
#else
let uiProducts: [Product] = [.library(name: "WisqUI", targets: ["WisqUI"])]
// WisqVM stays a dependency even when the Rust core is in: only the CPU is
// swapped, and the console (TerminalGrid) was never the part worth rewriting.
let uiTargets: [Target] = [
    .target(
        name: "WisqUI",
        dependencies: ["WisqCore", "WisqRemote", "WisqVM"]
            + (rustCoreEnabled ? [Target.Dependency.target(name: "WisqVMRust")] : []),
        swiftSettings: rustCoreEnabled ? [.define("WISQ_RUST_CORE")] : []
    ),
]
#endif

let package = Package(
    name: "Wisq",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WisqCore", targets: ["WisqCore"]),
        .library(name: "WisqNet", targets: ["WisqNet"]),
        .library(name: "WisqRemote", targets: ["WisqRemote"]),
        .library(name: "WisqVM", targets: ["WisqVM"]),
    ] + uiProducts + agentProducts + rustCoreProducts,
    targets: [
        // Pure domain model. Foundation only, no platform frameworks.
        .target(name: "WisqCore"),

        // zlib, for the persistent inflate streams RFB's compressed encodings need.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),

        // Byte transport (TCP/TLS) built on Network.framework.
        .target(name: "WisqNet", dependencies: ["WisqCore", "CZlib"]),

        // Remote desktop protocols: RFB/VNC (implemented), SPICE and RDP (planned).
        .target(name: "WisqRemote", dependencies: ["WisqCore", "WisqNet"]),

        // Local Linux VMs: an interpreted rv32ima machine. Foundation only, so
        // the same core that ships on the phone boots real kernels in CI.
        .target(name: "WisqVM"),

        .testTarget(name: "WisqCoreTests", dependencies: ["WisqCore"]),
        .testTarget(name: "WisqNetTests", dependencies: ["WisqNet", "WisqCore"]),
        // Test scaffolding the two VM test targets share. Not a product, and
        // not built for the app: an assembler for hand-written rv32 programs
        // lives here because both the Swift core's tests and the differential
        // ones need it, and SwiftPM will not let one file belong to two test
        // targets.
        .target(name: "WisqVMTestKit", path: "Tests/WisqVMTestKit"),

        .testTarget(name: "WisqVMTests", dependencies: ["WisqVM", "WisqVMTestKit"]),
        .testTarget(name: "WisqRemoteTests", dependencies: ["WisqRemote", "WisqNet"]),
    ] + uiTargets + agentTargets + rustCoreTargets
)
