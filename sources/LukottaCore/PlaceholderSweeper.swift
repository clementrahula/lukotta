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
    /// Folders subscribed to at once; the least recently written goes first.
    static let folderLimit = 64
    /// How long a withdrawn progress is left before its file is looked at, so
    /// that Finder finishes with the file first.
    static let settle: TimeInterval = 1
    /// How long an unpublished placeholder is left before it counts as one a
    /// stopped copy abandoned.
    static let abandoned: TimeInterval = 5
    /// The most entries of one folder looked at for those.
    static let scanLimit = 10_000

    private let root: String
    /// Files whose progress is published now, which a sweep leaves alone.
    private var published: Set<String> = []
    private let queue = DispatchQueue(label: "com.lukotta.placeholder-sweeper")
    private var stream: FSEventStreamRef?
    private var folders: [(path: String, token: Any)] = []
    /// Bumped each time a file's progress is published, so that a file a new
    /// copy has taken up is left to it.
    private var generation: [String: Int] = [:]

    public init(root: String) {
        self.root = root
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
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
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            for folder in folders { Progress.removeSubscriber(folder.token) }
            folders.removeAll()
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
            return { [weak self] in self?.withdrawn(path) }
        }
        folders.append((folder, token))
        if folders.count > Self.folderLimit {
            Progress.removeSubscriber(folders.removeFirst().token)
        }
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            self?.sweepAbandoned(in: folder, looksLeft: 3)
        }
    }

    /// A copy stopped before its folder was subscribed to -- the volume's
    /// events arrive seconds late -- withdrew its progress unseen. Finder keeps
    /// every placeholder of a running copy published, so one that is not, and
    /// has not changed for a while, belongs to a copy that has stopped.
    private func sweepAbandoned(in folder: String, looksLeft: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .attributeModificationDateKey,
        ]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true),
                includingPropertiesForKeys: keys)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.abandoned)
        var tooRecent = false
        for entry in entries.prefix(Self.scanLimit) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, values.fileSize == 0,
                let changed = values.attributeModificationDate,
                !published.contains(entry.path)
            else { continue }
            if changed >= cutoff {
                tooRecent = tooRecent || Self.isPlaceholder(atPath: entry.path)
            } else if Self.removeIfPlaceholder(entry.path) {
                Log.mount.notice("removed a file a copy stopped before it was seen had not reached")
            }
        }
        // Too recent to tell from a copy starting: looked at again once they are not.
        if tooRecent, looksLeft > 1 {
            queue.asyncAfter(deadline: .now() + Self.abandoned) { [weak self] in
                self?.sweepAbandoned(in: folder, looksLeft: looksLeft - 1)
            }
        }
    }

    private func withdrawn(_ path: String) {
        queue.async {
            self.published.remove(path)
            let seen = self.generation[path, default: 0]
            self.queue.asyncAfter(deadline: .now() + Self.settle) {
                guard self.generation[path, default: 0] == seen else { return }
                self.generation[path] = nil
                if Self.removeIfPlaceholder(path) {
                    Log.mount.notice("removed a file a stopped copy had not reached")
                }
            }
        }
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

    /// Removes the file if it is a placeholder, with the AppleDouble companion
    /// that carries its FinderInfo on a volume without extended attributes,
    /// should that outlive it.
    @discardableResult
    public static func removeIfPlaceholder(_ path: String) -> Bool {
        guard isPlaceholder(atPath: path), unlink(path) == 0 else { return false }
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
