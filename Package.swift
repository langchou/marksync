// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "safaribm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SafariBookmarksCore", targets: ["SafariBookmarksCore"]),
        .executable(name: "safaribm", targets: ["safaribm"]),
        .executable(name: "safaribm-tests", targets: ["safaribm-tests"]),
    ],
    targets: [
        .target(
            name: "SafariBookmarksCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "safaribm",
            dependencies: ["SafariBookmarksCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "safaribm-tests",
            dependencies: ["SafariBookmarksCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
