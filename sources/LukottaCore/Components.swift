// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What this app is made of, and what of it is installed on this Mac.
///
/// The app is not one program. It carries a Linux engine, a Linux image the
/// engine boots, the crates that engine reads disk formats with, our own
/// patches to two of them, a script that runs as root, and a privileged helper
/// that outlives any single launch. Each moves on its own schedule.
///
/// Two of those parts live outside the bundle -- the Linux environment in the
/// home directory and the helper registered with the system -- so what is
/// installed can be older than what the app ships. That is not hypothetical:
/// the environment was unpacked once and never again, and the version file
/// beside it was read by nothing, so a guest that changed reached nobody who
/// already had the app.
///
/// Everything here is stated rather than assumed: a version this app cannot
/// read is nil, and nil is never reported as agreement.
public struct Component: Sendable, Equatable {
    /// The name used in a bug report. Not shown in the interface and not
    /// translated: it names a part of the build, and a report that says
    /// "krun_devices" is answerable in any language.
    public var id: String
    /// What this copy of the app carries.
    public var shipped: String?
    /// What is installed on this Mac, when that is a separate thing that can
    /// differ. Nil where the part only exists inside the bundle.
    public var installed: String?

    public init(id: String, shipped: String?, installed: String? = nil) {
        self.id = id
        self.shipped = shipped
        self.installed = installed
    }

    /// Installed, and not what this app ships. Both must be known: an unknown
    /// version is a question, not a mismatch.
    public var isStale: Bool {
        guard let shipped, let installed else { return false }
        return shipped != installed
    }

    /// One line for a report: the part, what it ships, and what is out there
    /// when that differs.
    public var line: String {
        switch (shipped, installed) {
        case let (shipped?, installed?) where shipped != installed:
            return "\(id) \(shipped) (installed: \(installed))"
        case let (shipped?, _):
            return "\(id) \(shipped)"
        case let (nil, installed?):
            return "\(id) installed \(installed), this app states none"
        default:
            return "\(id) unknown"
        }
    }
}

public enum Components {

    /// The version of the script the app writes and runs as root.
    ///
    /// Generated from source rather than shipped as a file, so it has no
    /// version of its own to read. Bumped by hand when the text changes, which
    /// is what makes an engine log answerable a year later: the same log line
    /// means different things either side of a change to the script that
    /// produced it.
    /// Bumped when the generated script changes in a way a reader of a log
    /// would need to tell apart. It sat at "1" through three different scripts,
    /// which made it useless for the one thing it is for: reading a log back
    /// later and knowing which script produced it.
    ///
    /// 2: NTFS tries ntfs3 first and falls back to ntfs-3g with big_writes,
    ///    and driver options and read-only share a single --options.
    public static let mountScriptVersion = "2"

    /// The parts recorded by the build, read from the bundle.
    ///
    /// Written from `vendor/engine.lock`, so a part added to the lock arrives
    /// here without anybody remembering to add it.
    public static func recorded(in bundle: Bundle = .main) -> [String: String] {
        guard let url = bundle.url(forResource: "components", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    /// Every moving part, in a stable order.
    ///
    /// - Parameters:
    ///   - helperInstalled: what the running helper answered, when one is
    ///     registered. It is asked over XPC, which this target does not do, so
    ///     the answer is handed in.
    ///   - guestDirectory: where the Linux environment is unpacked.
    public static func all(
        bundle: Bundle = .main,
        helperInstalled: String? = nil,
        guestDirectory: URL? = EngineEnvironment.alpineDirectory
    ) -> [Component] {
        let info = bundle.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        var parts: [Component] = [
            Component(
                id: "app",
                shipped: [appVersion, build.map { "(build \($0))" }]
                    .compactMap { $0 }.joined(separator: " ").nonEmpty),
            // The helper is installed once and replaced only when it is stale,
            // so a Mac can be running an older one than the app in front of it.
            // That has already caused a crash on update.
            Component(id: "helper", shipped: build, installed: helperInstalled),
            // Unpacked into the home directory, kept between updates, and until
            // recently never replaced.
            Component(
                id: "guest_rootfs",
                shipped: EngineEnvironment.versionShipped,
                installed: guestDirectory.flatMap { EngineEnvironment.versionOfGuest(in: $0) }),
            Component(id: "mount_script", shipped: mountScriptVersion),
        ]

        // Everything the build recorded from the lock: the engine, the image it
        // boots, the crates, our patches. All of it is inside the bundle, so
        // there is nothing separate to compare it against.
        for (id, version) in recorded(in: bundle).sorted(by: { $0.key < $1.key }) {
            parts.append(Component(id: id, shipped: version))
        }
        return parts
    }

    /// The parts installed on this Mac that are not the ones this app ships.
    public static func stale(_ parts: [Component]) -> [Component] {
        parts.filter(\.isStale)
    }

    /// The section a bug report carries. Every part, one per line, with
    /// whatever disagrees said plainly rather than left to be noticed.
    public static func summary(_ parts: [Component]) -> String {
        var lines = ["What this app is made of:"]
        lines.append(contentsOf: parts.map { "  \($0.line)" })
        let old = stale(parts)
        if !old.isEmpty {
            lines.append(
                "  (installed and shipped disagree: \(old.map(\.id).joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    /// The string, or nil when there is nothing in it.
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
