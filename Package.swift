// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemPalacePlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemPalacePlugin", targets: ["MemPalacePlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/TypeWhisper/typewhisper-mac.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MemPalacePlugin",
            dependencies: [
                .product(name: "TypeWhisperPluginSDK", package: "typewhisper-mac"),
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
                .product(name: "TypeWhisperPluginSDK", package: "typewhisper-mac"),
                .product(name: "TypeWhisperPluginSDKTesting", package: "typewhisper-mac"),
            ],
            path: "Tests/MemPalacePluginTests"
        ),
    ]
)
