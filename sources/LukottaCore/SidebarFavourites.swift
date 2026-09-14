// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

@preconcurrency import CoreServices
import Foundation

/// An open drive in Finder's sidebar. Locations lists none of this app's volumes on
/// macOS 26, served over AFP or NFS, however mounted or advertised; Favourites does.
public enum SidebarFavourites {
    /// Mount point to the id of the favourite this app added for it. By id, because a
    /// favourite of an ejected volume no longer resolves to any path.
    public static let key = "sidebarFavouritesAddedById"

    public struct Favourite: Equatable {
        public let id: UInt32
        public let path: String?
        public init(id: UInt32, path: String?) {
            self.id = id
            self.path = path
        }
    }

    /// What to add and which favourites to take away, given the favourites there
    /// are, the drives open now, and what this app added before. A favourite
    /// nobody here added is never taken away.
    public static func plan(favourites: [Favourite], open: [String], added: [String: UInt32]) -> (
        add: [String], remove: [UInt32]
    ) {
        let ids = Set(favourites.map(\.id))
        let paths = Set(favourites.compactMap(\.path))
        let add = open.filter { point in
            !paths.contains(point) && !(added[point].map(ids.contains) ?? false)
        }
        let remove = added.filter { !open.contains($0.key) && ids.contains($0.value) }
            .map(\.value).sorted()
        return (add, remove)
    }

    /// Which of the favourites this call inserted to take back, when another process
    /// inserted the same drive at the same moment: the lowest id stays.
    public static func surplus(inserted: [String: UInt32], favourites: [Favourite]) -> [UInt32] {
        inserted.compactMap { point, id in
            let lowest = favourites.filter { $0.path == point }.map(\.id).min()
            return lowest.map { $0 < id } == true ? id : nil
        }.sorted()
    }

    public static func recorded() -> [String: UInt32] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: NSNumber] ?? [:]
        return stored.mapValues(\.uint32Value)
    }

    static func record(_ added: [String: UInt32]) {
        UserDefaults.standard.set(added.mapValues { NSNumber(value: $0) }, forKey: key)
    }

    /// Where Finder shows each drive this app opened: its AFP volume, or the NFS mount
    /// itself where no AFP volume stands in front of it. A drive another app opened is
    /// that app's to list, and a volume inside another is reached through that one.
    public static func openDrives(in table: String, opened: Set<String> = OpenedHere.all())
        -> [String]
    {
        let entries = MountTableEntry.all(in: table)
        var hiddenByHost: [String: String] = [:]
        for entry in entries where AfpShare.isHidden(entry) {
            if let host = AfpShare.hostAndShare(ofNFSSource: entry.source)?.host {
                hiddenByHost[host] = entry.mountPoint
            }
        }
        let points = entries.compactMap { entry -> String? in
            if entry.isAFP, let host = AfpShare.afpHost(of: entry.source) {
                return hiddenByHost[host].map(opened.contains) == true ? entry.mountPoint : nil
            }
            if entry.isEngineMount, !AfpShare.isHidden(entry), opened.contains(entry.mountPoint) {
                return entry.mountPoint
            }
            return nil
        }
        return Set(points).filter { point in
            !points.contains { point.hasPrefix($0 + "/") }
        }.sorted()
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var seenOpen: Set<String>?

    /// Make the sidebar agree with the mount table: every open drive listed,
    /// every drive this app listed and no longer open gone.
    public static func reconcile(mountTable given: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let table = given ?? mountTable()
        if reconcileHoldingLock(table) { seenOpen = Set(openDrives(in: table)) }
    }

    /// Reconcile when the drives open have changed since this process last
    /// looked, whoever opened or closed them. A pass still running is left to
    /// finish, and the next look tries again.
    public static func followMountTable(_ given: String? = nil) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let table = given ?? mountTable()
        let open = Set(openDrives(in: table))
        guard seenOpen != open else { return }
        if reconcileHoldingLock(table) { seenOpen = open }
    }

    /// False when the list could not be read, so nothing recorded is lost to silence.
    static func reconcileHoldingLock(_ table: String) -> Bool {
        guard
            let list = LSSharedFileListCreate(
                nil, "com.apple.LSSharedFileList.FavoriteItems" as CFString, nil)?
                .takeRetainedValue(),
            let items = snapshot(of: list)
        else { return false }
        let open = openDrives(in: table)
        let before = recorded()
        let (add, remove) = plan(favourites: items.map(\.favourite), open: open, added: before)
        Log.mount.notice(
            "sidebar: \(open.count, privacy: .public) open, \(items.count, privacy: .public) favourites, \(before.count, privacy: .public) recorded, adding \(add.count, privacy: .public), removing \(remove.count, privacy: .public)"
        )
        for item in items where remove.contains(item.favourite.id) {
            LSSharedFileListItemRemove(list, item.item)
        }
        var inserted: [String: UInt32] = [:]
        for point in add {
            let after =
                snapshot(of: list)?.last?.item ?? kLSSharedFileListItemLast.takeUnretainedValue()
            guard
                let item = LSSharedFileListInsertItemURL(
                    list, after, nil, nil, URL(fileURLWithPath: point) as CFURL, nil, nil)
            else { continue }
            inserted[point] = LSSharedFileListItemGetID(item)
        }
        guard let now = snapshot(of: list) else { return false }
        let taken = surplus(inserted: inserted, favourites: now.map(\.favourite))
        for item in now where taken.contains(item.favourite.id) {
            LSSharedFileListItemRemove(list, item.item)
        }
        let present = Set(now.map(\.favourite.id)).subtracting(taken)
        // Read again: another process of this app may have recorded meanwhile.
        var merged = recorded().filter { present.contains($0.value) && !remove.contains($0.value) }
        for (point, id) in inserted where present.contains(id) { merged[point] = id }
        record(merged)
        return true
    }

    static func snapshot(of list: LSSharedFileList) -> [(
        item: LSSharedFileListItem, favourite: Favourite
    )]? {
        var seed: UInt32 = 0
        guard let copied = LSSharedFileListCopySnapshot(list, &seed) else { return nil }
        return (copied.takeRetainedValue() as NSArray).map { element in
            let item = element as! LSSharedFileListItem
            let flags = UInt32(
                kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
            let url =
                LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL?
            return (item, Favourite(id: LSSharedFileListItemGetID(item), path: url?.path))
        }
    }
}
