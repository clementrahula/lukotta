// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import CoreServices
import Foundation

/// Removes the empty files a stopped Finder copy leaves on a volume.
///
/// Finder makes every file of a copy before it writes any of them -- empty, and
/// marked in its FinderInfo as type "brok", creator "MACS" -- and publishes a
/// file progress for each. When the copy is cancelled or fails, the progress
/// of every file it had not reached is withdrawn and the file stays behind,
/// empty, on a Mac's own disks too. Here it goes as soon as that happens. A
/// file's progress is seen only by subscribing to its folder, so the folders
/// are learned from the volume's own events.
public final class PlaceholderSweeper: @unchecked Sendable {
    /// Folders subscribed to at once, unless every one of them is being copied into.
    static let folderLimit = 64
    /// How long a withdrawn progress is left before its file is looked at, so
    /// that Finder finishes with the file first.
    static let settle: TimeInterval = 1
    /// How long a placeholder nobody publishes must stay unchanged before it
    /// counts as one a stopped copy abandoned.
    static let abandoned: TimeInterval = 5
    /// The most entries of one folder looked at for those.
    static let scanLimit = 10_000

    /// What a file's inode says about when it last changed. A placeholder
    /// that a new copy takes over, or that Finder finishes, changes; one a
    /// stopped copy left does not.
    public struct ChangeStamp: Equatable, Sendable {
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
    }

    private let root: String
    private let queue = DispatchQueue(label: "com.lukotta.placeholder-sweeper")
    private var stream: FSEventStreamRef?
    private var stopped = false
    /// Subscribed folders, the most recently written last.
    private var folders: [(path: String, token: Any)] = []
    /// Files whose progress is published now, which nothing here touches.
    private var published: Set<String> = []
    /// Bumped each time a file's progress is published, so that a file a new
    /// copy has taken up is left to it.
    private var generation: [String: Int] = [:]

    public init(root: String) {
        self.root = root
    }

    public func start() {
        queue.sync {
            guard stream == nil, !stopped else { return }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let flags =
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
            guard
                let made = FSEventStreamCreate(
                    nil, Self.eventsArrived, &context, [root] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                    FSEventStreamCreateFlags(flags))
            else { return }
            FSEventStreamSetDispatchQueue(made, queue)
            FSEventStreamStart(made)
            stream = made
        }
    }

    public func stop() {
        queue.sync {
            // First: removing a subscription withdraws every progress in its
            // folder, and those withdrawals are not copies that stopped.
            stopped = true
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            for folder in folders { Progress.removeSubscriber(folder.token) }
            folders.removeAll()
            published.removeAll()
            generation.removeAll()
        }
    }

