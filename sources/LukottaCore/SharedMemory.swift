// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What every Lukotta app remembers about drives, in one file none of them owns. Never renamed.
public enum SharedMemory {
    public struct Contents: Codable, Equatable, Sendable {
        public var names: [String: String] = [:]
        public var fingerprints: [String: String] = [:]
        /// Each app's own list of drives to open again, so two apps never open the same one.
        public var restorable: [String: [MountMemory.Entry]] = [:]
        public var carried: [String] = []
    }

    /// The same file for the release, the beta, a local build and whatever comes after them.
    public static var defaultFile: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Lukotta", isDirectory: true)
            .appendingPathComponent("memory.json")
    }

    /// Tests point this elsewhere, so nobody's real drives are touched.
    nonisolated(unsafe) public static var fileOverride: URL?

    static var file: URL { fileOverride ?? defaultFile }

    static let app = Bundle.main.bundleIdentifier ?? "com.example.driveunlocker"

    static let lock = NSLock()

    public static func read() -> Contents {
        lock.withLock { carriedOver(load()) }
    }

    /// Changes under one lock and one atomic write, so two apps never lose each other's entries.
    public static func change(_ body: (inout Contents) -> Void) {
        lock.withLock {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(file.path, O_RDONLY | O_CREAT, 0o600)
            if descriptor >= 0 { flock(descriptor, LOCK_EX) }
            defer {
                if descriptor >= 0 {
                    flock(descriptor, LOCK_UN)
                    close(descriptor)
                }
            }
            var contents = carriedOver(load())
            body(&contents)
            if let data = try? JSONEncoder().encode(contents) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    public static var restorableHere: [MountMemory.Entry] { read().restorable[app] ?? [] }

    static func load() -> Contents {
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
            let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else { return Contents() }
        return contents
    }

    /// What this app kept in its own settings before the file existed, merged in and left in place.
    static func carriedOver(_ start: Contents) -> Contents {
        var contents = start
        let defaults = UserDefaults.standard
        let names = defaults.dictionary(forKey: "knownVolumeNames") as? [String: String] ?? [:]
        let prints =
            defaults.dictionary(forKey: "com.lukotta.volumeFingerprints." + app)
            as? [String: String] ?? [:]
        contents.names.merge(names) { kept, _ in kept }
        contents.fingerprints.merge(prints) { kept, _ in kept }
        if let data = defaults.data(forKey: "restorableMounts"),
            let entries = try? JSONDecoder().decode([MountMemory.Entry].self, from: data)
        {
            var here = contents.restorable[app] ?? []
            for entry in entries where !here.contains(where: { $0.uuid == entry.uuid }) {
                here.append(entry)
            }
            contents.restorable[app] = here
        }
        return contents
    }
}
