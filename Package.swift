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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.11.2"),
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
            dependencies: [
                "RemoraCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
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
            dependencies: [
                "RemoraCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "RemoraCoreTests",
            dependencies: ["RemoraCore"]
        ),
        .testTarget(
            name: "RemoraAppTests",
            dependencies: ["RemoraApp"]
        ),
    ]
)
