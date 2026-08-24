// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import Foundation
import LukottaCore

/// Does the moving that `AppRollback` decides on.
///
/// The kept-aside copy is a whole app bundle, so it is not small. It exists
/// only between an update installing and the first launch that works, and is
/// dropped the moment one does — which is also what disarms the counter.
enum Rollback {
    private static let recordKey = "com.lukotta.launchRecord"

    private static var support: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Lukotta", isDirectory: true)
    }

    private static var keptAside: URL? {
        support?.appendingPathComponent("previous/Lukotta.app", isDirectory: true)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// The version of the bundle sitting in the keep-aside place, if any.
    static func keptAsideVersion() -> String? {
        guard let keptAside,
            let info = NSDictionary(
                contentsOf: keptAside.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    // MARK: Installing

    /// Copy the running bundle aside, before an update replaces it.
    ///
    /// Called from Sparkle's willInstallUpdate, which runs in the version that
    /// is about to be replaced — the last moment it can be copied.
    static func keepCurrentAside() {
        guard let keptAside else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: keptAside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: keptAside)
        try? manager.copyItem(at: Bundle.main.bundleURL, to: keptAside)
    }

    // MARK: Launching

    /// Decide, act, and say whether the app should carry on starting.
    ///
    /// Returns false when the previous version has been put back and opened, in
    /// which case this process should stop.
    static func evaluateLaunch() -> Bool {
        let action = AppRollback.decide(
            record: readRecord(),
            currentVersion: currentVersion,
            keptAside: keptAsideVersion(),
            now: Date())

        switch action {
        case .proceed(let record):
            write(record)
            return true
        case .rollBack(let attempts):
            Log.updates.error(
                "\(attempts, privacy: .public) launches of build \(currentVersion, privacy: .public) did not finish; restoring"
            )
            return !restore()
        }
    }

    /// This launch worked. Drop the copy, which disarms the whole mechanism
    /// until the next update arms it again.
    static func confirmHealthy() {
        write(nil)
        if keptAsideVersion() != nil {
            Log.updates.notice("this build started; the kept-aside copy is no longer needed")
        }
        if let keptAside { try? FileManager.default.removeItem(at: keptAside) }
    }

    // MARK: Doing it

    private static func restore() -> Bool {
        guard let keptAside, FileManager.default.fileExists(atPath: keptAside.path) else {
            return false
        }
        let installed = Bundle.main.bundleURL
        let manager = FileManager.default
        // Move the broken one aside rather than deleting it: if putting the old
        // one back fails, the machine must still have an app on it.
        let broken = keptAside.deletingLastPathComponent()
            .appendingPathComponent("broken.app", isDirectory: true)
        try? manager.removeItem(at: broken)
        do {
            try manager.moveItem(at: installed, to: broken)
            try manager.moveItem(at: keptAside, to: installed)
        } catch {
            Log.updates.error("could not restore the previous version: \(error)")
            // Put it back the way it was, so nothing is lost either way.
            if !manager.fileExists(atPath: installed.path) {
                try? manager.moveItem(at: broken, to: installed)
            }
            return false
        }
        try? manager.removeItem(at: broken)
        write(nil)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", installed.path]
        try? task.run()
        return true
    }

    // MARK: The record

    private static func readRecord() -> LaunchRecord? {
        guard let stored = UserDefaults.standard.dictionary(forKey: recordKey),
            let version = stored["version"] as? String, !version.isEmpty,
            let attempts = stored["attempts"] as? Int, attempts >= 1
        else { return nil }
        let started = stored["firstAttemptAt"] as? Double ?? Date().timeIntervalSince1970
        return LaunchRecord(
            version: version, attempts: attempts,
            firstAttemptAt: Date(timeIntervalSince1970: started))
    }

    private static func write(_ record: LaunchRecord?) {
        guard let record else {
            UserDefaults.standard.removeObject(forKey: recordKey)
            return
        }
        UserDefaults.standard.set(
            [
                "version": record.version,
                "attempts": record.attempts,
                "firstAttemptAt": record.firstAttemptAt.timeIntervalSince1970,
            ], forKey: recordKey)
    }
}
