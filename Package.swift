// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchBuddy",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchBuddyCore", targets: ["NotchBuddyCore"]),
        .executable(name: "notchbuddy-bridge", targets: ["notchbuddy-bridge"]),
        .executable(name: "NotchBuddy", targets: ["NotchBuddy"]),
    ],
    dependencies: [
        // Self-updates (EdDSA-signed appcast). Only the app links it; scripts/build-app.sh embeds the framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Resources: the localization tables (`Resources/<lang>.lproj/Localizable.strings`, see `L10n`).
        .target(name: "NotchBuddyCore", resources: [.process("Resources")]),
        .executableTarget(name: "notchbuddy-bridge", dependencies: ["NotchBuddyCore"]),
        .executableTarget(
            name: "NotchBuddy",
            dependencies: ["NotchBuddyCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework lives in NotchBuddy.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "NotchBuddyCoreTests", dependencies: ["NotchBuddyCore"]),
        .testTarget(name: "NotchBuddyIslandTests", dependencies: ["NotchBuddy"]),
    ],
    swiftLanguageModes: [.v5]
)
