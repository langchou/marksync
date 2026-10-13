// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "marksync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkSyncCore", targets: ["MarkSyncCore"]),
        .executable(name: "marksync", targets: ["marksync"]),
        .executable(name: "marksync-tests", targets: ["marksync-tests"]),
    ],
    targets: [
        .target(
            name: "MarkSyncCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "marksync",
            dependencies: ["MarkSyncCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "marksync-tests",
            dependencies: ["MarkSyncCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
