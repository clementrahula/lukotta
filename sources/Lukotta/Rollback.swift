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

    /// What the app and the shim in front of it both file this under: the
    /// identifier, as everything else this app keeps is filed. The name on disk
    /// is the fallback on both sides, for a bundle whose Info.plist cannot be
    /// read.
    private static var bundleName: String {
        AppRollback.supportName(
            identifier: Bundle.main.bundleIdentifier,
            bundleName: Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)
    }

    /// Where this used to be kept, so that what is there can be taken away.
    private static var oldPlace: URL? {
        let name = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        guard name != bundleName else { return nil }
        return try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent(name, isDirectory: true)
    }

    private static var support: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent(bundleName, isDirectory: true)
    }

    private static var keptAside: URL? {
        support?.appendingPathComponent("previous/\(bundleName).app", isDirectory: true)
    }

    /// Where the shim counts launches. Cleared from here, because this is the
    /// place that knows a launch worked.
    private static var launchAttempts: URL? {
        support?.appendingPathComponent("launch-attempts")
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
        // Copied under another name and moved into place at the end. The shim
        // in front of the app decides by whether the copy is there, and a copy
        // interrupted half way -- the quit that follows this is what interrupts
        // it -- is a bundle that exists, restores, and does not start. The move
        // is the moment it becomes something to fall back to.
        let building = keptAside.deletingLastPathComponent()
            .appendingPathComponent("previous.copying", isDirectory: true)
        do {
            try manager.createDirectory(
                at: keptAside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: building)
            try manager.copyItem(at: Bundle.main.bundleURL, to: building)
            try? manager.removeItem(at: keptAside)
            try manager.moveItem(at: building, to: keptAside)
        } catch {
            // Said out loud rather than shrugged at. A disk with no room on it
            // arms nothing, and the update that follows then has nothing to
            // fall back to -- which is worth knowing from the log afterwards
            // rather than guessing at.
            Log.updates.error("the outgoing version could not be kept aside: \(error)")
            try? manager.removeItem(at: building)
        }
    }

    // MARK: Launching

    /// Decide, act, and say whether the app should carry on starting.
    ///
    /// Returns false when the previous version has been put back and opened, in
    /// which case this process should stop.
    static func evaluateLaunch() -> Bool {
        // What this mechanism itself left under the old name, which was the
        // application's rather than its identifier's. A copy of a version two
        // updates ago is not worth carrying across, and the uninstaller removes
        // the identifier's directory, not this one.
        //
        // Only this mechanism's own two entries: the directory under the old
        // name is also where the Linux environment lives on a Mac that has not
        // been through the move yet, and that move happens later in this same
        // launch. Taking the whole directory would take the environment with
        // it, an unpack the app would then have to do again.
        if let oldPlace {
            for leftover in ["previous", "launch-attempts"] {
                let url = oldPlace.appendingPathComponent(leftover)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                Log.updates.notice(
                    "taking away \(leftover, privacy: .public) kept under the old name")
                try? FileManager.default.removeItem(at: url)
            }
        }

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
        // The shim counts every launch and cannot tell whether any of them
        // worked; this is the answer it is waiting for.
        if let launchAttempts { try? FileManager.default.removeItem(at: launchAttempts) }
        // A copy of the version that is running is not spent: it was made for
        // an update that has been fetched but not yet swapped in, and the swap
        // can be one quit away. Dropping it here — on any healthy launch in
        // between, and on every --smoke-test a release or a preflight runs —
        // would leave that install with nothing to fall back to.
        //
        // A copy of some *other* version is proof the swap already happened,
        // and this launch is the proof that it worked. That one is spent.
        let kept = keptAsideVersion()
        guard let kept, kept != currentVersion else { return }
        Log.updates.notice(
            "build \(currentVersion, privacy: .public) started; the copy of \(kept, privacy: .public) is no longer needed"
        )
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
