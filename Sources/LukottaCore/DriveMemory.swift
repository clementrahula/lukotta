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
