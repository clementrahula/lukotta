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
        public var engineLogs = 0
        public var rememberedFiles = 0
        public var rememberedNames = 0
        public var arrangedRows = 0

        public var isEmpty: Bool {
            workspaces == 0 && mountPoints == 0 && engineLogs == 0 && rememberedFiles == 0
                && rememberedNames == 0 && arrangedRows == 0
        }
    }

    /// How often the sweep should run while drives are open.
    ///
    /// A mount whose engine has died stays in the table looking like an open
    /// drive, and macOS eventually puts up "Server connections interrupted",
    /// naming it and offering Disconnect All. That is the one window this app
    /// exists to make sure nobody ever sees, and it reached the owner on
    /// 2026-09-05.
    ///
    /// The clearing below was written and tested long before; what was missing
    /// is that nothing ran it unless somebody opened or ejected a drive, so an
    /// engine that died while the app sat idle was left for macOS to find.
    ///
    /// Thirty seconds against a threshold of minutes. The probe inside
    /// `deadEngineMounts` deliberately spends about a minute deciding a mount is
    /// dead rather than slow -- one gone quiet for forty seconds has come back
    /// serving perfectly -- so a dead mount is away within about ninety seconds
    /// of dying, and macOS does not begin to reckon a mount unresponsive until a
    /// request has timed out five times at sixty seconds each.
    public static let deadMountWatchSeconds: Int = 30

    /// Take away everything finished with. Safe at any moment, including with
    /// drives open: everything in use fails one of the two rules.
    @discardableResult
    public static func sweep(
        now: Date = Date(),
        mountTable: String = LukottaCore.mountTable(),
        attached: Set<String>? = nil
    ) -> Result {
        var result = Result()
        // Mounts whose server has gone, before anything is counted: they are in
        // the table, they look like drives somebody has open, and macOS refuses
        // the next mount at the same name while one is there.
        EngineProcesses.deadMountsCleared(in: mountTable)
        result.workspaces = removeFinishedWorkspaces(now: now)
        result.mountPoints = removeEmptyMountPoints(in: mountTable)
        // Said loudly and separately. An empty one is litter; one with files in
        // it is somebody's data sitting on the wrong disk.
        for stranded in strandedMountPoints(in: mountTable) {
            Log.app.error(
                "\(stranded.files, privacy: .public) files are in \(stranded.path, privacy: .public), which is not a mounted drive: the mount went away and they were written to the startup disk"
            )
        }
        result.engineLogs = EngineLogs.removeOld(now: now)
        // Mount points this app made that are not mounted any more: ejected in
        // Finder, or gone with a restart.
        _ = OpenedHere.forgetWhatIsGone(mountTable: mountTable)
        let (files, names, rows) = forgetWhatIsGone(attached: attached)
        result.rememberedFiles = files
        result.rememberedNames = names
        result.arrangedRows = rows
        if !result.isEmpty {
            Log.app.notice(
                "swept \(result.workspaces, privacy: .public) workspaces, \(result.mountPoints, privacy: .public) mount points, \(result.engineLogs, privacy: .public) engine logs, \(result.rememberedFiles + result.rememberedNames + result.arrangedRows, privacy: .public) remembered things"
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

    /// Mount points this app made that nothing is mounted on **and that are not
    /// empty**, with how many files each holds.
    ///
    /// These are the dangerous ones, and they are why the sweep above only ever
    /// removes empty directories.
    ///
    /// When a mount goes away underneath a copy -- the guest stops answering
    /// for longer than the engine's `deadtimeout=45`, so macOS drops the mount
    /// -- the directory it was mounted on stays behind as an ordinary directory
    /// on the startup disk. A copy still running writes straight into it, and
    /// succeeds, because there is nothing wrong with writing to a directory.
    /// Finder shows a completed copy. The files are on the Mac. They are not on
    /// the drive, and nothing anywhere says so.
    ///
    /// Reproduced twice while this was written: of 150 files copied across a
    /// seventy-second outage, the ones attempted during it failed honestly, the
    /// ones before it vanished with the mount, and 115 landed on the startup
    /// disk byte-for-byte correct and entirely in the wrong place.
    ///
    /// So they are not swept -- removing them would destroy the only copy of
    /// whatever is in them -- and they are not ignored either. They are
    /// reported, so somebody can be told where their files actually went.
    public static func strandedMountPoints(in mountTable: String, home: URL? = nil) -> [(
        path: String, files: Int
    )] {
        let base = (home ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Volumes", isDirectory: true)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: base.path) else { return [] }
        let mounted = Set(MountTableEntry.all(in: mountTable).map(\.mountPoint))
        var stranded: [(path: String, files: Int)] = []
        for name in entries.sorted() {
            let point = base.appendingPathComponent(name, isDirectory: true)
            guard !mounted.contains(point.path) else { continue }
            guard let inside = try? manager.contentsOfDirectory(atPath: point.path),
                !inside.isEmpty
            else { continue }
            stranded.append((path: point.path, files: inside.count))
        }
        return stranded
    }

    // MARK: The engine's own logs

    /// The logs the engine writes for every mount, and how we know which are
    /// ours.
    ///
    /// Three files per mount -- the engine's, the guest kernel's, the network
    /// helper's -- written straight into ~/Library/Logs with a random suffix,
    /// about nineteen kilobytes a mount, and never rotated or removed. The
    /// engine hard-codes the directory and offers no way to redirect it.
    ///
    /// They cannot be recognised by name: a Mac with anylinuxfs installed on
    /// its own writes files called exactly the same thing, and those are not
    /// ours to delete. So each mount notes which files appeared while it ran,
    /// and only those are ever removed.
    public enum EngineLogs {
        /// Where the names of the ones we wrote are kept. Public so a test can
        /// assert the list shrinks rather than growing for ever.
        public static let key = "engineLogsWeMade"

        /// Inside this app's own engine directory, which is where the engine
        /// writes them now that it is given a home of its own. Nothing else
        /// writes here, so everything found is ours to remove -- and a Mac
        /// running anylinuxfs on its own keeps its logs where it always did,
        /// untouched.
        public static var directory: URL {
            EngineEnvironment.engineHome.appendingPathComponent("Library/Logs", isDirectory: true)
        }

        /// How long one is kept. Long enough to be in a bug report written the
        /// week after the fault, short enough not to accumulate.
        public static let keepFor: TimeInterval = 7 * 24 * 60 * 60

        static let prefixes = ["anylinuxfs-", "anylinuxfs_kernel-", "anylinuxfs_nethelper-"]

        static func isEngineLog(_ name: String) -> Bool {
            name.hasSuffix(".log") && prefixes.contains { name.hasPrefix($0) }
        }

        /// What the engine has written in there at this moment, ours or not.
        public static func present(in directory: URL? = nil) -> Set<String> {
            let base = directory ?? Self.directory
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            return Set(names.filter(isEngineLog))
        }

        /// Note whatever appeared since the snapshot as ours.
        @discardableResult
        public static func claimAppeared(since before: Set<String>, in directory: URL? = nil)
            -> [String]
        {
            let fresh = present(in: directory).subtracting(before).sorted()
            guard !fresh.isEmpty else { return [] }
            var mine = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            mine.formUnion(fresh)
            UserDefaults.standard.set(mine.sorted(), forKey: key)
            return fresh
        }

        /// Take away ours that are old, and forget the ones already gone.
        @discardableResult
        public static func removeOld(
            now: Date = Date(), in directory: URL? = nil, keepFor: TimeInterval = keepFor
        ) -> Int {
            let base = directory ?? Self.directory
            let manager = FileManager.default
            let mine = UserDefaults.standard.stringArray(forKey: key) ?? []
            guard !mine.isEmpty else { return 0 }

            // Where the engine wrote before it was given a directory of its
            // own. Names recorded then resolve against the new directory, where
            // nothing of that name exists -- so they were forgotten as "already
            // gone" while the files sat in the old place for ever.
            let legacy = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs", isDirectory: true)

            var kept: [String] = []
            var removed = 0
            for name in mine {
                var file = base.appendingPathComponent(name)
                if !manager.fileExists(atPath: file.path) {
                    let older = legacy.appendingPathComponent(name)
                    if manager.fileExists(atPath: older.path) { file = older }
                }
                guard manager.fileExists(atPath: file.path) else { continue }  // already gone
                let written =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let written, now.timeIntervalSince(written) < keepFor {
                    kept.append(name)
                    continue
                }
                if (try? manager.removeItem(at: file)) != nil {
                    removed += 1
                } else {
                    kept.append(name)
                }
            }
            if kept.count != mine.count { UserDefaults.standard.set(kept, forKey: key) }
            return removed
        }
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

        // What is attached, or no answer at all.
        //
        // hdiutil is asked with a timeout, and a Mac with a network volume or a
        // sleeping external disk in the mix can take longer than that. The
        // answer then is nil -- not "nothing is attached" -- and reading it as
        // the latter empties the list of files this app attached, which is the
        // only thing that can put them back after a crash. They would stay
        // attached, unexplained, with nothing left saying they were ours.
        let known: Set<String>?
        if let attached {
            known = attached
        } else if let listing = DiskImage.attachments() {
            known = Set(listing.values)
        } else {
            known = nil
        }

        // Attached by us: gone when the file is gone, or when nothing is
        // attached from it any more. Anything still attached stays, even after
        // a crash -- that is the whole reason this list exists.
        let opened = DiskImage.OpenedFiles.all()
        var files = 0
        if let known {
            for path in opened where !known.contains(path) || !manager.fileExists(atPath: path) {
                DiskImage.OpenedFiles.remove(path)
                files += 1
            }
        } else {
            // Nothing is forgotten on no evidence. A file that has since been
            // deleted is still dropped, because that much is known without
            // asking hdiutil anything.
            Log.app.notice("hdiutil did not answer; the list of attached files is left alone")
            for path in opened where !manager.fileExists(atPath: path) {
                DiskImage.OpenedFiles.remove(path)
                files += 1
            }
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
