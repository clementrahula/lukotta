// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What was open, so that it can be opened again after a restart.
///
/// A mount does not survive a restart: the virtual machine serving it is gone
/// and the NFS mount with it. Anyone who keeps a drive open all day therefore
/// has to open it again by hand every morning, which is what this removes.
///
/// Only what is needed to open the same thing again is kept: which volume, and
/// how it was opened. No passphrase is stored here. A drive that needs one is
/// restored only when the passphrase is in the Keychain already, because the
/// person asked for it to be remembered; otherwise it is passed over in
/// silence, since there is nobody there to type it.
public enum MountMemory {

    /// One thing that was open.
    public struct Entry: Codable, Equatable, Sendable {
        /// The volume's own identifier, which survives a restart where a device
        /// path does not: `/dev/disk4s1` becomes `/dev/disk6s1` when the drives
        /// are plugged in in a different order.
        public var uuid: String
        /// The file, where this was a disk image rather than a drive.
        public var imagePath: String?
        /// Which logical volume of a group was opened, where one was chosen.
        public var volumeIdentifier: String?
        /// Whether it was open read-only, so that it comes back the same way.
        public var readOnly: Bool
        /// What it was called, for the log. Never shown.
        public var name: String

        public init(
            uuid: String, imagePath: String? = nil, volumeIdentifier: String? = nil,
            readOnly: Bool, name: String
        ) {
            self.uuid = uuid
            self.imagePath = imagePath
            self.volumeIdentifier = volumeIdentifier
            self.readOnly = readOnly
            self.name = name
        }
    }

    private static let key = "restorableMounts"

    /// Where this is stored. The suite is the running bundle's own, so an
    /// unbranded build and a branded one do not read each other's list.
    private static var defaults: UserDefaults { .standard }

    public static func all() -> [Entry] {
        guard let data = defaults.data(forKey: key),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    /// Record that this is open, replacing any earlier record of the same
    /// volume.
    public static func remember(_ entry: Entry) {
        var entries = all().filter { $0.uuid != entry.uuid }
        entries.append(entry)
        save(entries)
    }

    /// Forget one volume, which is what ejecting means.
    public static func forget(uuid: String) {
        save(all().filter { $0.uuid != uuid })
    }

    /// Forget everything, for uninstalling and for turning the setting off.
    public static func forgetAll() {
        defaults.removeObject(forKey: key)
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Whether the app opens at login and puts back what was open.
///
/// Off unless it is turned on. Kept beside the memory itself so that the two
/// are read the same way from the application and from its tests.
public enum RestorePreference {
    public static let key = "restoreMountsAtLogin"

    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
