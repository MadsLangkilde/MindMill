// swift-tools-version:6.0
import PackageDescription

// The code Mindmill's apps share: KBCore (data, rules, parsing, protocol, state machines) and KBEngine (the engine
// work behind the UI: Claude sessions, voice, the companion hub). Plain Foundation only, so it builds for macOS and
// Windows; anything platform-specific sits behind `#if canImport` or an adapter protocol (see README.md).
let package = Package(
    name: "core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KBCore", targets: ["KBCore"]),
        .library(name: "KBEngine", targets: ["KBEngine"]),
    ],
    targets: [
        .target(name: "KBCore"),
        .target(name: "KBEngine", dependencies: ["KBCore"]),
        .testTarget(name: "KBCoreTests", dependencies: ["KBCore"]),
        .testTarget(name: "KBEngineTests", dependencies: ["KBEngine", "KBCore"]),
    ],
    swiftLanguageModes: [.v5]
)
