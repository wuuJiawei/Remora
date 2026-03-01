// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Remora",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RemoraCore", targets: ["RemoraCore"]),
        .library(name: "RemoraTerminal", targets: ["RemoraTerminal"]),
        .executable(name: "RemoraApp", targets: ["RemoraApp"]),
        .executable(name: "terminal-stress", targets: ["TerminalStressTool"]),
    ],
    targets: [
        .target(
            name: "RemoraCore",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "RemoraTerminal",
            dependencies: ["RemoraCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "RemoraApp",
            dependencies: ["RemoraCore", "RemoraTerminal"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "TerminalStressTool",
            dependencies: ["RemoraCore", "RemoraTerminal"]
        ),
        .testTarget(
            name: "RemoraCoreTests",
            dependencies: ["RemoraCore"]
        ),
        .testTarget(
            name: "RemoraTerminalTests",
            dependencies: ["RemoraTerminal"]
        ),
        .testTarget(
            name: "RemoraAppTests",
            dependencies: ["RemoraApp"]
        ),
    ]
)
