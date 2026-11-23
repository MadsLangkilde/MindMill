// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KB",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KB", targets: ["KB"]),
    ],
    targets: [
        .target(name: "KBCore"),
        .executableTarget(name: "KB", dependencies: ["KBCore"]),
        .testTarget(name: "KBCoreTests", dependencies: ["KBCore"]),
    ],
    swiftLanguageModes: [.v5]
)
