// swift-tools-version: 6.2
import PackageDescription

// TischrundeCore is pure Swift (Foundation only) so the DSP pipeline can be
// built and tested on any platform. Everything that needs AVFoundation,
// Accelerate or SwiftUI is macOS-only and therefore declared conditionally.

var products: [Product] = [
    .library(name: "TischrundeCore", targets: ["TischrundeCore"]),
]

var targets: [Target] = [
    .target(
        name: "TischrundeCore",
        path: "Sources/TischrundeCore"
    ),
    .testTarget(
        name: "TischrundeCoreTests",
        dependencies: ["TischrundeCore"],
        path: "Tests/TischrundeCoreTests"
    ),
]

#if os(macOS)
products += [
    .executable(name: "Tischrunde", targets: ["Tischrunde"]),
    .executable(name: "tischrunde-cli", targets: ["tischrunde-cli"]),
]

targets += [
    .target(
        name: "TischrundeIO",
        dependencies: ["TischrundeCore"],
        path: "Sources/TischrundeIO"
    ),
    .executableTarget(
        name: "Tischrunde",
        dependencies: ["TischrundeCore", "TischrundeIO"],
        path: "Sources/Tischrunde",
        swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    .executableTarget(
        name: "tischrunde-cli",
        dependencies: ["TischrundeCore", "TischrundeIO"],
        path: "Sources/tischrunde-cli"
    ),
]
#endif

let package = Package(
    name: "Tischrunde",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets
)
