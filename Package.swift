// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DirigoSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DirigoCore", targets: ["DirigoCore"]),
        .library(name: "DirigoLibrary", targets: ["DirigoLibrary"]),
        .library(name: "DirigoEngine", targets: ["DirigoEngine"]),
        .library(name: "DirigoHardware", targets: ["DirigoHardware"]),
        .executable(name: "dirigo-cli", targets: ["DirigoCLI"]),
        .executable(name: "DirigoApp", targets: ["DirigoApp"]),
    ],
    targets: [
        .target(
            name: "DirigoCore"
        ),
        .target(
            name: "DirigoLibrary",
            dependencies: ["DirigoCore"]
        ),
        .target(
            name: "DirigoEngine",
            dependencies: ["DirigoCore", "DirigoLibrary"]
        ),
        .target(
            name: "DirigoHardware",
            dependencies: ["DirigoCore", "DirigoLibrary"]
        ),
        .executableTarget(
            name: "DirigoCLI",
            dependencies: ["DirigoCore", "DirigoLibrary", "DirigoEngine", "DirigoHardware"]
        ),
        .executableTarget(
            name: "DirigoApp",
            dependencies: ["DirigoCore", "DirigoLibrary", "DirigoEngine", "DirigoHardware"]
        ),
        .testTarget(
            name: "DirigoSwiftTests",
            // DirigoApp is included so the canvas geometry and the wiring commit path can be tested.
            // They were previously reachable only through the GUI, which is how a coordinate-space
            // mistake in `PinHitTest` survived a green test suite and a successful build.
            dependencies: ["DirigoCore", "DirigoLibrary", "DirigoEngine", "DirigoHardware", "DirigoApp"]
        ),
    ]
)
