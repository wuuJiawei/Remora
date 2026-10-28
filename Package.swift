// swift-tools-version: 6.0
import PackageDescription
import Foundation

private struct NativeSourceManifest: Decodable {
    let libssh2: [String]
    let mbedcrypto: [String]
}

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let nativeSourceManifestURL = packageRoot
    .appendingPathComponent("Vendor/NativeSSH/SOURCES.json")
private let nativeSourceManifest = try! JSONDecoder().decode(
    NativeSourceManifest.self,
    from: Data(contentsOf: nativeSourceManifestURL)
)

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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "7691f85b222a67a66b58499e1b2647443cf0dda7"),
    ],
    targets: [
        .target(
            name: "RemoraMbedCrypto",
            path: "Vendor/NativeSSH/mbedtls",
            sources: nativeSourceManifest.mbedcrypto,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("library"),
                .headerSearchPath("3rdparty/everest/include"),
                .headerSearchPath("3rdparty/everest/include/everest"),
                .headerSearchPath("3rdparty/everest/include/everest/kremlib"),
            ]
        ),
        .target(
            name: "RemoraLibSSH2",
            dependencies: ["RemoraMbedCrypto"],
            path: "Vendor/NativeSSH/libssh2",
            sources: nativeSourceManifest.libssh2,
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("HAVE_CONFIG_H"),
                .define("LIBSSH2_MBEDTLS"),
            ]
        ),
        .target(
            name: "RemoraSSHNative",
            dependencies: ["RemoraLibSSH2"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "RemoraCore",
            dependencies: ["RemoraSSHNative"],
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
                .linkedFramework("WebKit"),
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
            dependencies: ["RemoraCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "RemoraAppTests",
            dependencies: ["RemoraApp"]
        ),
    ]
)
