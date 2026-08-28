// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// An NTFS volume, behind the seam the extension is written against.
///
/// `FSStoreBacking` serves memory and `FSPassthroughBacking` serves a directory;
/// both exist to measure. This serves the thing the application is for. The
/// volume above it does not change at all, which is what the seam was for.
///
/// **Read-only, and it says so by refusing rather than by pretending.** Every
/// call that would change the volume answers as it would for a disk that cannot
/// be written, so the kernel gets a straight refusal instead of a success that
/// changed nothing. Writing NTFS means allocating clusters, keeping `$Bitmap` in
/// step, growing runlists and journalling to `$LogFile`; until all of that
/// exists, a half-written volume would be worse than a read-only one.
public final class NTFSBacking: FSBacking, @unchecked Sendable {

    /// A handle on a record. FSKit holds one for as long as it is interested in
    /// a file, so it carries the number rather than anything read at the time.
    public final class Handle: FSHandle {
        public let record: UInt64
        /// The name this file was found under. The record itself carries
        /// several and the directory entry knows which one was used.
        public let name: String
        public let isDirectory: Bool

        public init(record: UInt64, name: String, isDirectory: Bool) {
            self.record = record
            self.name = name
            self.isDirectory = isDirectory
            super.init()
        }
    }

    private let reader: NTFSVolumeReader
    private let lock = NSLock()
    /// Listings are re-read rather than cached: a directory read twice in a row
    /// is the common case, but a cache that can go stale on a volume somebody
    /// else is writing is a source of wrong answers rather than of speed.

    public init?(read: @escaping NTFSVolumeReader.ReadBytes) {
        guard let reader = NTFSVolumeReader(read: read) else { return nil }
        self.reader = reader
    }

    public var rootHandle: FSHandle {
        Handle(record: NTFSTable.rootRecord, name: "", isDirectory: true)
    }

    private func ours(_ h: FSHandle) -> Handle? { h as? Handle }

    // MARK: - Attributes

    public func attributes(of handle: FSHandle) -> FSAttributes? {
        guard let handle = ours(handle) else { return nil }
        return lock.withLock {
            guard let record = reader.record(handle.record) else { return nil }
            let size =
                reader.attributes(of: record)
                .first(where: { $0.kind == .data })?.dataSize ?? 0
            let times = reader.times(of: record)
            return FSAttributes(
                id: handle.record,
                // NTFS records do not carry their parent; the name does, and a
                // handle reached through a listing knows where it came from.
                // The root is its own parent, as on any volume.
                parentID: handle.record == NTFSTable.rootRecord
                    ? NTFSTable.rootRecord : NTFSTable.rootRecord,
                isDirectory: record.header.isDirectory,
                size: record.header.isDirectory ? 0 : size,
                // Read-only, and the mode says so rather than the volume
                // accepting a write and losing it.
                mode: record.header.isDirectory ? 0o555 : 0o444,
                linkCount: 1,
                // Real dates, from $STANDARD_INFORMATION. The epoch is a
                // fallback for a record that genuinely has none, which is rare
                // and noticeable -- rather than being every file on the drive,
                // which is what it was a moment ago.
                modified: times?.modified ?? Date(timeIntervalSince1970: 0),
                created: times?.created ?? Date(timeIntervalSince1970: 0))
        }
    }

    public func setMode(_ mode: UInt32, on handle: FSHandle) {
        // Nothing. A read-only volume's permissions are not somebody's to set,
        // and quietly accepting the call would report a change that did not
        // happen.
    }

    // MARK: - Looking around

    public func lookup(_ name: String, in directory: FSHandle) -> FSHandle? {
        guard let directory = ours(directory), directory.isDirectory else { return nil }
        return lock.withLock {
            guard let entries = reader.contents(ofDirectory: directory.record),
                let found = entries.first(where: { $0.name == name })
            else { return nil }
            let isDirectory = reader.record(found.record)?.header.isDirectory ?? false
            return Handle(record: found.record, name: name, isDirectory: isDirectory)
        }
    }

    public func children(of directory: FSHandle) -> [(name: String, handle: FSHandle)] {
        guard let directory = ours(directory), directory.isDirectory else { return [] }
        return lock.withLock {
            guard let entries = reader.contents(ofDirectory: directory.record) else { return [] }
            // NTFS keeps "." in the root's own index. Finder does not want to
            // see a folder inside itself.
            return
                entries
                .filter { $0.name != "." && $0.name != ".." }
                // Sorted, because FSKit resumes an enumeration from an index
                // into this and an order that moves between calls skips files.
                .sorted { $0.name < $1.name }
                .map { entry in
                    let isDirectory = reader.record(entry.record)?.header.isDirectory ?? false
                    return (
                        entry.name,
                        Handle(record: entry.record, name: entry.name, isDirectory: isDirectory)
                            as FSHandle
                    )
                }
        }
    }

    // MARK: - Reading

    public func read(_ handle: FSHandle, offset: Int, length: Int) -> Data {
        guard let handle = ours(handle), !handle.isDirectory, offset >= 0, length > 0 else {
            return Data()
        }
        return lock.withLock {
            reader.contents(ofFile: handle.record, offset: UInt64(offset), length: length) ?? Data()
        }
    }

    // MARK: - Everything that would write

    public func create(_ name: String, isDirectory: Bool, in directory: FSHandle, mode: UInt32)
        -> FSHandle?
    { nil }

    public func remove(_ name: String, from directory: FSHandle) -> FSStore.RemoveOutcome {
        .missing
    }

    public func rename(
        _ name: String, in source: FSHandle, to newName: String, in destination: FSHandle
    ) -> Bool { false }

    public func write(_ handle: FSHandle, contents: Data, offset: Int) -> Int { 0 }

    public func truncate(_ handle: FSHandle, to size: Int) {}

    // MARK: - Extended attributes

    /// None yet. NTFS keeps them in `$EA`, which is a separate attribute and a
    /// separate piece of work; answering "none" is true rather than convenient,
    /// and a volume with no xattrs is a volume macOS handles perfectly well.
    public func xattr(_ name: String, of handle: FSHandle) -> Data? { nil }
    public func xattrNames(of handle: FSHandle) -> [String] { [] }
    public func setXattr(
        _ name: String, to value: Data?, on handle: FSHandle, mustCreate: Bool, mustReplace: Bool
    ) -> FSStore.XattrOutcome { .missing }

    // MARK: - Statistics

    public func usage() -> (files: UInt64, bytes: UInt64) {
        // What the volume holds, not what has been walked. Counting every
        // record would mean reading the whole table to answer statfs, which
        // Finder asks for every time a window opens.
        (0, 0)
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
