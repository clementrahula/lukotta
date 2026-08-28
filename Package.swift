// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula
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
        //
        // The asset catalogue is excluded because SwiftPM would copy it rather
        // than compile it, and an uncompiled catalogue has no icons in it.
        // build-app.sh runs actool over it. Saying so here also silences the
        // warning it drew on every single build.
        .executableTarget(name: "Lukotta",
                          dependencies: ["LukottaCore", .product(name: "Sparkle", package: "Sparkle")],
                          path: "sources/Lukotta",
                          exclude: ["Assets.xcassets"]),

        // Runs as root under launchd. Composes commands itself; it never
        // accepts one.
        .executableTarget(name: "LukottaHelper", dependencies: ["LukottaCore"],
                          path: "sources/LukottaHelper"),

        // Beside the app rather than in front of it: plain C, and the only
        // thing able to notice a version of the app that never runs at all.
        // See its own file for why it is not what the bundle starts.
        .executableTarget(name: "LukottaLaunch", path: "sources/LukottaLaunch"),

        // The FSKit extension: a filesystem served from this process rather
        // than from the kernel, which is what lets a volume be local instead of
        // a network mount. macOS 15.4 is where FSKit arrives, and the app
        // supports 15, so nothing outside this target may depend on it.
        // FSKit arrives in macOS 15.4 and the application supports 15.0, which
        // SwiftPM cannot express: `platforms:` is one setting for the whole
        // package. So this one target is compiled against a later minimum and
        // nothing else changes. It is Apple Silicon only, as the app is.
        .executableTarget(
            name: "LukottaFS", path: "sources/LukottaFS",
            swiftSettings: [.unsafeFlags(["-target", "arm64-apple-macos15.4"])]),

        // Run with `swift run LukottaTests`. Not a .testTarget: XCTest and
        // swift-testing both require a full Xcode installation, and the tests
        // should run anywhere the app can be built.
        .executableTarget(name: "LukottaTests", dependencies: ["LukottaCore"],
                          path: "sources/LukottaTests"),
    ]
)
