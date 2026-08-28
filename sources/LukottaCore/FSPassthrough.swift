// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A tree that is somewhere else.
///
/// `FSStore` holds its files in memory, which prices the framework and nothing
/// more. This one keeps them in a real directory and reaches it with ordinary
/// POSIX calls, which is what makes it useful for two things memory cannot do:
///
/// 1. **It measures the write path against a backing store that is not the
///    bottleneck.** The open question after tonight is what an FSKit create
///    costs when the filesystem behind it is fast. Apple's msdos module answers
///    1686 us, but FAT32 walks an allocation chain and scans a linear directory
///    to make a file, so that number is about FAT. A create straight onto APFS
///    costs 64 us, so anything above that, served through this, is the
///    framework's own.
/// 2. **It is the shape of the real thing.** §3 of architecture.md puts an
///    FSKit module in front and something remote behind it -- a guest holding
///    the NTFS volume, reached over a socket. A host directory is the simplest
///    possible stand-in for "behind", and every operation the module needs is
///    exercised against it exactly as it would be against the real backend.
///
/// What it is not is a filesystem for anybody to use: it is a second view of a
/// directory that already exists, so two things writing to it will confuse each
/// other. It exists to be measured and to prove the operations.
public final class FSPassthrough: @unchecked Sendable {

    /// Where the real files are.
    public let root: URL

    /// Identifiers have to be stable for as long as FSKit holds an item, and
    /// they have to survive a rename, so they cannot be derived from the path.
    /// The inode number of the file underneath is exactly the right thing: it
    /// is what the backing filesystem already uses for the same purpose.
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    /// A file, named by where it is rather than by holding its contents.
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let id: UInt64
        public let isDirectory: Bool
        public let size: UInt64
        public let mode: UInt32
        public let modified: Date
        public let created: Date
        public let linkCount: UInt32
    }

    private func entry(at url: URL) -> Entry? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
        return Entry(
            url: url,
            // The inode, which is stable across a rename and unique on the
            // volume -- the two things an FSItem identifier has to be.
            id: UInt64(status.st_ino),
            isDirectory: isDirectory,
            size: UInt64(status.st_size),
            mode: UInt32(status.st_mode & 0o7777),
            modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)),
            created: Date(timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec)),
            linkCount: UInt32(status.st_nlink))
    }

    public func rootEntry() -> Entry? { entry(at: root) }

    // MARK: - Lookup and enumeration

    /// A name is one path component and never a path.
    ///
    /// The kernel passes what somebody typed, and a name carrying a slash or
    /// `..` would reach outside the volume entirely -- the whole of a directory
    /// traversal, in a process that answers the filesystem. Refused here rather
    /// than trusted, because there is exactly one place to refuse it.
    public static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    public func lookup(_ name: String, in directory: Entry) -> Entry? {
        guard Self.isSafe(name) else { return nil }
        return entry(at: directory.url.appendingPathComponent(name))
    }

    public func children(of directory: Entry) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.url.path)) ?? []
        // Sorted, because FSKit resumes an enumeration from a cookie that is an
        // index into this. An order that moves between calls skips entries.
        return names.sorted().compactMap { lookup($0, in: directory) }
    }

    // MARK: - Changing things

    public func create(
        _ name: String, isDirectory: Bool, in directory: Entry, mode: UInt32
    ) -> Entry? {
        guard Self.isSafe(name) else { return nil }
        let url = directory.url.appendingPathComponent(name)
        if isDirectory {
            guard mkdir(url.path, mode_t(mode)) == 0 else { return nil }
        } else {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(mode))
            guard fd >= 0 else { return nil }
            close(fd)
        }
        return entry(at: url)
    }

    public func remove(_ name: String, from directory: Entry) -> FSStore.RemoveOutcome {
        guard Self.isSafe(name) else { return .missing }
        let url = directory.url.appendingPathComponent(name)
        guard let target = entry(at: url) else { return .missing }
        let failed = target.isDirectory ? rmdir(url.path) != 0 : unlink(url.path) != 0
        guard failed else { return .removed }
        return errno == ENOTEMPTY ? .notEmpty : .missing
    }

    public func rename(
        _ name: String, in source: Entry, to newName: String, in destination: Entry
    ) -> Bool {
        guard Self.isSafe(name), Self.isSafe(newName) else { return false }
        return Darwin.rename(
            source.url.appendingPathComponent(name).path,
            destination.url.appendingPathComponent(newName).path) == 0
    }

    // MARK: - Contents

    public func read(_ file: Entry, offset: Int, length: Int) -> Data {
        let fd = open(file.url.path, O_RDONLY)
        guard fd >= 0 else { return Data() }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes {
            pread(fd, $0.baseAddress, length, off_t(offset))
        }
        guard read > 0 else { return Data() }
        return Data(buffer.prefix(read))
    }

    public func write(_ file: Entry, contents: Data, offset: Int) -> Int {
        let fd = open(file.url.path, O_WRONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let written = contents.withUnsafeBytes {
            pwrite(fd, $0.baseAddress, contents.count, off_t(offset))
        }
        return max(0, written)
    }

    public func truncate(_ file: Entry, to size: Int) {
        _ = Darwin.truncate(file.url.path, off_t(size))
    }

    // MARK: - Extended attributes

    /// Answered natively, which is the point: a volume that cannot hold an
    /// xattr gets an AppleDouble `._name` file beside every file on it, because
    /// macOS puts `com.apple.provenance` on everything it creates.
    public func xattr(_ name: String, of file: Entry) -> Data? {
        let size = getxattr(file.url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes {
            getxattr(file.url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    public func xattrNames(of file: Entry) -> [String] {
        let size = listxattr(file.url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(file.url.path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer.prefix(read)
            .split(separator: 0)
            .compactMap { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            .sorted()
    }

    public func setXattr(
        _ name: String, to value: Data?, on file: Entry,
        mustCreate: Bool = false, mustReplace: Bool = false
    ) -> FSStore.XattrOutcome {
        guard let value else {
            return removexattr(file.url.path, name, XATTR_NOFOLLOW) == 0 ? .set : .missing
        }
        var options: Int32 = XATTR_NOFOLLOW
        if mustCreate { options |= XATTR_CREATE }
        if mustReplace { options |= XATTR_REPLACE }
        let set = value.withUnsafeBytes {
            setxattr(file.url.path, name, $0.baseAddress, value.count, 0, options)
        }
        guard set != 0 else { return .set }
        return errno == EEXIST ? .exists : .missing
    }

    // MARK: - Statistics

    public func usage() -> (files: UInt64, bytes: UInt64) {
        var files: UInt64 = 0
        var bytes: UInt64 = 0
        guard let walk = FileManager.default.enumerator(atPath: root.path) else {
            return (0, 0)
        }
        for case let name as String in walk {
            files += 1
            var status = stat()
            if lstat(root.appendingPathComponent(name).path, &status) == 0 {
                bytes += UInt64(status.st_size)
            }
        }
        return (files, bytes)
    }
}
