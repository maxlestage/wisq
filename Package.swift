// swift-tools-version: 6.0
import PackageDescription

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
let uiTargets: [Target] = [.target(name: "WisqUI", dependencies: ["WisqCore", "WisqRemote", "WisqVM"])]
#endif

let package = Package(
    name: "Wisq",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WisqCore", targets: ["WisqCore"]),
        .library(name: "WisqNet", targets: ["WisqNet"]),
        .library(name: "WisqRemote", targets: ["WisqRemote"]),
        .library(name: "WisqVM", targets: ["WisqVM"]),
    ] + uiProducts + agentProducts,
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
        .testTarget(name: "WisqNetTests", dependencies: ["WisqNet"]),
        .testTarget(name: "WisqVMTests", dependencies: ["WisqVM"]),
        .testTarget(name: "WisqRemoteTests", dependencies: ["WisqRemote", "WisqNet"]),
    ] + uiTargets + agentTargets
)
