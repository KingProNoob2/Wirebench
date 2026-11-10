// swift-tools-version: 6.0
import PackageDescription

// The SwiftUI app only exists where SwiftUI does; every other target is portable (Linux builds them).
#if os(macOS)
let appProducts: [Product] = [.executable(name: "WirebenchApp", targets: ["WirebenchApp"])]
let appTargets: [Target] = [
    .executableTarget(
        name: "WirebenchApp",
        dependencies: ["WirebenchModel", "WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware"]
    ),
]
let appTestDependencies: [Target.Dependency] = ["WirebenchApp"]
#else
let appProducts: [Product] = []
let appTargets: [Target] = []
let appTestDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "Wirebench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WirebenchCore", targets: ["WirebenchCore"]),
        .library(name: "WirebenchLibrary", targets: ["WirebenchLibrary"]),
        .library(name: "WirebenchEngine", targets: ["WirebenchEngine"]),
        .library(name: "WirebenchHardware", targets: ["WirebenchHardware"]),
        .library(name: "WirebenchBridge", type: .dynamic, targets: ["WirebenchBridge"]),
        .executable(name: "wirebench-cli", targets: ["WirebenchCLI"]),
    ] + appProducts,
    targets: [
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
        // zlib, for the one place Apple's Compression framework is used; only linked where that framework is absent.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]
        ),
        .target(
            name: "WirebenchHardware",
            dependencies: ["WirebenchCore", "WirebenchLibrary", .target(name: "CZlib", condition: .when(platforms: [.linux]))]
        ),
        // A C interface to the model, for the Qt frontend: JSON scene out, JSON commands in.
        .target(
            name: "WirebenchBridge",
            dependencies: ["WirebenchModel", "WirebenchCore", "WirebenchLibrary"],
            path: "Sources/WirebenchBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "WirebenchCLI",
            dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware", "WirebenchModel"]
        ),
        // The application's state and commands, with no view code: the SwiftUI app and any other frontend sit on it.
        .target(
            name: "WirebenchModel",
            dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware"]
        ),
        .testTarget(
            name: "WirebenchTests",
            // WirebenchApp is included so the canvas geometry and the wiring commit path can be tested.
            // They were previously reachable only through the GUI, which is how a coordinate-space
            // mistake in `PinHitTest` survived a green test suite and a successful build.
            dependencies: ["WirebenchCore", "WirebenchLibrary", "WirebenchEngine", "WirebenchHardware", "WirebenchModel"] + appTestDependencies
        ),
    ] + appTargets
)
