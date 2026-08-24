// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Everything this app can leave behind on somebody's Mac, and the one place
/// that takes it away.
///
/// Written as one type because the alternative is what was here before: a
/// workspace destroyed on quit but not after a crash, a mount point left in
/// ~/Volumes by every eject, and two lists in the settings that only ever grew.
/// None of those was a bug anybody would file. Together they were a hundred and
/// twelve directories and a list of every file the person had ever opened.
///
/// Two rules decide what may be removed, and both must hold:
///
/// **Scope.** Only what this app made, recognised by name: a workspace called
/// Lukotta-<uuid> in this app's own temporary directory, a mount point this app
/// mounted on, a settings key this app owns. Nothing is removed because it
/// merely looks like litter.
///
/// **Time and use.** Only what is finished with: a workspace older than the
/// grace period and serving no mount, a mount point with nothing mounted on it,
/// a remembered file that is no longer there. A sweep during a mount must never
/// take the ground out from under it.
public enum Housekeeping {

    /// How long a workspace is left alone.
    ///
    /// Long enough that a mount in progress is never touched -- the slowest
    /// observed was about a minute, at the ceiling with a dozen machines
    /// running -- and short enough that a crash is cleaned up at the next
    /// launch rather than at the next reboot.
    public static let grace: TimeInterval = 15 * 60

    /// What one sweep did, for the log and for a test to assert against.
    public struct Result: Equatable, Sendable {
        public var workspaces = 0
        public var mountPoints = 0
        public var rememberedFiles = 0
        public var rememberedNames = 0
        public var arrangedRows = 0

        public var isEmpty: Bool {
            workspaces == 0 && mountPoints == 0 && rememberedFiles == 0
                && rememberedNames == 0 && arrangedRows == 0
        }
    }

    /// Take away everything finished with. Safe at any moment, including with
    /// drives open: everything in use fails one of the two rules.
    @discardableResult
    public static func sweep(
        now: Date = Date(),
        mountTable: String = LukottaCore.mountTable(),
        attached: Set<String>? = nil
    ) -> Result {
        var result = Result()
        result.workspaces = removeFinishedWorkspaces(now: now)
        result.mountPoints = removeEmptyMountPoints(in: mountTable)
        let (files, names, rows) = forgetWhatIsGone(attached: attached)
        result.rememberedFiles = files
        result.rememberedNames = names
        result.arrangedRows = rows
        if !result.isEmpty {
            Log.app.notice(
                "swept \(result.workspaces, privacy: .public) workspaces, \(result.mountPoints, privacy: .public) mount points, \(result.rememberedFiles + result.rememberedNames + result.arrangedRows, privacy: .public) remembered things"
            )
        }
        return result
    }

    // MARK: The workspace a mount is given

    /// A mount's scratch directory: the script, its log, and a symlink named
    /// after the drive. Made per mount, and left behind by anything that stops
    /// the app before it can tidy up.
    public static func removeFinishedWorkspaces(now: Date, in directory: URL? = nil) -> Int {
        let base = directory ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(Workspace.prefix) {
            let modified =
                (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // No date is not a reason to keep it, but it is a reason to be sure
            // it is one of ours: the name already says so.
            if let modified, now.timeIntervalSince(modified) < grace { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: The place a drive was mounted

    /// The empty directory an ejected drive leaves in ~/Volumes.
    ///
    /// The engine makes one per mount and does not take it back, so a year of
    /// opening drives is a year of empty folders in a directory Finder shows.
    /// Removed only when nothing is mounted there and it holds nothing: an
    /// rmdir, which refuses anything else, rather than a delete.
    public static func removeEmptyMountPoints(in mountTable: String, home: URL? = nil) -> Int {
        let base = (home ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Volumes", isDirectory: true)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: base.path) else { return 0 }
        let mounted = Set(MountTableEntry.all(in: mountTable).map(\.mountPoint))
        var removed = 0
        for name in entries {
            let point = base.appendingPathComponent(name, isDirectory: true)
            guard !mounted.contains(point.path) else { continue }
            guard let inside = try? manager.contentsOfDirectory(atPath: point.path),
                inside.isEmpty
            else { continue }
            if rmdir(point.path) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: What the settings remember

    /// Everything the app remembers about files, checked against the files.
    ///
    /// Three lists grew and never shrank: the containers this app attached, the
    /// name each image's volume turned out to have, and the order somebody
    /// arranged. A file that has been deleted or moved is remembered for ever,
    /// which is both litter and a record of what somebody once opened.
    public static func forgetWhatIsGone(attached: Set<String>? = nil) -> (Int, Int, Int) {
        let manager = FileManager.default
        let stillAttached = attached ?? Set((DiskImage.attachments() ?? [:]).values)

        // Attached by us: gone when the file is gone, or when nothing is
        // attached from it any more. Anything still attached stays, even after
        // a crash -- that is the whole reason this list exists.
        let opened = DiskImage.OpenedFiles.all()
        var files = 0
        for path in opened where !stillAttached.contains(path) || !manager.fileExists(atPath: path)
        {
            DiskImage.OpenedFiles.remove(path)
            files += 1
        }

        // The name a volume had: kept for files that are still there.
        let names = DriveMemory.forgetMissingFiles()

        // The arrangement: a row whose file has gone keeps its place, because
        // somebody put it there and the file may come back. One whose file has
        // been deleted cannot.
        var rows = 0
        let order = ListOrderMemory.read()
        let kept = order.filter { row in
            guard row.hasPrefix("/") else { return true }  // a UUID, not a path
            let path = row.components(separatedBy: "#").first ?? row
            if manager.fileExists(atPath: path) { return true }
            rows += 1
            return false
        }
        if rows > 0 { ListOrderMemory.write(kept) }

        return (files, names, rows)
    }
}
