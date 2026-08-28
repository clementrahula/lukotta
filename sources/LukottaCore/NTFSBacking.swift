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

    /// The volume's shape. A caller checking what was written needs it, and
    /// working it out a second time somewhere else is how a checker ends up
    /// looking at a different place than the writer wrote to.
    public var geometry: NTFSGeometry { reader.geometry }

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

    // MARK: - Holding the volume

    /// Whether the dirty flag is currently ours.
    ///
    /// Only ever changed under `lock`, because two threads both deciding they
    /// are the first writer would write `$Volume` twice, and the second write
    /// would race the first.
    private var marked = false

    /// Whether this volume has been marked as ours.
    public var isMarked: Bool { lock.withLock { marked } }

    /// Set `$Volume`'s dirty flag, once, before the first write.
    ///
    /// **A write that cannot mark the volume does not happen.** Without the
    /// mark, a crash part way through leaves a volume Windows believes is
    /// clean, and it will mount it and trust structures that were being
    /// changed. Refusing the write costs somebody a copy that did not happen;
    /// not refusing it costs them the volume.
    ///
    /// The table copy goes first. Between the two writes the flag is already
    /// on where a mount reads it, so a crash in that gap is a volume that says
    /// it needs checking -- which it does.
    ///
    /// Must be called with `lock` held.
    private func markLocked() -> Bool {
        if marked { return true }
        guard let record = reader.record(NTFSVolumeState.volumeRecord) else { return false }
        let attributes = reader.attributes(of: record)
        guard let state = NTFSVolumeState.read(record: record.data, attributes: attributes),
            state.isSafeToWrite,
            let dirtied = NTFSVolumeState.setting(
                dirty: true, in: record.data, attributes: attributes),
            writeRecordLocked(
                NTFSVolumeState.volumeRecord, dirtied, header: record.header,
                mirrorLast: true)
        else { return false }
        marked = true
        return true
    }

    /// Clear the flag, and only on the way out.
    ///
    /// The mirror goes first here, so the table's copy is the last thing to
    /// change. At every instant in between, the flag a mount reads is still
    /// set -- a crash in the gap leaves a volume that says it needs checking,
    /// never one that says it is clean while a copy of its own metadata
    /// disagrees.
    ///
    /// - Returns: false when the flag could not be cleared, which leaves the
    ///   volume marked. That is the safe direction to fail in: chkdsk runs
    ///   once for nothing.
    @discardableResult
    public func release() -> Bool {
        lock.withLock {
            guard marked else { return true }
            guard let record = reader.record(NTFSVolumeState.volumeRecord) else { return false }
            let attributes = reader.attributes(of: record)
            guard
                let cleaned = NTFSVolumeState.setting(
                    dirty: false, in: record.data, attributes: attributes),
                writeRecordLocked(
                    NTFSVolumeState.volumeRecord, cleaned, header: record.header,
                    mirrorLast: false)
            else { return false }
            marked = false
            return true
        }
    }

    /// Put a record back everywhere it lives.
    ///
    /// - Parameter mirrorLast: which copy is written second. Whichever it is,
    ///   the other one is what a reader between the two writes sees, so the
    ///   order is chosen by what that reader should conclude.
    ///
    /// Must be called with `lock` held.
    private func writeRecordLocked(
        _ number: UInt64, _ data: Data, header: NTFSRecord.Header, mirrorLast: Bool
    ) -> Bool {
        guard let writeBytes,
            let tableOffset = reader.diskOffset(ofRecord: number),
            let mirrorLength = reader.size(ofFile: NTFSRecordWrite.mirrorRecord),
            let bytes = NTFSRecordWrite.onDisk(
                data, header: header, sectorSize: reader.geometry.bytesPerSector),
            var places = NTFSRecordWrite.destinations(
                record: number, tableOffset: tableOffset,
                mirrorOffset: reader.geometry.mftMirrorStartCluster
                    * UInt64(reader.geometry.bytesPerCluster),
                mirrorLength: mirrorLength,
                bytesPerFileRecord: reader.geometry.bytesPerFileRecord)
        else { return false }

        if !mirrorLast { places.reverse() }
        for place in places {
            guard writeBytes(place.offset, bytes) else { return false }
        }
        return true
    }

    // MARK: - Everything that would write

    /// Make a file.
    ///
    /// Three structures change and they must agree: `$MFT`'s `$BITMAP` says the
    /// record is taken, the record itself describes the file, and the parent's
    /// index carries the name. Without a journal none of that can be made
    /// atomic, so the order is chosen so that **every interrupted state is a
    /// leak and never a dangling reference.**
    ///
    /// 1. The bitmap bit. A crash here loses one record slot until chkdsk runs,
    ///    and nothing points anywhere.
    /// 2. The record. A crash here leaves a record nothing refers to -- an
    ///    orphan, which chkdsk either frees or files under found.000.
    /// 3. The index entry. Once this lands the file exists.
    ///
    /// The other order -- name first -- would put a name in a directory
    /// pointing at a record that is not a file. That is a directory somebody
    /// opens and gets an error from, or worse, a different file.
    ///
    /// Directories are not made here yet: a directory needs an index of its
    /// own, and the entries of a new one are not the same problem as an entry
    /// in an existing one.
    public func create(_ name: String, isDirectory: Bool, in directory: FSHandle, mode: UInt32)
        -> FSHandle?
    {
        guard writeBytes != nil, !isDirectory, !name.isEmpty,
            let parent = ours(directory), parent.isDirectory
        else { return nil }

        return lock.withLock {
            guard volumeIsSafeToWrite, markLocked(), let collation = reader.collation() else {
                return nil
            }
            // A name already in the directory is not made again. NTFS has one
            // entry per name, and a second is a file that lists twice and
            // deletes once.
            guard reader.find(name, inDirectory: parent.record) == nil else { return nil }

            guard let parentRecord = reader.record(parent.record),
                let bitmap = reader.contents(
                    ofFile: NTFSTable.mftRecord, attribute: .bitmap),
                let tableSize = reader.size(ofFile: NTFSTable.mftRecord)
            else { return nil }
            let records = tableSize / UInt64(reader.geometry.bytesPerFileRecord)
            guard let choice = NTFSRecordAllocator.choose(in: bitmap, recordCount: records) else {
                // No free record. The table has to grow, which is an allocation
                // and a runlist change, and is not here. Nil is "no room".
                return nil
            }

            // Permissions are the parent's. NTFS keeps them in $Secure and
            // records only the entry number; inventing one would be inventing
            // permissions, and copying the parent is what every implementation
            // that writes NTFS does.
            let security = securityID(of: parentRecord) ?? 0
            let now = Date()
            let plan = NTFSNewRecord.Plan(
                record: choice.record,
                sequence: reader.nextSequence(forRecord: choice.record),
                parent: parent.record,
                parentSequence: sequenceOf(parentRecord),
                name: name, namespace: .posix,
                times: NTFSTimestamps.Times(
                    created: now, modified: now, recordChanged: now, accessed: now),
                securityID: security)
            guard
                let composed = NTFSNewRecord.compose(
                    plan, recordSize: reader.geometry.bytesPerFileRecord,
                    sectorSize: reader.geometry.bytesPerSector),
                let header = NTFSRecord.header(
                    composed, expectedLength: reader.geometry.bytesPerFileRecord),
                let key = NTFSIndexWrite.entry(
                    key: NTFSNewRecord.fileNameValue(plan, units: Array(name.utf16)),
                    record: choice.record, sequence: plan.sequence)
            else { return nil }

            // Find the node the name belongs in before anything is written. A
            // directory with no room in the right node needs a split, and
            // finding that out after the record is on the disk means an orphan
            // for no reason.
            guard let node = leafNode(of: parent.record, for: name, collation: collation),
                node.room >= key.count
            else { return nil }

            // 1. The bitmap.
            guard
                writeAttributeLocked(
                    record: NTFSTable.mftRecord, attribute: .bitmap, contents: choice.bitmap,
                    changedFrom: bitmap)
            else { return nil }

            // 2. The record.
            guard writeRecordLocked(choice.record, composed, header: header, mirrorLast: true)
            else { return nil }

            // 3. The name.
            guard
                let spliced = NTFSIndexWrite.inserting(
                    entry: key, into: node.bytes, nodeHeaderAt: node.headerOffset,
                    collation: collation),
                writeIndexBlockLocked(spliced, at: node.diskOffset)
            else { return nil }

            return Handle(record: choice.record, name: name, isDirectory: false)
        }
    }

    /// Which entry of `$Secure` a record points at.
    private func securityID(of record: (data: Data, header: NTFSRecord.Header)) -> UInt32? {
        guard
            let information = reader.attributes(of: record).first(where: {
                $0.kind == .standardInformation
            }), information.isResident, information.valueLength >= 56
        else { return nil }
        let at = record.data.startIndex + information.valueOffset + 52
        guard at + 3 < record.data.endIndex else { return nil }
        var value: UInt32 = 0
        for byte in 0..<4 { value |= UInt32(record.data[at + byte]) << (8 * UInt32(byte)) }
        return value
    }

    private func sequenceOf(_ record: (data: Data, header: NTFSRecord.Header)) -> UInt16 {
        guard record.data.count > 0x11 else { return 1 }
        let at = record.data.startIndex
        return UInt16(record.data[at + 0x10]) | (UInt16(record.data[at + 0x11]) << 8)
    }

    /// One index block, ready to be spliced.
    private struct Leaf {
        let bytes: Data
        let headerOffset: Int
        let diskOffset: UInt64
        let blockSize: Int
        let room: Int
    }

    /// Walk down to the node a name belongs in.
    ///
    /// The same descent a search does, and it has to be: a name filed anywhere
    /// but where the search would look for it is a name nothing finds.
    ///
    /// Must be called with `lock` held.
    private func leafNode(of directory: UInt64, for name: String, collation: NTFSCollation)
        -> Leaf?
    {
        guard let record = reader.record(directory), record.header.isDirectory else { return nil }
        let attributes = reader.attributes(of: record)
        guard let indexRoot = attributes.first(where: { $0.kind == .indexRoot }),
            indexRoot.isResident
        else { return nil }

        var blockSize = 0
        let value = record.data.startIndex + indexRoot.valueOffset
        guard value + 16 <= record.data.endIndex else { return nil }
        for byte in 0..<4 { blockSize |= Int(record.data[value + 8 + byte]) << (8 * byte) }
        guard blockSize >= 512 else { return nil }

        let node = indexRoot.valueOffset + 16
        guard let first = NTFSIndex.firstEntryOffset(nodeHeader: record.data, at: node) else {
            return nil
        }
        let rootEntries = NTFSIndex.entries(
            record.data, from: first,
            limit: min(indexRoot.valueOffset + indexRoot.valueLength, record.data.count))
        var step = NTFSIndex.find(name, in: rootEntries, collation: collation)
        guard case .descend(var block) = step else {
            // The whole index lives inside the record, which means growing a
            // resident attribute -- a record rewrite, and not this.
            return nil
        }

        guard let allocation = attributes.first(where: { $0.kind == .indexAllocation }),
            !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return nil }

        // A tree this deep is a tree that is not a tree. The bound stops a
        // cycle in a damaged index from being followed for ever.
        for _ in 0..<32 {
            guard
                let placed = NTFSTable.diskOffset(
                    forFileOffset: block * UInt64(blockSize), runs: runs,
                    bytesPerCluster: reader.geometry.bytesPerCluster),
                let raw = reader.read(placed.offset, blockSize),
                let blockHeader = NTFSIndexBlock.header(raw, blockSize: blockSize),
                let bytes = NTFSIndexBlock.applyFixup(
                    raw, header: blockHeader, sectorSize: reader.geometry.bytesPerSector)
            else { return nil }

            let entries = NTFSIndex.entries(
                bytes, from: blockHeader.firstEntryOffset, limit: blockHeader.endOfEntries)
            step = NTFSIndex.find(name, in: entries, collation: collation)
            switch step {
            case .descend(let next):
                block = next
            case .found:
                // Already there. The caller checked, so this is a directory
                // changing under us.
                return nil
            case .absent:
                guard
                    let room = NTFSIndexWrite.room(
                        of: bytes, nodeHeaderAt: NTFSIndexBlock.nodeHeaderOffset)
                else { return nil }
                return Leaf(
                    bytes: bytes, headerOffset: NTFSIndexBlock.nodeHeaderOffset,
                    diskOffset: placed.offset, blockSize: blockSize, room: room.free)
            }
        }
        return nil
    }

    /// Write an index block back, with its fixup put on and its signature moved
    /// on.
    ///
    /// Must be called with `lock` held.
    private func writeIndexBlockLocked(_ bytes: Data, at offset: UInt64) -> Bool {
        guard let writeBytes,
            let header = NTFSIndexBlock.header(bytes, blockSize: bytes.count),
            let onDisk = NTFSIndexBlock.removeFixup(
                bytes, header: header, sectorSize: reader.geometry.bytesPerSector)
        else { return false }
        return writeBytes(offset, onDisk)
    }

    /// Write the changed part of a non-resident attribute.
    ///
    /// Only the bytes that differ, and only in whole sectors around them: a
    /// bitmap is megabytes on a large volume and rewriting all of it to set one
    /// bit would take a second and put every one of those bytes at risk.
    ///
    /// Must be called with `lock` held.
    private func writeAttributeLocked(
        record number: UInt64, attribute kind: NTFSAttribute.Kind, contents: Data,
        changedFrom previous: Data
    ) -> Bool {
        guard let writeBytes, contents.count == previous.count,
            let record = reader.record(number),
            let attribute = reader.attributes(of: record).first(where: { $0.kind == kind }),
            !attribute.isResident, attribute.isReadableAsIs,
            let runs = NTFSRunlist.decode(
                record.data, at: attribute.runlistOffset, limit: record.data.count)
        else { return false }

        let sector = reader.geometry.bytesPerSector
        guard sector > 0 else { return false }
        var changed: Set<Int> = []
        for index in 0..<contents.count
        where contents[contents.startIndex + index] != previous[previous.startIndex + index] {
            changed.insert(index / sector)
        }
        guard !changed.isEmpty else { return true }

        for block in changed.sorted() {
            let from = block * sector
            let slice = contents[
                contents.startIndex
                    + from..<min(contents.endIndex, contents.startIndex + from + sector)]
            guard
                let pieces = NTFSFileWrite.pieces(
                    offset: UInt64(from), length: slice.count, runs: runs,
                    bytesPerCluster: reader.geometry.bytesPerCluster, size: attribute.dataSize)
            else { return false }
            for piece in pieces {
                let part = slice[
                    slice.startIndex + piece.range.lowerBound..<slice.startIndex
                        + piece.range.upperBound]
                guard writeBytes(piece.diskOffset, Data(part)) else { return false }
            }
        }
        return true
    }

    /// Take a file away.
    ///
    /// The reverse of create, in the reverse order, for the same reason: every
    /// interrupted state has to be a leak rather than a dangling reference.
    ///
    /// 1. The name comes out of the directory. From here on nothing refers to
    ///    the file, and a crash leaves an orphan record and some clusters
    ///    nobody owns -- space, which chkdsk reclaims.
    /// 2. The record is marked free and its sequence moved on, so a reference
    ///    made to it before now is recognised as stale rather than followed to
    ///    whatever takes the slot next.
    /// 3. The bitmap bit goes back, and the record can be reused.
    ///
    /// **Nothing is overwritten.** A deleted file's record and clusters keep
    /// their contents until something else takes them, which is exactly what
    /// makes recovery possible -- and this application exists to recover
    /// things.
    ///
    /// Directories are refused: an empty one still has an index of its own to
    /// take apart, and a directory with anything in it must not go at all.
    public func remove(_ name: String, from directory: FSHandle) -> FSStore.RemoveOutcome {
        guard writeBytes != nil, let parent = ours(directory), parent.isDirectory else {
            return .missing
        }
        return lock.withLock {
            guard volumeIsSafeToWrite, let collation = reader.collation() else { return .missing }
            guard let number = reader.find(name, inDirectory: parent.record),
                let record = reader.record(number)
            else { return .missing }
            guard !record.header.isDirectory else { return .notEmpty }
            guard markLocked() else { return .missing }

            guard let leaf = nodeHolding(name, in: parent.record, collation: collation) else {
                return .missing
            }

            // 1. The name.
            guard
                let spliced = NTFSIndexWrite.removing(
                    name: name, from: leaf.bytes, nodeHeaderAt: leaf.headerOffset,
                    collation: collation),
                writeIndexBlockLocked(spliced, at: leaf.diskOffset)
            else { return .missing }

            // 2. The record. The in-use flag goes off and the sequence moves
            // on; the attributes stay exactly where they are, because a record
            // that still describes its file is a file that can be recovered.
            var freed = [UInt8](record.data)
            let base = record.data.startIndex
            let flags = UInt16(freed[base + 0x16]) | (UInt16(freed[base + 0x17]) << 8)
            let cleared = flags & ~UInt16(0x0001)
            freed[base + 0x16] = UInt8(cleared & 0xFF)
            freed[base + 0x17] = UInt8(cleared >> 8)
            let sequence = UInt16(freed[base + 0x10]) | (UInt16(freed[base + 0x11]) << 8)
            let next = NTFSRecord.nextSignature(after: sequence)
            freed[base + 0x10] = UInt8(next & 0xFF)
            freed[base + 0x11] = UInt8(next >> 8)
            guard
                writeRecordLocked(
                    number, Data(freed), header: record.header, mirrorLast: true)
            else { return .missing }

            // 3. The bitmap.
            guard let bitmap = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap),
                let tableSize = reader.size(ofFile: NTFSTable.mftRecord),
                let released = NTFSRecordAllocator.releasing(
                    number, in: bitmap,
                    recordCount: tableSize / UInt64(reader.geometry.bytesPerFileRecord)),
                writeAttributeLocked(
                    record: NTFSTable.mftRecord, attribute: .bitmap, contents: released,
                    changedFrom: bitmap)
            else { return .missing }

            return .removed
        }
    }

    /// The node a name is actually in.
    ///
    /// The same descent as `leafNode`, stopping when the name is found rather
    /// than when it is not.
    ///
    /// Must be called with `lock` held.
    private func nodeHolding(_ name: String, in directory: UInt64, collation: NTFSCollation)
        -> Leaf?
    {
        guard let record = reader.record(directory), record.header.isDirectory,
            let indexRoot = reader.attributes(of: record).first(where: { $0.kind == .indexRoot }),
            indexRoot.isResident
        else { return nil }

        var blockSize = 0
        let value = record.data.startIndex + indexRoot.valueOffset
        guard value + 16 <= record.data.endIndex else { return nil }
        for byte in 0..<4 { blockSize |= Int(record.data[value + 8 + byte]) << (8 * byte) }
        guard blockSize >= 512 else { return nil }

        let node = indexRoot.valueOffset + 16
        guard let first = NTFSIndex.firstEntryOffset(nodeHeader: record.data, at: node) else {
            return nil
        }
        let rootEntries = NTFSIndex.entries(
            record.data, from: first,
            limit: min(indexRoot.valueOffset + indexRoot.valueLength, record.data.count))
        guard
            case .descend(var block) = NTFSIndex.find(
                name, in: rootEntries, collation: collation)
        else { return nil }

        guard
            let allocation = reader.attributes(of: record).first(where: {
                $0.kind == .indexAllocation
            }), !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return nil }

        for _ in 0..<32 {
            guard
                let placed = NTFSTable.diskOffset(
                    forFileOffset: block * UInt64(blockSize), runs: runs,
                    bytesPerCluster: reader.geometry.bytesPerCluster),
                let raw = reader.read(placed.offset, blockSize),
                let blockHeader = NTFSIndexBlock.header(raw, blockSize: blockSize),
                let bytes = NTFSIndexBlock.applyFixup(
                    raw, header: blockHeader, sectorSize: reader.geometry.bytesPerSector),
                let room = NTFSIndexWrite.room(
                    of: bytes, nodeHeaderAt: NTFSIndexBlock.nodeHeaderOffset)
            else { return nil }

            let entries = NTFSIndex.entries(
                bytes, from: blockHeader.firstEntryOffset, limit: blockHeader.endOfEntries)
            switch NTFSIndex.find(name, in: entries, collation: collation) {
            case .descend(let next): block = next
            case .absent: return nil
            case .found:
                return Leaf(
                    bytes: bytes, headerOffset: NTFSIndexBlock.nodeHeaderOffset,
                    diskOffset: placed.offset, blockSize: blockSize, room: room.free)
            }
        }
        return nil
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
            // Nothing is written to a volume that does not carry our mark. See
            // markLocked: the mark is what makes a crash recoverable, and a
            // write without it is a write onto a volume Windows will trust.
            guard volumeIsSafeToWrite, markLocked(),
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
