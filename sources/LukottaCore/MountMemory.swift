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

/// The mount points this copy of the app made.
///
/// A beta and a release both serve drives into ~/Volumes, and the engine's own
/// status reports every mount on the Mac whoever made it. Nothing in a mount
/// says which application asked for it -- so uninstalling one offered to eject,
/// and then ejected, drives the other had open, and anylinuxfs's own besides.
///
/// This is the record: written when a mount is made, taken away when it is
/// ejected, and kept in this app's own settings, which a beta and a release do
/// not share. It survives a restart, because what is open at the moment
/// somebody uninstalls may have been opened days ago.
public enum OpenedHere {
    public static let key = "mountPointsThisAppMade"

    public static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    public static func add(_ mountPoint: String) {
        guard !mountPoint.isEmpty else { return }
        var points = all()
        points.insert(mountPoint)
        UserDefaults.standard.set(points.sorted(), forKey: key)
    }

    public static func remove(_ mountPoint: String) {
        var points = all()
        guard points.remove(mountPoint) != nil else { return }
        UserDefaults.standard.set(points.sorted(), forKey: key)
    }

    /// Which of these mounts are this app's, out of everything the engine
    /// reports. A mount point this app never recorded belongs to something
    /// else, and nothing here touches it.
    public static func ours(of mountPoints: [String]) -> [String] {
        let mine = all()
        return mountPoints.filter { mine.contains($0) }
    }

    /// Forget what is no longer mounted, so the list cannot grow for ever.
    @discardableResult
    public static func forgetWhatIsGone(mountTable table: String = LukottaCore.mountTable()) -> Int
    {
        let live = Set(MountTableEntry.all(in: table).map(\.mountPoint))
        let mine = all()
        let stale = mine.subtracting(live)
        guard !stale.isEmpty else { return 0 }
        UserDefaults.standard.set(mine.subtracting(stale).sorted(), forKey: key)
        return stale.count
    }

    public static func forgetEverything() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
