// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HiFiGuard",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "HiFiGuardCore",
            path: "Sources/HiFiGuardCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HiFiGuard",
            dependencies: ["HiFiGuardCore"],
            path: "Sources/HiFiGuard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Prints the live audio state and can set the default mic, so the guard can be
        // exercised against real hardware without clicking through System Settings.
        .executableTarget(
            name: "HiFiGuardProbe",
            dependencies: ["HiFiGuardCore"],
            path: "Sources/HiFiGuardProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Renders Resources/AppIcon.iconset from the same paths the menu-bar icon uses.
        .executableTarget(
            name: "HiFiGuardIcon",
            dependencies: ["HiFiGuardCore"],
            path: "Sources/HiFiGuardIcon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Plain executable rather than a testTarget: the Command Line Tools ship an
        // incomplete Testing.framework and no XCTest. Run with `swift run HiFiGuardTests`.
        .executableTarget(
            name: "HiFiGuardTests",
            dependencies: ["HiFiGuardCore"],
            path: "Sources/HiFiGuardTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
