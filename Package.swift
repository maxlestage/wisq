// swift-tools-version: 5.9
import PackageDescription

// The UI layer is UIKit/SwiftUI and only exists on Apple platforms. Dropping it on
// Linux lets the protocol work — which is where the bugs live — be built and tested
// on a runner that costs nothing, instead of waiting on a macOS one.
// The host agent runs where the VMs run — macOS and Linux, never iOS.
#if os(iOS)
let agentProducts: [Product] = []
let agentTargets: [Target] = []
#else
let agentProducts: [Product] = [.executable(name: "wisq-agent", targets: ["wisq-agent"])]
let agentTargets: [Target] = [
    .target(name: "WisqAgentKit", dependencies: ["WisqCore"]),
    .executableTarget(name: "wisq-agent", dependencies: ["WisqAgentKit", "WisqCore"]),
    .testTarget(name: "WisqAgentKitTests", dependencies: ["WisqAgentKit", "WisqRemote"]),
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
