// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lukotta",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Updates. MIT, with BSD-2 and zlib-licensed components bundled, so it
        // composes with distributing Lukotta under the GPL.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // All logic lives here, with no SwiftUI dependency, so it can be tested
        // without a running application.
        // Swift 5 language mode, matching how the app has always been compiled.
        // Swift 6 strict concurrency flags real issues in AppModel's detached
        // tasks; those are worth fixing deliberately, not as a side effect of a
        // structural refactor. Tracked in TODO section 12.
        .target(name: "LukottaCore", path: "sources/LukottaCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),

        // The interface. Deliberately thin.
        .executableTarget(name: "Lukotta",
                          dependencies: ["LukottaCore", .product(name: "Sparkle", package: "Sparkle")],
                          path: "sources/Lukotta",
                          swiftSettings: [.swiftLanguageMode(.v5)]),

        // Run with `swift run LukottaTests`. Not a .testTarget: XCTest and
        // swift-testing both require a full Xcode installation, and the tests
        // should run anywhere the app can be built.
        // Runs as root under launchd. Composes commands itself; it never
        // accepts one.
        .executableTarget(name: "LukottaHelper", dependencies: ["LukottaCore"],
                          path: "sources/LukottaHelper",
                          swiftSettings: [.swiftLanguageMode(.v5)]),

        .executableTarget(name: "LukottaTests", dependencies: ["LukottaCore"],
                          path: "sources/LukottaTests",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
