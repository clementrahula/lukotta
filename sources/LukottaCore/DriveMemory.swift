// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What Lukotta remembers about drives it has opened before.
///
/// The volume label is only knowable once a drive is unlocked, which is after
/// the point where it would be useful — the NFS server is named before that, so
/// a drive shows as "disk4s1.local" in Finder. Recording the label from a
/// successful mount lets the next one be named properly.
///
/// Keyed on partition UUID, so it survives replugging as a different diskNsM.
/// Nothing sensitive is stored here: credentials live in the Keychain.
public enum DriveMemory {
    private static let key = "knownVolumeNames"

    private static var store: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The label this drive had the last time it was opened.
    public static func knownName(for uuid: String) -> String? {
        guard !uuid.isEmpty else { return nil }
        return store[uuid]
    }

    /// Forget the names of files that are no longer on this Mac.
    ///
    /// The keys are partition UUIDs for drives and paths for images. A UUID
    /// says nothing about a file and is kept: the drive may be in a drawer. A
    /// path that no longer exists is a record of something somebody deleted,
    /// and is of no use to anybody.
    @discardableResult
    public static func forgetMissingFiles() -> Int {
        let manager = FileManager.default
        var current = store
        let gone = current.keys.filter { $0.hasPrefix("/") && !manager.fileExists(atPath: $0) }
        for key in gone { current[key] = nil }
        if !gone.isEmpty { store = current }
        return gone.count
    }

    /// Record the label of a drive that has just been opened.
    ///
    /// `mountPoint` is a path such as /Volumes/BACKUP; the last component is the
    /// name macOS gave the volume.
    public static func remember(mountPoint: String, for uuid: String) {
        guard !uuid.isEmpty else { return }
        let name = (mountPoint as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return }
        var current = store
        current[uuid] = name
        store = current
    }

    /// Whether any drive has been opened before. Evidence that reading a drive
    /// was permitted at least once.
    public static var hasAny: Bool { !store.isEmpty }

    /// Drop one entry. The app forgets everything at once or nothing; this is
    /// how a test removes what it added without touching anyone's real names.
    public static func forget(uuid: String) {
        var current = store
        current.removeValue(forKey: uuid)
        store = current
    }

    /// Everything remembered, for a "forget this Mac" style reset.
    public static func forgetEverything() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
