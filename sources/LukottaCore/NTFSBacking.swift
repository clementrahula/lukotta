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

    /// Whether the volume underneath could be written to, if there were a
    /// write path. Nothing consults it to allow a write -- there are none --
    /// but a drive Windows left mid-write must never become writable by
    /// somebody later adding one and not knowing to ask.
    public let volumeIsSafeToWrite: Bool

    /// What the volume calls itself, which is what Finder puts on the desktop.
    public let volumeLabel: String?

    /// Putting bytes on the device, where the caller can do that at all.
    ///
    /// Separate from reading and optional, so that a volume opened without one
    /// cannot write by accident: the absence of a function is a stronger
    /// guarantee than a flag somebody has to check.
    public typealias WriteBytes = @Sendable (_ offset: UInt64, _ bytes: Data) -> Bool

    private let writeBytes: WriteBytes?

    public init?(
        read: @escaping NTFSVolumeReader.ReadBytes,
        write: WriteBytes? = nil
    ) {
        guard let reader = NTFSVolumeReader(read: read) else { return nil }
        self.reader = reader
        self.writeBytes = write
        let state = reader.state()
        self.volumeIsSafeToWrite = state?.isSafeToWrite ?? false
        self.volumeLabel = state?.label
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
            // Through the tree rather than by listing the directory: the
            // entries are sorted, so each node says where to look next. On a
            // folder of a hundred thousand files, listing it to open one file
            // is what makes a window hang.
            guard let record = reader.find(name, inDirectory: directory.record) else {
                return nil
            }
            let isDirectory = reader.record(record)?.header.isDirectory ?? false
            return Handle(record: record, name: name, isDirectory: isDirectory)
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
                // NTFS's own metadata files -- $MFT, $Bitmap, $LogFile and the
                // rest -- live in the root directory of every volume. Windows
                // does not show them and neither should this: a drive that
                // opens with a dozen dollar-signed files in it looks broken,
                // and deleting one would be worse than looking broken.
                //
                // They are the reserved records, 0 to 15, plus $Extend. Hidden
                // by number rather than by name, because a file somebody made
                // and called $MFT is theirs and should be shown.
                .filter { $0.record >= NTFSTable.reservedRecords || $0.name == "." }
                .filter { $0.name != "$Extend" }
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

    /// Write into clusters the file already owns.
    ///
    /// Everything that would change the volume's structure is refused, so this
    /// answers zero far more often than it writes. Zero is the honest answer:
    /// the caller learns nothing was stored rather than being told a write
    /// succeeded that did not.
    public func write(_ handle: FSHandle, contents: Data, offset: Int) -> Int {
        guard let writeBytes,
            let handle = ours(handle), !handle.isDirectory,
            offset >= 0, !contents.isEmpty
        else { return 0 }

        return lock.withLock {
            guard volumeIsSafeToWrite,
                let record = reader.record(handle.record),
                !reader.spillsAttributes(record),
                let data = reader.attributes(of: record).first(where: { $0.kind == .data }),
                NTFSFileWrite.isAllowed(
                    attribute: data, volumeIsClean: true, volumeIsWritable: true),
                let runs = NTFSRunlist.decode(
                    record.data, at: data.runlistOffset, limit: record.data.count),
                let pieces = NTFSFileWrite.pieces(
                    offset: UInt64(offset), length: contents.count, runs: runs,
                    bytesPerCluster: reader.geometry.bytesPerCluster, size: data.dataSize)
            else { return 0 }

            // All or nothing. A write that stores some pieces and fails on a
            // later one leaves a file half old and half new with nobody told,
            // so a failure part way through is still reported as bytes written
            // -- the caller cannot unwrite them, but it must not be told they
            // did not happen.
            var written = 0
            for piece in pieces {
                let slice = contents[
                    contents.startIndex + piece.range.lowerBound..<contents.startIndex
                        + piece.range.upperBound]
                guard writeBytes(piece.diskOffset, Data(slice)) else { break }
                written += piece.range.count
            }
            return written
        }
    }

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
        // Real numbers, from $Bitmap. Reporting zero used on a full drive is
        // what Finder shows in Get Info and beside every window, and a volume
        // that claims to be empty when it is not invites somebody to copy onto
        // it until the write fails.
        //
        // The file count is not answered: knowing it means reading the whole
        // master file table, and Finder does not show it anywhere.
        lock.withLock {
            guard let space = reader.spaceInUse() else { return (0, 0) }
            return (0, space.used)
        }
    }

    /// How large the volume is, which statfs needs beside what is used.
    public var capacityInBytes: UInt64 {
        lock.withLock { reader.spaceInUse()?.total ?? 0 }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
