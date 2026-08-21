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
        .target(name: "LukottaCore", path: "sources/LukottaCore"),

        // The interface. Deliberately thin.
        .executableTarget(name: "Lukotta",
                          dependencies: ["LukottaCore", .product(name: "Sparkle", package: "Sparkle")],
                          path: "sources/Lukotta"),

        // Runs as root under launchd. Composes commands itself; it never
        // accepts one.
        .executableTarget(name: "LukottaHelper", dependencies: ["LukottaCore"],
                          path: "sources/LukottaHelper"),

        // Run with `swift run LukottaTests`. Not a .testTarget: XCTest and
        // swift-testing both require a full Xcode installation, and the tests
        // should run anywhere the app can be built.
        .executableTarget(name: "LukottaTests", dependencies: ["LukottaCore"],
                          path: "sources/LukottaTests"),
    ]
)
