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
    targets: [
        // Resources: the localization tables (`Resources/<lang>.lproj/Localizable.strings`, see `L10n`).
        .target(name: "NotchBuddyCore", resources: [.process("Resources")]),
        .executableTarget(name: "notchbuddy-bridge", dependencies: ["NotchBuddyCore"]),
        .executableTarget(name: "NotchBuddy", dependencies: ["NotchBuddyCore"]),
        .testTarget(name: "NotchBuddyCoreTests", dependencies: ["NotchBuddyCore"]),
        .testTarget(name: "NotchBuddyIslandTests", dependencies: ["NotchBuddy"]),
    ],
    swiftLanguageModes: [.v5]
)
