// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChosConvertKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ChosConvertKit", targets: ["ChosConvertKit"]),
        .library(name: "ChosConvertUI", targets: ["ChosConvertUI"]),
    ],
    targets: [
        // Built by scripts/build-core-macos.sh from /core.
        .binaryTarget(name: "CChosConvertCore", path: "Frameworks/ChosConvertCore.xcframework"),
        .target(
            name: "ChosConvertKit",
            dependencies: ["CChosConvertCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ChosConvertUI",
            dependencies: ["ChosConvertKit"],
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "ChosConvertKitTests",
            dependencies: ["ChosConvertKit"]
        ),
        .testTarget(
            name: "ChosConvertUITests",
            dependencies: ["ChosConvertUI", "ChosConvertKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
