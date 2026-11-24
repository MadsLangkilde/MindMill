// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KB",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KB", targets: ["KB"]),
    ],
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(name: "KB", dependencies: [
            .product(name: "KBCore", package: "core"),
            .product(name: "KBEngine", package: "core"),
        ]),
        .testTarget(name: "KBAppTests", dependencies: ["KB", .product(name: "KBCore", package: "core"), .product(name: "KBEngine", package: "core")]),
    ],
    swiftLanguageModes: [.v5]
)
