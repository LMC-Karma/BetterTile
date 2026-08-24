// swift-tools-version: 6.2

import PackageDescription

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
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "BetterTileCoreTests", dependencies: ["BetterTileCore"]),
        .testTarget(name: "BetterTileMacOSTests", dependencies: ["BetterTileMacOS", "BetterTileCore"]),
    ],
    swiftLanguageModes: [.v6]
)