    private static let eventsArrived: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let sweeper = Unmanaged<PlaceholderSweeper>.fromOpaque(info).takeUnretainedValue()
        let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        for (index, path) in names.enumerated() where index < count {
            if flags[index] & created != 0, flags[index] & isFile != 0 {
                sweeper.watch(folder: (path as NSString).deletingLastPathComponent)
            }
        }
    }

    /// On the queue.
    private func watch(folder: String) {
        guard !stopped else { return }
        if let index = folders.firstIndex(where: { $0.path == folder }) {
            folders.append(folders.remove(at: index))
            return
        }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let token = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
            guard let self, let path = progress.fileURL?.path else { return nil }
            self.queue.async {
                self.generation[path, default: 0] += 1
                self.published.insert(path)
            }
            return { [weak self] in
                // Read as it is withdrawn: a file the copy reached says so.
                let reached = progress.completedUnitCount > 0
                self?.withdrawn(path, reached: reached)
            }
        }
        folders.append((folder, token))
        evictIdleFolder()
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            self?.lookForAbandoned(in: folder, earlier: [:], looksLeft: 3)
        }
    }

    /// Over the limit, the least recently written folder that nothing is being
    /// copied into stops being watched. It leaves the list before its
    /// subscription goes, so that the withdrawals that causes are ignored.
    private func evictIdleFolder() {
        guard folders.count > Self.folderLimit,
            let index = folders.firstIndex(where: { folder in
                !published.contains { ($0 as NSString).deletingLastPathComponent == folder.path }
            })
        else { return }
        Progress.removeSubscriber(folders.remove(at: index).token)
    }

    private func withdrawn(_ path: String, reached: Bool) {
        queue.async {
            self.published.remove(path)
            let folder = (path as NSString).deletingLastPathComponent
            guard !self.stopped, !reached, self.folders.contains(where: { $0.path == folder }),
                let stamp = Self.changeStamp(path)
            else { return }
            let seen = self.generation[path, default: 0]
            self.queue.asyncAfter(deadline: .now() + Self.settle) {
                guard !self.stopped, self.generation[path, default: 0] == seen,
                    !self.published.contains(path)
                else { return }
                self.generation[path] = nil
                if Self.removeIfPlaceholder(path, unchangedSince: stamp) {
                    Log.mount.notice("removed a file a stopped copy had not reached")
                }
            }
        }
    }

    /// A copy stopped before its folder was subscribed to -- the volume's
    /// events arrive seconds late -- withdrew its progress unseen. Finder keeps
    /// every placeholder of a running copy published, so one that nobody
    /// publishes and that has not changed between two looks `abandoned` apart
    /// belongs to a copy that has stopped.
    private func lookForAbandoned(in folder: String, earlier: [String: ChangeStamp], looksLeft: Int)
    {
        guard !stopped else { return }
        var unsure: [String: ChangeStamp] = [:]
        for path in Self.emptyFiles(in: folder)
        where !published.contains(path) && Self.isPlaceholder(atPath: path) {
            guard let stamp = Self.changeStamp(path) else { continue }
            if earlier[path] == stamp {
                if Self.removeIfPlaceholder(path, unchangedSince: stamp) {
                    Log.mount.notice(
                        "removed a file a copy stopped before it was seen had not reached")
                }
            } else {
                unsure[path] = stamp
            }
        }
        if !unsure.isEmpty, looksLeft > 1 {
            queue.asyncAfter(deadline: .now() + Self.abandoned) { [weak self] in
                self?.lookForAbandoned(in: folder, earlier: unsure, looksLeft: looksLeft - 1)
            }
        }
    }

    static func emptyFiles(in folder: String) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true),
                includingPropertiesForKeys: keys)
        else { return [] }
        return entries.prefix(Self.scanLimit).compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, values.fileSize == 0
            else { return nil }
            return entry.path
        }
    }

    public static func changeStamp(_ path: String) -> ChangeStamp? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return ChangeStamp(
            inode: UInt64(status.st_ino), seconds: Int(status.st_ctimespec.tv_sec),
            nanoseconds: Int(status.st_ctimespec.tv_nsec))
    }

    /// Whether a file is one of Finder's unfilled copy targets: a regular file,
    /// empty, whose FinderInfo marks a copy in progress.
    public static func isPlaceholder(atPath path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size == 0
        else { return false }
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW)
        return read >= 8 && info.prefix(8).elementsEqual("brokMACS".utf8)
    }

    /// Removes the file if it is a placeholder and, when a stamp is given, has
    /// not changed since it was taken, with the AppleDouble companion that
    /// carries its FinderInfo on a volume without extended attributes, should
    /// that outlive it.
    @discardableResult
    public static func removeIfPlaceholder(_ path: String, unchangedSince stamp: ChangeStamp? = nil)
        -> Bool
    {
        guard isPlaceholder(atPath: path) else { return false }
        if let stamp, changeStamp(path) != stamp { return false }
        guard unlink(path) == 0 else { return false }
        let name = (path as NSString).lastPathComponent
        let companion = (path as NSString).deletingLastPathComponent + "/._" + name
        if isAppleDouble(atPath: companion) { unlink(companion) }
        return true
    }

    static func isAppleDouble(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic.elementsEqual([0x00, 0x05, 0x16, 0x07])
    }
}
