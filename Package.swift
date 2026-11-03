// swift-tools-version: 6.2

import PackageDescription

// Hooks are read only by tests; never use this condition for product behaviour.
// Release tests opt in on the command line. Shipped Release builds omit hooks.
let testHookSettings: [SwiftSetting] = [
    .define("BETTERTILE_TEST_HOOKS", .when(configuration: .debug)),
]

let package = Package(
    name: "BetterTile",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BetterTileCore", targets: ["BetterTileCore"]),
        .library(name: "BetterTileMacOS", targets: ["BetterTileMacOS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .target(name: "BetterTileCore"),
        .target(
            name: "BetterTileMacOS",
            dependencies: ["BetterTileCore"],
            swiftSettings: testHookSettings,
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ColorSync"),
            ]
        ),
        .executableTarget(
            name: "BetterTileApp",
            dependencies: [
                "BetterTileCore",
                "BetterTileMacOS",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Info.plist"],
            swiftSettings: testHookSettings
        ),
        // Test-only support. Only test targets may depend on it.
        .target(name: "BetterTileTestSupport", dependencies: ["BetterTileCore"], path: "Tests/BetterTileTestSupport"),
        .testTarget(name: "BetterTileCoreTests", dependencies: ["BetterTileCore", "BetterTileTestSupport"]),
        .testTarget(name: "BetterTileMacOSTests", dependencies: ["BetterTileMacOS", "BetterTileCore", "BetterTileTestSupport"],
                    resources: [.copy("Fixtures/ActionGlyphs")],
                    swiftSettings: testHookSettings),
        .testTarget(name: "BetterTileAppTests", dependencies: ["BetterTileApp", "BetterTileTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
