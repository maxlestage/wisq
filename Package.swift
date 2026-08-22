// swift-tools-version: 5.9
import PackageDescription

// The UI layer is UIKit/SwiftUI and only exists on Apple platforms. Dropping it on
// Linux lets the protocol work — which is where the bugs live — be built and tested
// on a runner that costs nothing, instead of waiting on a macOS one.
#if os(Linux)
let uiProducts: [Product] = []
let uiTargets: [Target] = []
#else
let uiProducts: [Product] = [.library(name: "WisqUI", targets: ["WisqUI"])]
let uiTargets: [Target] = [.target(name: "WisqUI", dependencies: ["WisqCore", "WisqRemote"])]
#endif

let package = Package(
    name: "Wisq",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WisqCore", targets: ["WisqCore"]),
        .library(name: "WisqNet", targets: ["WisqNet"]),
        .library(name: "WisqRemote", targets: ["WisqRemote"]),
    ] + uiProducts,
    targets: [
        // Pure domain model. Foundation only, no platform frameworks.
        .target(name: "WisqCore"),

        // Byte transport (TCP/TLS) built on Network.framework.
        .target(name: "WisqNet", dependencies: ["WisqCore"]),

        // Remote desktop protocols: RFB/VNC (implemented), SPICE and RDP (planned).
        .target(name: "WisqRemote", dependencies: ["WisqCore", "WisqNet"]),

        .testTarget(name: "WisqCoreTests", dependencies: ["WisqCore"]),
        .testTarget(name: "WisqRemoteTests", dependencies: ["WisqRemote", "WisqNet"]),
    ] + uiTargets
)
