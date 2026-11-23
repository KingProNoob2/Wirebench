// swift-tools-version: 6.2
import Foundation
import PackageDescription

let platforms: [SupportedPlatform] = [.macOS(.v15)]

/// The agent is a build option, off unless asked for: `WIREBENCH_AI=1 swift build` (or `swift test`) defines
/// `WIREBENCH_AI`, and nothing of the agent is compiled without it.
let aiSettings: [SwiftSetting] = ProcessInfo.processInfo.environment["WIREBENCH_AI"] == "1"
    ? [.define("WIREBENCH_AI")] : []

// The SwiftUI app only exists where SwiftUI does; every other target is portable (Linux builds them).
#if os(macOS)
let appProducts: [Product] = [.executable(name: "WirebenchApp", targets: ["WirebenchApp"])]
let appTargets: [Target] = [
    .executableTarget(
        name: "WirebenchApp",
        dependencies: ["WirebenchModel", "WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware",
                       "WirebenchSource"],
        resources: [.process("SimulatorAssets")],
        swiftSettings: aiSettings
    ),
]
let appTestDependencies: [Target.Dependency] = ["WirebenchApp"]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
let appTestDependencies: [Target.Dependency] = []
#endif

// The targets are built as a few chunks rather than one literal: a single array with all of them no longer
// type-checks in reasonable time once the manifest has a package dependency as well.
let coreTargets: [Target] = [
    .target(
        name: "WirebenchCore"
    ),
    .target(
        name: "WirebenchLibrary",
        dependencies: ["WirebenchCore"]
    ),
    // The C++ simulation core. A target of its own because SwiftPM will not mix Swift and C++ in
    // one target, and a plain-C public header so importing it needs no interop mode.
    .target(
        name: "WirebenchSimCxx",
        path: "Sources/WirebenchSimCxx",
        publicHeadersPath: "include",
        cxxSettings: [.unsafeFlags(["-std=c++17", "-O2", "-pipe"])]
    ),
    .target(
        name: "WirebenchEngine",
        dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchSimCxx"]
    ),
    .target(
        name: "WirebenchMaraVMC",
        path: "Sources/WirebenchMaraVMC",
        publicHeadersPath: "include"
    ),
    .target(
        name: "WirebenchMaraVM",
        dependencies: ["WirebenchMaraVMC"]
    ),
    .target(
        name: "WirebenchDuinoSim",
        dependencies: ["WirebenchMaraVMC"],
        path: "Sources/WirebenchDuinoSim",
        publicHeadersPath: "include",
        cxxSettings: [.unsafeFlags(["-std=c++17", "-O2", "-pipe"]),
                      .headerSearchPath("../WirebenchMaraVMC/include")]
    ),
    // zlib, for the one place Apple's Compression framework is used; only linked where that framework is absent.
    .systemLibrary(
        name: "CZlib",
        path: "Sources/CZlib",
        providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
    ),
    .target(
        name: "WirebenchHardware",
        dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchDuinoSim", .target(name: "CZlib", condition: .when(platforms: [.linux]))]
    ),
]

let featureTargets: [Target] = [
    // A C interface to the model, for the Qt frontend: JSON scene out, JSON commands in.
    .target(
        name: "WirebenchBridge",
        dependencies: ["WirebenchModel", "WirebenchCore", "WirebenchLibrary"],
        path: "Sources/WirebenchBridge",
        publicHeadersPath: "include",
        swiftSettings: aiSettings
    ),
    // Structured Text: the source front end (its own lexer and parser) and its lowering to blocks.
    .target(
        name: "WirebenchSource",
        dependencies: ["WirebenchCore", "WirebenchLibrary"]
    ),
    .executableTarget(
        name: "WirebenchCLI",
        dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware", "WirebenchModel",
                       "WirebenchSource"]
    ),
    // The application's state and commands, with no view code: the SwiftUI app and any other frontend sit on it.
    .target(
        name: "WirebenchModel",
        dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware"],
        swiftSettings: aiSettings
    ),
    .testTarget(
        name: "WirebenchTests",
        // WirebenchApp is included so the canvas geometry and the wiring commit path can be tested.
        // They were previously reachable only through the GUI, which is how a coordinate-space
        // mistake in `PinHitTest` survived a green test suite and a successful build.
        dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware", "WirebenchModel",
                       "WirebenchSource", "WirebenchMaraVM"] + appTestDependencies,
        swiftSettings: aiSettings
    ),
]

let package = Package(
    name: "Wirebench",
    platforms: platforms,
    products: [
        .library(name: "WirebenchCore", targets: ["WirebenchCore"]),
        .library(name: "WirebenchLibrary", targets: ["WirebenchLibrary"]),
        .library(name: "WirebenchEngine", targets: ["WirebenchEngine"]),
        .library(name: "WirebenchHardware", targets: ["WirebenchHardware"]),
        .library(name: "WirebenchSource", targets: ["WirebenchSource"]),
        .library(name: "WirebenchBridge", type: .dynamic, targets: ["WirebenchBridge"]),
        .executable(name: "wirebench-cli", targets: ["WirebenchCLI"]),
    ] + appProducts,
    targets: coreTargets + featureTargets + appTargets
)
