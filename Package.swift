// swift-tools-version:5.9
// Test harness for the pure-logic part of Caffeine Plus (the app itself builds with Xcode).
import PackageDescription

let package = Package(
    name: "CaffeinePlusCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CaffeinePlusCore", path: "src/Caffeine/Classes/Core"),
        .testTarget(name: "CaffeinePlusCoreTests", dependencies: ["CaffeinePlusCore"], path: "Tests/CaffeinePlusCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
