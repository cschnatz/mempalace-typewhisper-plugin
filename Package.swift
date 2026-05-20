// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemPalacePlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemPalacePlugin", targets: ["MemPalacePlugin"]),
    ],
    dependencies: [
        .package(path: "vendor/typewhisper-mac/TypeWhisperPluginSDK"),
    ],
    targets: [
        .target(
            name: "MemPalacePlugin",
            dependencies: [
                .product(name: "TypeWhisperPluginSDK", package: "TypeWhisperPluginSDK"),
            ],
            path: "Sources/MemPalacePlugin",
            resources: [
                .process("manifest.json"),
            ]
        ),
        .testTarget(
            name: "MemPalacePluginTests",
            dependencies: [
                "MemPalacePlugin",
                .product(name: "TypeWhisperPluginSDK", package: "TypeWhisperPluginSDK"),
                .product(name: "TypeWhisperPluginSDKTesting", package: "TypeWhisperPluginSDK"),
            ],
            path: "Tests/MemPalacePluginTests"
        ),
    ]
)
