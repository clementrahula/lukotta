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
        if let mine = ours(directory) {
            let cached: [(name: String, handle: FSHandle)]? = lock.withLock {
                listedDirectory == mine.record ? listedEntries : nil
            }
            if let cached { return cached }
            let fresh = childrenUncached(of: directory)
            lock.withLock {
                listedDirectory = mine.record
                listedEntries = fresh
            }
            return fresh
        }
        return childrenUncached(of: directory)
    }

    private func childrenUncached(of directory: FSHandle) -> [(name: String, handle: FSHandle)] {
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

    /// The volume's cluster bitmap and `$MFT`'s record bitmap, kept while the
    /// volume is marked.
    ///
    /// Both are read and written on every create, remove and growing write, and
    /// on a four-gigabyte volume the cluster one is 128 KB -- read, compared
    /// byte by byte against the new version, and read again next time. That is
    /// a quarter of the cost of writing a megabyte.
    ///
    /// **Caching them is only safe because the mark says so.** While `$Volume`
    /// carries our dirty flag, nothing else is writing this volume: that is
    /// what the flag means, and what every other implementation relies on. The
    /// cache is dropped when the volume is released, so a second mount reads
    /// them fresh.
    private var clusterBitmap: Data?
    private var recordBitmap: Data?

    /// The last directory listed, kept for as long as nothing is written.
    ///
    /// **An enumeration asks for a directory one page at a time**, and each
    /// page used to sweep every block of it again: 6.7 milliseconds and 256
    /// reads for five thousand names, once per page. Fifty pages is a third of
    /// a second for one listing, and a directory of a million files would take
    /// hours -- the cost is quadratic in the number of names, and it is exactly
    /// the case this is meant to handle.
    ///
    /// One directory is enough, because that is how an enumeration goes:
    /// straight through one directory, page after page. Anything that writes
    /// throws it away, so a listing can never show what a write has changed --
    /// which is the only thing a cache of this shape can get wrong.
    private var listedDirectory: UInt64?
    private var listedEntries: [(name: String, handle: FSHandle)] = []

    /// Everything that writes calls this. Forgetting to is a listing that shows
    /// a file somebody deleted.
    private func forgetListing() {
        listedDirectory = nil
        listedEntries = []
    }

    /// Where the last record was found, so the next search starts there.
    ///
    /// Without it every create scans the record bitmap from the first
    /// available slot, and on a volume with fifty thousand records in use that
    /// is fifty thousand bits per file -- which is nearly all the time a create
    /// takes. The hint is only a hint: the search falls back to the beginning,
    /// so a wrong one costs a scan and never a wrong answer.
    private var recordHint: UInt64 = NTFSRecordAllocator.firstAvailable

    /// Why the last split or deepening gave up. For diagnosis only; nothing
    /// reads it to decide anything.
    private var lastGrief = ""
    public var whyTheTreeWouldNotGrow: String { lock.withLock { lastGrief } }

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
            clusterBitmap = nil
            recordBitmap = nil
            return true
        }
    }

    /// `$MFT`'s record bitmap, read once while the volume is ours.
    ///
    /// Must be called with `lock` held.
    private func recordBitmapLocked() -> Data? {
        if let recordBitmap { return recordBitmap }
        let read = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap)
        recordBitmap = read
        return read
    }

    /// The volume's cluster bitmap, likewise.
    ///
    /// Must be called with `lock` held.
    private func clusterBitmapLocked() -> Data? {
        if let clusterBitmap { return clusterBitmap }
        let read = reader.contents(ofFile: NTFSVolumeReader.bitmapRecord)
        clusterBitmap = read
        return read
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
        guard writeBytes != nil, !name.isEmpty,
            let parent = ours(directory), parent.isDirectory
        else { return nil }

        return lock.withLock { () -> FSHandle? in
            guard volumeIsSafeToWrite, markLocked(), let collation = reader.collation() else {
                return nil
            }
            // The descent that finds the leaf also answers whether the name is
            // already there: it stops at the entry when it is. Two descents
            // gave the same answer twice and cost the same twice.
            guard let parentRecord = reader.record(parent.record),
                let bitmap = recordBitmapLocked(),
                let tableSize = reader.size(ofFile: NTFSTable.mftRecord)
            else { return nil }
            let records = tableSize / UInt64(reader.geometry.bytesPerFileRecord)
            guard
                let choice = NTFSRecordAllocator.choose(
                    in: bitmap, recordCount: records, near: recordHint)
            else {
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
                securityID: security, isDirectory: isDirectory)
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
            // One descent, down the raw bytes: it says both whether the name
            // is already there and which node it belongs in. Going through the
            // reader's own search instead builds a Swift string for every entry
            // of every node it passes, which was most of what a create cost.
            guard let shape = indexShape(of: parent.record),
                var leaf = descent(to: name, in: shape, collation: collation)?.last,
                !holds(name, leaf, collation)
            else { return nil }
            // A directory small enough to keep its whole index in its record
            // has no node with spare bytes in it -- what it has is spare room
            // in the record, which is a different question and the only one
            // that matters there.
            var fits = leaf.freeBytes(sectorSize: reader.geometry.bytesPerSector) >= key.count
            if case .root = leaf.site {
                fits =
                    shape.record.header.allocatedLength - shape.record.header.usedLength
                    >= key.count + 8
            }
            if !fits {
                lastGrief = "(the split reported nothing)"
                // Split, then look again: the name now belongs in one of the
                // two halves, and which one is the descent's answer rather than
                // a guess.
                //
                // A split that fails may be a root with no room for another key
                // rather than anything wrong, so the tree is deepened once and
                // the split tried again. Once, not until it works: a second
                // failure is a real one, and retrying would be a loop that
                // writes.
                func trySplit() -> Bool {
                    guard let fresh = indexShape(of: parent.record),
                        let again = descent(to: name, in: fresh, collation: collation)
                    else { return false }
                    return splitLocked(again, in: fresh, collation: collation)
                }
                if !trySplit() {
                    let deepened = deepenLocked(directory: parent.record, collation: collation)
                    if !deepened || !trySplit() {
                        if deepened { lastGrief += " | and again after deepening" }
                        return nil
                    }
                }
                guard let fresh = indexShape(of: parent.record),
                    let after = descent(to: name, in: fresh, collation: collation)?.last
                else {
                    lastGrief += " | and no leaf afterwards"
                    return nil
                }
                var roomNow =
                    after.freeBytes(sectorSize: reader.geometry.bytesPerSector) >= key.count
                if case .root = after.site {
                    roomNow =
                        fresh.record.header.allocatedLength - fresh.record.header.usedLength
                        >= key.count + 8
                }
                guard roomNow else {
                    lastGrief +=
                        " | the leaf still has only \(after.freeBytes(sectorSize: reader.geometry.bytesPerSector)) bytes"
                    return nil
                }
                leaf = after
            }

            // 1. The bitmap.
            guard writeRecordBitmapLocked(choice.bitmap, changedFrom: bitmap) else { return nil }

            // 2. The record.
            guard writeRecordLocked(choice.record, composed, header: header, mirrorLast: true)
            else { return nil }

            // 3. The name. Into a block, or into the record itself when the
            // directory is small enough to keep its index there.
            guard let placed = place(key, into: leaf, collation: collation) else { return nil }
            if case .root = leaf.site {
                guard let fresh = indexShape(of: parent.record),
                    writeNodeLocked(leaf, entries: placed, in: fresh)
                else { return nil }
            } else {
                guard writeNodeLockedRaw(leaf, entries: placed) else { return nil }
            }

            forgetListing()
            recordHint = choice.record
            return Handle(record: choice.record, name: name, isDirectory: isDirectory)
        }
    }

    /// Why a create was refused, in words.
    ///
    /// Only for saying so in a log or a measurement. Nothing depends on it, and
    /// it repeats the checks rather than recording them, so a create and this
    /// can in principle disagree -- which is why it is not what create returns.
    public func whyCreateFailed(_ name: String, in directory: FSHandle) -> String {
        guard let parent = ours(directory), parent.isDirectory else { return "not a directory" }
        return lock.withLock {
            guard volumeIsSafeToWrite else { return "the volume is not safe to write" }
            guard let collation = reader.collation() else { return "no $UpCase" }
            if reader.find(name, inDirectory: parent.record) != nil { return "the name is taken" }
            guard let bitmap = reader.contents(ofFile: NTFSTable.mftRecord, attribute: .bitmap),
                let tableSize = reader.size(ofFile: NTFSTable.mftRecord)
            else { return "$MFT's bitmap does not read" }
            let records = tableSize / UInt64(reader.geometry.bytesPerFileRecord)
            guard NTFSRecordAllocator.choose(in: bitmap, recordCount: records) != nil else {
                return "no free record in a table of \(records)"
            }
            guard let shape = indexShape(of: parent.record),
                let path = descent(to: name, in: shape, collation: collation),
                let leaf = path.last
            else { return "no leaf node for the name" }
            // Deliberately nothing that allocates. An earlier version of
            // this asked the shape for a free index block, which claims a
            // cluster and writes the bitmap -- a question that changed the
            // volume it was asked about.
            var why =
                "the leaf node has "
                + "\(leaf.freeBytes(sectorSize: reader.geometry.bytesPerSector)) bytes free, "
                + "\(path.count) deep, \(leaf.entries.count) entries"
            if !lastGrief.isEmpty { why += " | \(lastGrief)" }
            return why
        }
    }

    /// Why a removal was refused, in words. For logs and measurements only.
    public func whyRemoveFailed(_ name: String, from directory: FSHandle) -> String {
        guard let parent = ours(directory), parent.isDirectory else { return "not a directory" }
        return lock.withLock {
            guard let collation = reader.collation() else { return "no $UpCase" }
            guard let number = reader.find(name, inDirectory: parent.record) else {
                return "the search does not find the name"
            }
            guard let record = reader.record(number) else { return "no record \(number)" }
            if record.header.isDirectory { return "it is a directory" }
            guard let shape = indexShape(of: parent.record) else { return "no index" }
            guard let found = findNode(name, in: shape, collation: collation) else {
                return "the descent does not reach the node holding it"
            }
            let entry = found.node.entries[found.index]
            let child = NTFSIndexSplit.child(of: entry)
            var place = "a leaf"
            if case .root = found.node.site { place = "the root" }
            if child != nil { place += " with a child at \(child!)" }
            if child != nil, largestBelow(entry, in: shape) == nil {
                return "in \(place), and there is no largest name below it"
            }
            return "in \(place), entry \(found.index) of \(found.node.entries.count)"
        }
    }

    /// Whether a node already holds a name.
    private func holds(_ name: String, _ node: NodeAt, _ collation: NTFSCollation) -> Bool {
        let wanted = Array(name.utf16)
        return node.entries.contains { entry in
            NTFSIndexWrite.key(of: entry, at: 0).map {
                collation.compare($0, wanted) == .orderedSame
            } ?? false
        }
    }

    /// A node's entries with one more put where it belongs.
    private func place(_ entry: Data, into node: NodeAt, collation: NTFSCollation) -> [Data]? {
        guard let key = NTFSIndexWrite.key(of: entry, at: 0) else { return nil }
        var entries = node.entries
        var at = entries.count
        for (index, other) in entries.enumerated() {
            guard let otherKey = NTFSIndexWrite.key(of: other, at: 0) else { return nil }
            switch collation.compare(otherKey, key) {
            case .orderedSame: return nil
            case .orderedDescending:
                at = index
            case .orderedAscending: continue
            }
            break
        }
        entries.insert(entry, at: at)
        return entries
    }

    /// Write a block back without a shape to hand.
    ///
    /// Blocks only: a root needs the record it lives in, and any caller holding
    /// a root holds a shape as well.
    ///
    /// Must be called with `lock` held.
    private func writeNodeLockedRaw(_ node: NodeAt, entries: [Data]) -> Bool {
        guard case .block(let offset, let number) = node.site,
            let built = NTFSIndexBlock.compose(
                blockNumber: number, blockSize: node.blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: entries, marker: node.marker,
                hasChildren: node.hasChildren)
        else { return false }
        return writeIndexBlockLocked(built, at: offset)
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

    /// Split a full leaf, so the name that would not fit has somewhere to go.
    ///
    /// The median goes to **the leaf's own parent**, which is the root only
    /// while the tree is one level deep. Once it is deeper, the parent is a
    /// block, and putting the median in the root instead cuts the whole tree by
    /// a key that describes one leaf.
    ///
    /// The order is chosen so nothing is ever unreachable:
    ///
    /// 1. A cluster is claimed, if the index has to grow. A crash leaks it.
    /// 2. The new block is written. Nothing points at it yet, so it is
    ///    invisible rather than wrong.
    /// 3. The parent gains the median. **This is the split.**
    /// 4. The old leaf is trimmed. Between 3 and 4 the names below the median
    ///    are in both blocks -- which no search can notice, because a search
    ///    below the median goes to the new block and never looks in the old.
    ///
    /// Must be called with `lock` held.
    private func splitLocked(_ path: [NodeAt], in shape: IndexShape, collation: NTFSCollation)
        -> Bool
    {
        guard path.count >= 2, let leaf = path.last else {
            lastGrief = "split: the leaf is the root, nothing above it to promote into"
            return false
        }
        let parent = path[path.count - 2]
        guard case .block(let leafOffset, let leafNumber) = leaf.site else {
            lastGrief = "split: the leaf is not a block"
            return false
        }
        guard let plan = split(leaf) else {
            lastGrief = "split: the node cannot be cut, \(leaf.entries.count) entries"
            return false
        }

        guard let room = freeIndexBlockLocked(shape: shape) else {
            lastGrief = "split: no block to put the lower half in"
            return false
        }
        guard
            let built = NTFSIndexBlock.compose(
                blockNumber: room.block, blockSize: shape.blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: plan.below,
                marker: plan.marker, hasChildren: leaf.hasChildren),
            let promoted = NTFSIndexSplit.promoting(plan.median, toChild: room.block),
            let placed = NTFSTable.diskOffset(
                forFileOffset: room.block * UInt64(shape.blockSize), runs: room.runs,
                bytesPerCluster: reader.geometry.bytesPerCluster),
            writeIndexBlockLocked(built, at: placed.offset)
        else {
            lastGrief = "split: the new block could not be built or written"
            return false
        }

        // Where the median belongs among the parent's own keys.
        guard let key = NTFSIndexWrite.key(of: promoted, at: 0) else { return false }
        var entries = parent.entries
        var place = entries.count
        for (index, other) in entries.enumerated() {
            guard let otherKey = NTFSIndexWrite.key(of: other, at: 0) else { return false }
            if collation.compare(otherKey, key) == .orderedDescending {
                place = index
                break
            }
        }
        entries.insert(promoted, at: place)

        guard
            writeParentLocked(
                parent, entries: entries, in: shape, grown: room.grownAllocation,
                claiming: room.block)
        else {
            lastGrief = "split: the parent would not take the median"
            return false
        }

        // 4. The old leaf, trimmed to the names above the median.
        guard
            let trimmed = NTFSIndexBlock.compose(
                blockNumber: leafNumber, blockSize: shape.blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: plan.above,
                marker: plan.marker, hasChildren: leaf.hasChildren)
        else { return false }
        return writeIndexBlockLocked(trimmed, at: leafOffset)
    }

    /// A node's entries cut in two, worked out from the entries themselves.
    private func split(_ node: NodeAt) -> NTFSIndexSplit.Plan? {
        guard node.entries.count >= 3 else { return nil }
        let total = node.entries.reduce(0) { $0 + $1.count }
        var running = 0
        var cut = 0
        for (index, entry) in node.entries.enumerated() {
            running += entry.count
            if running * 2 >= total {
                cut = index
                break
            }
        }
        cut = max(1, min(cut, node.entries.count - 2))
        guard
            NTFSIndexWrite.read16(node.entries[cut], NTFSIndexWrite.entryFlagsField)
                & NTFSIndexWrite.hasChild == 0
        else { return nil }
        return NTFSIndexSplit.Plan(
            below: Array(node.entries[0..<cut]), above: Array(node.entries[(cut + 1)...]),
            marker: node.marker, median: node.entries[cut])
    }

    /// Write a parent back, carrying the index's growth and the new block's bit
    /// with it when the parent is the root.
    ///
    /// The directory's record holds `$INDEX_ROOT`, the `$I30` bitmap and
    /// `$INDEX_ALLOCATION`, so when the parent is the root all three changes go
    /// down in one write and the split commits at once. When the parent is a
    /// block, the bitmap and the runlist still live in the record, so that is
    /// written first and the block after it -- a crash between them leaks a
    /// block, which chkdsk reclaims.
    ///
    /// Must be called with `lock` held.
    private func writeParentLocked(
        _ parent: NodeAt, entries: [Data], in shape: IndexShape, grown: Data?,
        claiming block: UInt64
    ) -> Bool {
        let base = shape.record.data.startIndex
        guard
            let blockBitmap = reader.attributes(of: shape.record).first(where: {
                $0.kind == .bitmap
            }), blockBitmap.isResident
        else { return false }
        var bits = [UInt8](
            shape.record.data[
                (base + blockBitmap.valueOffset)..<(base + blockBitmap.valueOffset
                    + blockBitmap.valueLength)])
        guard Int(block / 8) < bits.count else { return false }
        bits[Int(block / 8)] |= 1 << UInt8(block % 8)

        var edited = shape.record.data
        var header = shape.record.header
        if let grown {
            guard
                let step = NTFSRecordEdit.replacingWhole(
                    .indexAllocation, named: "$I30", with: grown, in: edited, header: header),
                let stepHeader = NTFSRecord.header(
                    step, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            edited = step
            header = stepHeader
        }
        guard
            let withBits = NTFSRecordEdit.replacing(
                .bitmap, named: "$I30", with: Data(bits), in: edited, header: header),
            var withBitsHeader = NTFSRecord.header(
                withBits, expectedLength: reader.geometry.bytesPerFileRecord)
        else { return false }
        var record = withBits

        if case .root = parent.site {
            let value = Data(
                record[
                    (record.startIndex + shape.indexRoot.valueOffset)..<(record.startIndex
                        + shape.indexRoot.valueOffset + shape.indexRoot.valueLength)])
            guard
                let rebuilt = NTFSIndexWrite.laidOut(
                    value, header: NTFSIndexWrite.indexRootHeaderLength, entries: entries,
                    marker: parent.marker),
                withBitsHeader.usedLength + (rebuilt.count - shape.indexRoot.valueLength)
                    <= withBitsHeader.allocatedLength,
                let withRoot = NTFSRecordEdit.replacing(
                    .indexRoot, named: "$I30", with: rebuilt, in: record, header: withBitsHeader),
                let finalHeader = NTFSRecord.header(
                    withRoot, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            record = withRoot
            withBitsHeader = finalHeader
            return writeRecordLocked(
                shape.directory, record, header: withBitsHeader, mirrorLast: true)
        }

        guard case .block(let offset, let number) = parent.site,
            let built = NTFSIndexBlock.compose(
                blockNumber: number, blockSize: shape.blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: entries,
                marker: parent.marker, hasChildren: true),
            writeRecordLocked(
                shape.directory, record, header: withBitsHeader, mirrorLast: true)
        else { return false }
        return writeIndexBlockLocked(built, at: offset)
    }

    /// Give the tree another level, so the root has room again.
    ///
    /// `$INDEX_ROOT` lives inside a record and cannot grow past it. When it is
    /// full, everything it holds moves into a block of its own and the root
    /// keeps a single marker pointing there. The next promotion has an empty
    /// root to go into, and a search still works: the marker's child is where
    /// everything below the last key lives, and after this everything is below
    /// the last key because there are no keys.
    ///
    /// Same order as a split, and for the same reason: the block that will hold
    /// the entries is written while nothing points at it, and the record write
    /// is the moment it becomes true.
    ///
    /// Must be called with `lock` held.
    private func deepenLocked(directory: UInt64, collation: NTFSCollation) -> Bool {
        guard let record = reader.record(directory) else { return false }
        let attributes = reader.attributes(of: record)
        guard let indexRoot = attributes.first(where: { $0.kind == .indexRoot }),
            indexRoot.isResident
        else { return false }

        var blockSize = 0
        let base = record.data.startIndex
        for byte in 0..<4 {
            blockSize |= Int(record.data[base + indexRoot.valueOffset + 8 + byte]) << (8 * byte)
        }
        guard blockSize >= 512 else { return false }

        // A directory made here has no blocks at all: its whole index is the
        // root, because that is what an empty directory is. The first time it
        // outgrows its record it has to acquire the two attributes that hold
        // blocks -- an $INDEX_ALLOCATION to keep them in and a $BITMAP to say
        // which of them exist.
        guard attributes.contains(where: { $0.kind == .indexAllocation }),
            attributes.contains(where: { $0.kind == .bitmap })
        else {
            let gave = giveBlocksLocked(directory: directory, blockSize: blockSize)
            if !gave { lastGrief = "deepen: the directory could not be given blocks" }
            return gave
        }

        guard let allocation = attributes.first(where: { $0.kind == .indexAllocation }),
            !allocation.isResident,
            let blockBitmap = attributes.first(where: { $0.kind == .bitmap }),
            blockBitmap.isResident
        else { return false }

        let rootValue = Data(
            record.data[
                (base + indexRoot.valueOffset)..<(base + indexRoot.valueOffset
                    + indexRoot.valueLength)])
        guard
            let (entries, marker) = NTFSIndexSplit.entries(
                of: rootValue, nodeHeaderAt: NTFSIndexWrite.indexRootHeaderLength),
            !entries.isEmpty
        else { return false }

        // A block for them. Growing the index if there is none free, exactly as
        // a split does.
        guard let shape = indexShape(of: directory), let room = freeIndexBlockLocked(shape: shape)
        else {
            lastGrief = "deepen: no block for the root's entries"
            return false
        }

        guard
            let built = NTFSIndexBlock.compose(
                blockNumber: room.block, blockSize: blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: entries, marker: marker,
                hasChildren: true),
            let placed = NTFSTable.diskOffset(
                forFileOffset: room.block * UInt64(blockSize), runs: room.runs,
                bytesPerCluster: reader.geometry.bytesPerCluster),
            writeIndexBlockLocked(built, at: placed.offset),
            let emptied = NTFSIndexWrite.rootPointingAt(room.block, keeping: rootValue)
        else { return false }

        var bits = [UInt8](
            record.data[
                (base + blockBitmap.valueOffset)..<(base + blockBitmap.valueOffset
                    + blockBitmap.valueLength)])
        guard Int(room.block / 8) < bits.count else { return false }
        bits[Int(room.block / 8)] |= 1 << UInt8(room.block % 8)

        var edited = record.data
        var header = record.header
        if let grown = room.grownAllocation {
            guard
                let step = NTFSRecordEdit.replacingWhole(
                    .indexAllocation, named: "$I30", with: grown, in: edited, header: header),
                let stepHeader = NTFSRecord.header(
                    step, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            edited = step
            header = stepHeader
        }
        guard
            let withBits = NTFSRecordEdit.replacing(
                .bitmap, named: "$I30", with: Data(bits), in: edited, header: header),
            let withBitsHeader = NTFSRecord.header(
                withBits, expectedLength: reader.geometry.bytesPerFileRecord),
            let withRoot = NTFSRecordEdit.replacing(
                .indexRoot, named: "$I30", with: emptied, in: withBits, header: withBitsHeader),
            let finalHeader = NTFSRecord.header(
                withRoot, expectedLength: reader.geometry.bytesPerFileRecord)
        else { return false }
        return writeRecordLocked(directory, withRoot, header: finalHeader, mirrorLast: true)
    }

    /// Give a directory somewhere to keep index blocks.
    ///
    /// A directory made here starts with nothing but its root, which is what an
    /// empty directory is. When the root fills it needs two more attributes: an
    /// `$INDEX_ALLOCATION` holding the blocks and a `$BITMAP` saying which of
    /// them exist. Both are added in one record write, along with the root
    /// emptied into the first block -- so a reader either sees a directory with
    /// no blocks and a full root, or one with a block and an empty root, and
    /// never a root pointing at a block the record does not know about.
    ///
    /// Must be called with `lock` held.
    private func giveBlocksLocked(directory: UInt64, blockSize: Int) -> Bool {
        guard blockSize == reader.geometry.bytesPerCluster,
            let record = reader.record(directory),
            let indexRoot = reader.attributes(of: record).first(where: { $0.kind == .indexRoot }),
            indexRoot.isResident,
            let volumeBitmap = clusterBitmapLocked()
        else { return false }
        let base = record.data.startIndex
        let rootValue = Data(
            record.data[
                (base + indexRoot.valueOffset)..<(base + indexRoot.valueOffset
                    + indexRoot.valueLength)])
        guard
            let (entries, marker) = NTFSIndexSplit.entries(
                of: rootValue, nodeHeaderAt: NTFSIndexWrite.indexRootHeaderLength), !entries.isEmpty
        else { return false }

        // One cluster, near the directory's own record so a listing does not
        // cross the disk.
        let total = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
        guard
            let claim = NTFSAllocator.plan(
                clusters: 1, in: volumeBitmap, totalClusters: total,
                near: (reader.diskOffset(ofRecord: directory) ?? 0)
                    / UInt64(reader.geometry.bytesPerCluster), maximumFragments: 1),
            let cluster = claim.runs.first?.physicalCluster,
            let built = NTFSIndexBlock.compose(
                blockNumber: 0, blockSize: blockSize,
                sectorSize: reader.geometry.bytesPerSector, entries: entries, marker: marker,
                hasChildren: NTFSIndexSplit.child(of: marker) != nil),
            let allocationBytes = NTFSFileGrow.nonResident(
                type: 0xA0, id: 3, runs: claim.runs, bytesPerCluster: blockSize,
                size: UInt64(blockSize), initialised: UInt64(blockSize)),
            let emptied = NTFSIndexWrite.rootPointingAt(0, keeping: rootValue)
        else { return false }

        // The $INDEX_ALLOCATION attribute carries a name, and the one built
        // above does not: it is the general non-resident builder. Put the name
        // in, and move the runlist along to make room for it.
        guard let named = naming(allocationBytes, "$I30") else { return false }

        // Eight bytes of bitmap, sixty-four blocks' worth, with the first taken.
        var bits = [UInt8](repeating: 0, count: 8)
        bits[0] = 0x01

        // 1. The cluster. A crash from here leaks it and nothing else.
        guard
            writeVolumeBitmapLocked(
                claim.bitmap, touching: claim.runs, changedFrom: volumeBitmap)
        else { return false }
        // 2. The block, which nothing points at yet.
        guard writeIndexBlockLocked(built, at: cluster * UInt64(blockSize)) else { return false }
        // 3. The record: both new attributes and the emptied root, at once.
        //
        // The root is emptied first. It is what filled the record in the first
        // place, and the two new attributes have to fit in what it gives back
        // -- adding them to a record that is still full fails, which is what it
        // did.
        guard
            let withRoot = NTFSRecordEdit.replacing(
                .indexRoot, named: "$I30", with: emptied, in: record.data, header: record.header),
            let emptyHeader = NTFSRecord.header(
                withRoot, expectedLength: reader.geometry.bytesPerFileRecord),
            let withAllocation = NTFSRecordEdit.adding(
                named, type: 0xA0, named: "$I30", to: withRoot, header: emptyHeader),
            let step = NTFSRecord.header(
                withAllocation, expectedLength: reader.geometry.bytesPerFileRecord),
            let bitmapBytes = residentAttribute(type: 0xB0, id: 4, name: "$I30", value: Data(bits)),
            let withBitmap = NTFSRecordEdit.adding(
                bitmapBytes, type: 0xB0, named: "$I30", to: withAllocation, header: step),
            let finalHeader = NTFSRecord.header(
                withBitmap, expectedLength: reader.geometry.bytesPerFileRecord)
        else { return false }
        return writeRecordLocked(directory, withBitmap, header: finalHeader, mirrorLast: true)
    }

    /// A non-resident attribute with a name put into it.
    ///
    /// The general builder makes nameless attributes; `$I30` needs one, and the
    /// runlist has to move along to make room. Doing it here rather than in the
    /// builder keeps the builder to one job.
    private func naming(_ attribute: Data, _ name: String) -> Data? {
        let units = Array(name.utf16)
        let nameAt = NTFSFileGrow.nonResidentHeaderLength
        let runlistAt = (nameAt + units.count * 2 + 7) & ~7
        let oldRunlistAt = Int(NTFSFileGrow.read16(attribute, NTFSFileGrow.runlistOffsetField))
        guard oldRunlistAt >= nameAt, oldRunlistAt <= attribute.count else { return nil }
        let runlist = [UInt8](attribute[(attribute.startIndex + oldRunlistAt)...])
        let length = (runlistAt + runlist.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }

        var bytes = [UInt8](attribute.prefix(nameAt))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: length - nameAt))
        for (index, unit) in units.enumerated() {
            bytes[nameAt + index * 2] = UInt8(unit & 0xFF)
            bytes[nameAt + index * 2 + 1] = UInt8(unit >> 8)
        }
        bytes.replaceSubrange(runlistAt..<(runlistAt + runlist.count), with: runlist)
        bytes[0x09] = UInt8(units.count)
        bytes[0x0A] = UInt8(nameAt & 0xFF)
        bytes[0x0B] = UInt8(nameAt >> 8)
        bytes[NTFSFileGrow.runlistOffsetField] = UInt8(runlistAt & 0xFF)
        bytes[NTFSFileGrow.runlistOffsetField + 1] = UInt8(runlistAt >> 8)
        for byte in 0..<4 {
            bytes[0x04 + byte] = UInt8((UInt32(length) >> (8 * UInt32(byte))) & 0xFF)
        }
        return Data(bytes)
    }

    /// A resident attribute with a name, built whole.
    private func residentAttribute(type: UInt32, id: UInt16, name: String, value: Data) -> Data? {
        let units = Array(name.utf16)
        let nameAt = 24
        let valueAt = (nameAt + units.count * 2 + 7) & ~7
        let length = (valueAt + value.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        for byte in 0..<4 { bytes[byte] = UInt8((type >> (8 * UInt32(byte))) & 0xFF) }
        for byte in 0..<4 {
            bytes[0x04 + byte] = UInt8((UInt32(length) >> (8 * UInt32(byte))) & 0xFF)
        }
        bytes[0x08] = 0
        bytes[0x09] = UInt8(units.count)
        bytes[0x0A] = UInt8(nameAt & 0xFF)
        bytes[0x0E] = UInt8(id & 0xFF)
        bytes[0x0F] = UInt8(id >> 8)
        for byte in 0..<4 {
            bytes[0x10 + byte] = UInt8((UInt32(value.count) >> (8 * UInt32(byte))) & 0xFF)
        }
        bytes[0x14] = UInt8(valueAt & 0xFF)
        bytes[0x15] = UInt8(valueAt >> 8)
        for (index, unit) in units.enumerated() {
            bytes[nameAt + index * 2] = UInt8(unit & 0xFF)
            bytes[nameAt + index * 2 + 1] = UInt8(unit >> 8)
        }
        bytes.replaceSubrange(valueAt..<(valueAt + value.count), with: [UInt8](value))
        return Data(bytes)
    }

    /// A free index block, growing the index by one if it has none.
    private struct IndexRoom {
        let block: UInt64
        let runs: [NTFSRunlist.Run]
        /// The rebuilt `$INDEX_ALLOCATION`, when it had to grow.
        let grownAllocation: Data?
    }

    /// Must be called with `lock` held.
    private func freeIndexBlockLocked(shape: IndexShape) -> IndexRoom? {
        let record = shape.record
        let blockSize = shape.blockSize
        guard
            let allocation = reader.attributes(of: record).first(where: {
                $0.kind == .indexAllocation
            }), !allocation.isResident,
            let blockBitmap = reader.attributes(of: record).first(where: { $0.kind == .bitmap }),
            blockBitmap.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return nil }
        let base = record.data.startIndex
        let bits = [UInt8](
            record.data[
                (base + blockBitmap.valueOffset)..<(base + blockBitmap.valueOffset
                    + blockBitmap.valueLength)])

        let existing = allocation.dataSize / UInt64(blockSize)
        for number in 0..<existing where bits[Int(number / 8)] & (1 << UInt8(number % 8)) == 0 {
            return IndexRoom(block: number, runs: runs, grownAllocation: nil)
        }
        guard UInt64(bits.count) * 8 > existing else { return nil }

        guard blockSize == reader.geometry.bytesPerCluster,
            let last = runs.last, let lastCluster = last.physicalCluster,
            let volumeBitmap = clusterBitmapLocked()
        else { return nil }
        let total = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
        let after = lastCluster + last.clusterCount
        guard
            let claim = NTFSAllocator.plan(
                clusters: 1, in: volumeBitmap, totalClusters: total, near: after,
                maximumFragments: 1),
            let got = claim.runs.first?.physicalCluster
        else { return nil }

        var extended = runs
        if got == after {
            extended[extended.count - 1] = NTFSRunlist.Run(
                logicalCluster: last.logicalCluster, physicalCluster: lastCluster,
                clusterCount: last.clusterCount + 1)
        } else {
            extended.append(
                NTFSRunlist.Run(
                    logicalCluster: last.logicalCluster + last.clusterCount, physicalCluster: got,
                    clusterCount: 1))
        }
        guard let encoded = NTFSRunlist.encode(extended),
            let rebuilt = nonResidentBytes(
                allocation, in: record.data, runlist: encoded,
                size: allocation.dataSize + UInt64(blockSize),
                lastCluster: NTFSRunlist.clusterCount(extended) - 1),
            writeVolumeBitmapLocked(claim.bitmap, touching: claim.runs, changedFrom: volumeBitmap)
        else { return nil }
        return IndexRoom(block: existing, runs: extended, grownAllocation: rebuilt)
    }

    /// Where a non-resident attribute keeps its runlist, read from its own
    /// header rather than assumed.
    private func runlistOffset(of attribute: Data) -> Int {
        Int(attribute[attribute.startIndex + 0x20])
            | (Int(attribute[attribute.startIndex + 0x21]) << 8)
    }

    /// A non-resident attribute's bytes, with a new runlist and new sizes.
    ///
    /// The header stays as it was apart from the four numbers that describe the
    /// extent of the data: the last cluster it covers, how much room it takes
    /// on the disk, and how much of that is real. A runlist changed without
    /// them is an attribute that ends before its own clusters do.
    private func nonResidentBytes(
        _ attribute: NTFSAttribute.Header, in record: Data, runlist: Data, size: UInt64,
        lastCluster: UInt64
    ) -> Data? {
        // Find the attribute's own bytes by walking to it.
        guard let header = NTFSRecord.header(record, expectedLength: record.count) else {
            return nil
        }
        var at = header.firstAttributeOffset
        let base = record.startIndex
        while at + 8 <= header.usedLength {
            var kind: UInt32 = 0
            for byte in 0..<4 { kind |= UInt32(record[base + at + byte]) << (8 * UInt32(byte)) }
            if kind == 0xFFFF_FFFF { return nil }
            var length = 0
            for byte in 0..<4 { length |= Int(record[base + at + 4 + byte]) << (8 * byte) }
            guard length >= 24, at + length <= header.usedLength else { return nil }
            if kind == attribute.type, record[base + at + 8] == 1 {
                var bytes = [UInt8](record[(base + at)..<(base + at + length)])
                let runlistAt = Int(bytes[0x20]) | (Int(bytes[0x21]) << 8)
                let needed = (runlistAt + runlist.count + 7) & ~7
                guard needed <= 0xFFFF else { return nil }
                if needed > bytes.count {
                    bytes.append(contentsOf: [UInt8](repeating: 0, count: needed - bytes.count))
                } else if needed < bytes.count {
                    bytes.removeSubrange(needed..<bytes.count)
                }
                for index in runlistAt..<bytes.count { bytes[index] = 0 }
                bytes.replaceSubrange(
                    runlistAt..<(runlistAt + runlist.count), with: [UInt8](runlist))
                // 0x04 the attribute's length, 0x18 the last cluster, 0x28 the
                // room taken, 0x30 the real size, 0x38 the size a reader may
                // trust as initialised.
                for byte in 0..<4 {
                    bytes[0x04 + byte] = UInt8((UInt32(bytes.count) >> (8 * UInt32(byte))) & 0xFF)
                }
                for byte in 0..<8 {
                    bytes[0x18 + byte] = UInt8((lastCluster >> (8 * UInt64(byte))) & 0xFF)
                    bytes[0x28 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF)
                    bytes[0x30 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF)
                    bytes[0x38 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF)
                }
                return Data(bytes)
            }
            at += length
        }
        return nil
    }

    /// Write the changed part of the volume's cluster bitmap.
    ///
    /// Must be called with `lock` held.
    private func writeVolumeBitmapLocked(_ contents: Data, changedFrom previous: Data) -> Bool {
        guard
            writeAnyAttributeLocked(
                record: NTFSVolumeReader.bitmapRecord, attribute: .data, contents: contents,
                changedFrom: previous)
        else { return false }
        // The copy in hand is now what is on the disk. Not updating it here is
        // how a cache starts handing out clusters that have already been given
        // away.
        clusterBitmap = contents
        return true
    }

    /// Write `$MFT`'s record bitmap and keep the copy in hand in step.
    ///
    /// Must be called with `lock` held.
    private func writeRecordBitmapLocked(_ contents: Data, changedFrom previous: Data) -> Bool {
        guard
            writeAnyAttributeLocked(
                record: NTFSTable.mftRecord, attribute: .bitmap, contents: contents,
                changedFrom: previous)
        else { return false }
        recordBitmap = contents
        return true
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

    /// Write back just the part of a bitmap that a set of runs touched.
    ///
    /// The general version finds what changed by comparing the old bytes with
    /// the new -- 128 KB of comparison on a four-gigabyte volume, on every
    /// write that allocates. The allocator already knows which clusters it
    /// took, and the bits for them lie in one stretch of the bitmap, so there
    /// is nothing to search for.
    ///
    /// Must be called with `lock` held.
    private func writeVolumeBitmapLocked(
        _ contents: Data, touching runs: [NTFSRunlist.Run], changedFrom previous: Data
    ) -> Bool {
        var lowest = UInt64.max
        var highest: UInt64 = 0
        for run in runs {
            guard let start = run.physicalCluster, run.clusterCount > 0 else { continue }
            lowest = min(lowest, start)
            highest = max(highest, start + run.clusterCount - 1)
        }
        guard lowest != UInt64.max else { return true }
        return writeBitmapRangeLocked(
            contents, bits: lowest...highest, changedFrom: previous)
    }

    /// Must be called with `lock` held.
    private func writeBitmapRangeLocked(
        _ contents: Data, bits: ClosedRange<UInt64>, changedFrom previous: Data
    ) -> Bool {
        guard let writeBytes, contents.count == previous.count,
            let record = reader.record(NTFSVolumeReader.bitmapRecord),
            let attribute = reader.attributes(of: record).first(where: { $0.kind == .data }),
            !attribute.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: attribute.runlistOffset, limit: record.data.count)
        else { return false }
        let sector = reader.geometry.bytesPerSector
        guard sector > 0 else { return false }

        let firstSector = Int(bits.lowerBound / 8) / sector
        let lastSector = Int(bits.upperBound / 8) / sector
        for block in firstSector...lastSector {
            let from = block * sector
            guard from < contents.count else { break }
            let slice = contents[
                (contents.startIndex + from)..<min(
                    contents.endIndex, contents.startIndex + from + sector)]
            guard
                let pieces = NTFSFileWrite.pieces(
                    offset: UInt64(from), length: slice.count, runs: runs,
                    bytesPerCluster: reader.geometry.bytesPerCluster, size: attribute.dataSize)
            else { return false }
            for piece in pieces {
                // The slice is already a Data. Wrapping it in another one copies
                // every byte a second time, which on a megabyte write is most
                // of what the write costs.
                guard
                    writeBytes(
                        piece.diskOffset,
                        slice[
                            (slice.startIndex + piece.range.lowerBound)..<(slice.startIndex
                                + piece.range.upperBound)])
                else { return false }
            }
        }
        clusterBitmap = contents
        return true
    }

    /// Write the changed part of a non-resident attribute.
    ///
    /// Only the bytes that differ, and only in whole sectors around them: a
    /// bitmap is megabytes on a large volume and rewriting all of it to set one
    /// bit would take a second and put every one of those bytes at risk.
    ///
    /// Must be called with `lock` held.
    ///
    /// **Not for the two bitmaps.** Those are cached while the volume is
    /// marked, and a write that goes round the cache leaves it handing out
    /// records and clusters that have already been given away -- which is how
    /// four hundred files came to share one record. `writeRecordBitmapLocked`
    /// and `writeVolumeBitmapLocked` are the only ways in, and this refuses the
    /// two of them outright rather than trusting every future caller to
    /// remember.
    private func writeAttributeLocked(
        record number: UInt64, attribute kind: NTFSAttribute.Kind, contents: Data,
        changedFrom previous: Data
    ) -> Bool {
        guard !(number == NTFSTable.mftRecord && kind == .bitmap),
            !(number == NTFSVolumeReader.bitmapRecord && kind == .data)
        else { return false }
        return writeAnyAttributeLocked(
            record: number, attribute: kind, contents: contents, changedFrom: previous)
    }

    /// The write itself, with no guard on which attribute it is.
    ///
    /// Must be called with `lock` held.
    private func writeAnyAttributeLocked(
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
                // A slice of Data is a Data. Making a new one copies every
                // byte a second time.
                guard
                    writeBytes(
                        piece.diskOffset,
                        slice[
                            slice.startIndex + piece.range.lowerBound..<slice.startIndex
                                + piece.range.upperBound])
                else { return false }
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

            // One descent, down the raw bytes, which finds the entry and says
            // which node holds it. The record number is in the entry itself, so
            // the reader's own search -- which builds a string per entry per
            // node -- is not needed as well.
            guard let shape = indexShape(of: parent.record),
                let found = findNode(name, in: shape, collation: collation)
            else { return .missing }
            let entry = found.node.entries[found.index]
            var reference: UInt64 = 0
            for byte in 0..<8 {
                reference |= UInt64(entry[entry.startIndex + byte]) << (8 * UInt64(byte))
            }
            let number = reference & 0x0000_FFFF_FFFF_FFFF
            guard let record = reader.record(number) else { return .missing }
            if record.header.isDirectory {
                // An empty directory can go. One with anything in it must not,
                // and NTFS does not say so anywhere but in the index itself.
                guard (reader.contents(ofDirectory: number)?.isEmpty ?? false) else {
                    return .notEmpty
                }
            }
            guard markLocked() else { return .missing }

            // 1. The name, out of whichever node a search would find it in --
            // which is not always a leaf, and an entry that is not in a leaf
            // holds the tree together as well as naming a file.
            guard takeOutLocked(found.index, of: found.node, in: shape, collation: collation)
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
            guard let bitmap = recordBitmapLocked(),
                let tableSize = reader.size(ofFile: NTFSTable.mftRecord),
                let released = NTFSRecordAllocator.releasing(
                    number, in: bitmap,
                    recordCount: tableSize / UInt64(reader.geometry.bytesPerFileRecord)),
                writeRecordBitmapLocked(released, changedFrom: bitmap)
            else { return .missing }

            // 4. A directory's index blocks go back to the volume. A file's
            // clusters are deliberately left claimed -- its record still points
            // at them and that is what makes it recoverable -- but a directory
            // that is gone has no names to recover, and its blocks are pure
            // bookkeeping.
            // Only a directory's. A file's clusters are deliberately left
            // claimed: its record still points at them, and that is what makes
            // it recoverable. Freeing them would hand the next write the bytes
            // somebody may want back. (A file has no $INDEX_ALLOCATION, so
            // calling this on one does nothing either way -- the check is here
            // to say which of the two rules is the one being followed.)
            if record.header.isDirectory {
                _ = releaseIndexBlocksLocked(of: record)
            }

            // The slot just freed is below the hint, and the next create
            // should take it rather than walk past it to the end of the table.
            recordHint = min(recordHint, number)
            forgetListing()
            return .removed
        }
    }

    /// Where a node lives, so it can be written back.
    private enum NodeSite {
        /// Inside the directory's own record, as `$INDEX_ROOT`.
        case root
        /// Out in `$INDEX_ALLOCATION`, at this byte and this block number.
        case block(offset: UInt64, number: UInt64)
    }

    /// A node, its entries, and where it came from.
    private struct NodeAt {
        let entries: [Data]
        let marker: Data
        let site: NodeSite
        let blockSize: Int
        /// Whether anything hangs below it.
        let hasChildren: Bool

        /// How many bytes the node has left for another entry.
        ///
        /// Worked out from the entries rather than read from the header,
        /// because the entries are what gets written back: a header claiming
        /// room the entries disagree with is a write past the end of the node.
        /// A root has none by definition -- it lives in a record, and every
        /// byte it does not use belongs to another attribute.
        var free: Int { 0 }

        /// How many bytes the node has left, for a given sector size.
        ///
        /// Measured from where a composed block actually puts its first entry,
        /// which is past the fixup array and not at the node header. Measuring
        /// from the header over-reports by the length of the array, and then
        /// the node says it has room while the block refuses to lay out --
        /// which looks like a create failing for no reason.
        func freeBytes(sectorSize: Int) -> Int {
            if case .root = site { return 0 }
            let used =
                NTFSIndexBlock.firstEntry(blockSize: blockSize, sectorSize: sectorSize)
                + entries.reduce(0) { $0 + $1.count } + marker.count
            return max(0, blockSize - NTFSIndexBlock.nodeHeaderOffset - used)
        }
    }

    /// Walk down to the node holding a name, keeping what is needed to write
    /// it back.
    ///
    /// The same descent a search does, because a name has to be taken out of
    /// the node a search would find it in and no other.
    ///
    /// Must be called with `lock` held.
    private func findNode(_ name: String, in shape: IndexShape, collation: NTFSCollation)
        -> (node: NodeAt, index: Int)?
    {
        let wanted = Array(name.utf16)
        var current = shape.root
        for _ in 0..<32 {
            var descend: UInt64?
            for (index, entry) in current.entries.enumerated() {
                guard let key = NTFSIndexWrite.key(of: entry, at: 0) else { return nil }
                switch collation.compare(key, wanted) {
                case .orderedSame:
                    return (current, index)
                case .orderedDescending:
                    // The first key past it: what we want is below this entry.
                    descend = NTFSIndexSplit.child(of: entry)
                    if descend == nil { return nil }
                case .orderedAscending:
                    continue
                }
                if descend != nil { break }
            }
            // Past every key in the node: below the marker, or nowhere.
            let next = descend ?? NTFSIndexSplit.child(of: current.marker)
            guard let next, let below = node(at: next, in: shape) else { return nil }
            current = below
        }
        return nil
    }

    /// Every node from the root down to the one a name belongs in.
    ///
    /// The leaf is last and the root is first. A split needs the one before the
    /// leaf, because that is where the median goes -- putting it in the root
    /// instead partitions the whole tree by a key that only describes one leaf,
    /// and every name on the wrong side of it becomes unreachable while still
    /// sitting in a block. Which is exactly what happened: nothing was lost, a
    /// third of the names simply could not be found.
    ///
    /// Must be called with `lock` held.
    private func descent(to name: String, in shape: IndexShape, collation: NTFSCollation)
        -> [NodeAt]?
    {
        let wanted = Array(name.utf16)
        var path = [shape.root]
        for _ in 0..<32 {
            guard let current = path.last else { return nil }
            var descend: UInt64?
            for entry in current.entries {
                guard let key = NTFSIndexWrite.key(of: entry, at: 0) else { return nil }
                switch collation.compare(key, wanted) {
                case .orderedSame: return path
                case .orderedDescending:
                    descend = NTFSIndexSplit.child(of: entry)
                    if descend == nil { return path }
                case .orderedAscending: continue
                }
                if descend != nil { break }
            }
            guard let next = descend ?? NTFSIndexSplit.child(of: current.marker) else {
                return path
            }
            guard let below = node(at: next, in: shape) else { return nil }
            path.append(below)
        }
        return nil
    }

    /// What a directory's index is made of.
    private struct IndexShape {
        let directory: UInt64
        let record: (data: Data, header: NTFSRecord.Header)
        let indexRoot: NTFSAttribute.Header
        let blockSize: Int
        let runs: [NTFSRunlist.Run]
        let root: NodeAt
    }

    /// Must be called with `lock` held.
    private func indexShape(of directory: UInt64) -> IndexShape? {
        guard let record = reader.record(directory), record.header.isDirectory else { return nil }
        let attributes = reader.attributes(of: record)
        guard let indexRoot = attributes.first(where: { $0.kind == .indexRoot }),
            indexRoot.isResident
        else { return nil }
        let base = record.data.startIndex
        var blockSize = 0
        for byte in 0..<4 {
            blockSize |= Int(record.data[base + indexRoot.valueOffset + 8 + byte]) << (8 * byte)
        }
        guard blockSize >= 512 else { return nil }
        let value = Data(
            record.data[
                (base + indexRoot.valueOffset)..<(base + indexRoot.valueOffset
                    + indexRoot.valueLength)])
        guard
            let (entries, marker) = NTFSIndexSplit.entries(
                of: value, nodeHeaderAt: NTFSIndexWrite.indexRootHeaderLength)
        else { return nil }
        let runs =
            attributes.first(where: { $0.kind == .indexAllocation }).flatMap {
                $0.isResident
                    ? nil
                    : NTFSRunlist.decode(
                        record.data, at: $0.runlistOffset, limit: record.data.count)
            } ?? []
        return IndexShape(
            directory: directory, record: record, indexRoot: indexRoot, blockSize: blockSize,
            runs: runs,
            root: NodeAt(
                entries: entries, marker: marker, site: .root, blockSize: blockSize,
                hasChildren: NTFSIndexSplit.child(of: marker) != nil))
    }

    /// Must be called with `lock` held.
    private func node(at number: UInt64, in shape: IndexShape) -> NodeAt? {
        guard
            let placed = NTFSTable.diskOffset(
                forFileOffset: number * UInt64(shape.blockSize), runs: shape.runs,
                bytesPerCluster: reader.geometry.bytesPerCluster),
            let raw = reader.read(placed.offset, shape.blockSize),
            let header = NTFSIndexBlock.header(raw, blockSize: shape.blockSize),
            let bytes = NTFSIndexBlock.applyFixup(
                raw, header: header, sectorSize: reader.geometry.bytesPerSector),
            let (entries, marker) = NTFSIndexSplit.entries(
                of: bytes, nodeHeaderAt: NTFSIndexBlock.nodeHeaderOffset)
        else { return nil }
        return NodeAt(
            entries: entries, marker: marker,
            site: .block(offset: placed.offset, number: number), blockSize: shape.blockSize,
            hasChildren: NTFSIndexSplit.child(of: marker) != nil)
    }

    /// Write a node back with the entries given.
    ///
    /// Must be called with `lock` held.
    private func writeNodeLocked(
        _ node: NodeAt, entries: [Data], in shape: IndexShape
    ) -> Bool {
        switch node.site {
        case .block(let offset, let number):
            guard
                let built = NTFSIndexBlock.compose(
                    blockNumber: number, blockSize: node.blockSize,
                    sectorSize: reader.geometry.bytesPerSector, entries: entries,
                    marker: node.marker, hasChildren: node.hasChildren)
            else { return false }
            return writeIndexBlockLocked(built, at: offset)
        case .root:
            let base = shape.record.data.startIndex
            let value = Data(
                shape.record.data[
                    (base + shape.indexRoot.valueOffset)..<(base + shape.indexRoot.valueOffset
                        + shape.indexRoot.valueLength)])
            guard
                let rebuilt = NTFSIndexWrite.laidOut(
                    value, header: NTFSIndexWrite.indexRootHeaderLength, entries: entries,
                    marker: node.marker),
                shape.record.header.usedLength + (rebuilt.count - shape.indexRoot.valueLength)
                    <= shape.record.header.allocatedLength,
                let edited = NTFSRecordEdit.replacing(
                    .indexRoot, named: "$I30", with: rebuilt, in: shape.record.data,
                    header: shape.record.header),
                let header = NTFSRecord.header(
                    edited, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            return writeRecordLocked(
                shape.directory, edited, header: header, mirrorLast: true)
        }
    }

    /// Take one entry out of a node, whatever kind of node it is.
    ///
    /// A leaf entry is simply dropped. **An entry with a node below it is not**,
    /// because it holds the tree together as well as naming a file: everything
    /// under it is reached by comparing against its key. So it is replaced by
    /// the largest name below it, which is bigger than everything else down
    /// there and smaller than everything to its right -- so every name stays on
    /// the side of it it was on -- and that name is then taken out of the leaf
    /// it came from.
    ///
    /// The replacement is written first. For as long as it takes to write the
    /// leaf afterwards, that name is in two places, and a search finds it in
    /// the higher one and stops -- which is the right answer. The other order
    /// makes the name missing for exactly as long.
    ///
    /// Must be called with `lock` held.
    private func takeOutLocked(
        _ index: Int, of node: NodeAt, in shape: IndexShape, collation: NTFSCollation
    ) -> Bool {
        guard index < node.entries.count else { return false }
        let entry = node.entries[index]

        guard NTFSIndexSplit.child(of: entry) != nil else {
            var left = node.entries
            left.remove(at: index)
            return writeNodeLocked(node, entries: left, in: shape)
        }

        // A subtree with nothing left in it. Removals have emptied it, so the
        // key above it names nothing and describes nothing: it can go, and the
        // block it pointed at goes back to the directory's own bitmap.
        if isEmptyBelow(entry, in: shape) {
            var left = node.entries
            left.remove(at: index)
            guard writeNodeLocked(node, entries: left, in: shape) else { return false }
            // After the entry is gone the block is unreferenced, so freeing its
            // bit second means a crash between the two leaks a block rather
            // than leaving a pointer to one that is free.
            if let block = NTFSIndexSplit.child(of: entry) {
                _ = freeIndexBlockBitLocked(block, of: shape.directory)
            }
            return true
        }

        guard let (leaf, replacement) = largestBelow(entry, in: shape),
            let key = NTFSIndexWrite.key(of: replacement, at: 0),
            let carried = NTFSIndexSplit.child(of: entry),
            let promoted = NTFSIndexSplit.promoting(replacement, toChild: carried),
            let removedKey = NTFSIndexWrite.key(of: entry, at: 0)
        else { return false }
        // The replacement must come from below this entry and not from beside
        // it: a leaf reached through some other key gives a name that belongs
        // on the wrong side, and every search for it afterwards goes the wrong
        // way.
        guard collation.compare(key, removedKey) == .orderedAscending else { return false }

        var replaced = node.entries
        replaced[index] = promoted
        guard writeNodeLocked(node, entries: replaced, in: shape) else { return false }

        var below = leaf.entries
        guard !below.isEmpty else { return false }
        below.removeLast()
        return writeNodeLocked(leaf, entries: below, in: shape)
    }

    /// Whether there is nothing at all below an entry.
    ///
    /// Must be called with `lock` held.
    private func isEmptyBelow(_ entry: Data, in shape: IndexShape) -> Bool {
        guard var current = NTFSIndexSplit.child(of: entry).flatMap({ node(at: $0, in: shape) })
        else { return false }
        for _ in 0..<32 {
            if !current.entries.isEmpty { return false }
            guard
                let deeper = NTFSIndexSplit.child(of: current.marker).flatMap({
                    node(at: $0, in: shape)
                })
            else { return true }
            current = deeper
        }
        return false
    }

    /// Give a removed directory's index blocks back to the volume.
    ///
    /// Done last, and its failure is not the removal's failure: by this point
    /// the directory is gone from its parent and its record is free, and a
    /// crash here leaves clusters nobody owns. That is space, which chkdsk
    /// reclaims. Refusing the whole removal because the tidying failed would
    /// leave a directory somebody asked to be rid of.
    ///
    /// Must be called with `lock` held.
    private func releaseIndexBlocksLocked(of record: (data: Data, header: NTFSRecord.Header))
        -> Bool
    {
        guard
            let allocation = reader.attributes(of: record).first(where: {
                $0.kind == .indexAllocation
            }), !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count),
            let bitmap = clusterBitmapLocked()
        else { return true }  // no blocks to give back

        let total = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
        var working = bitmap
        for run in runs {
            guard let start = run.physicalCluster, run.clusterCount > 0 else { continue }
            guard
                let released = NTFSBitmap.releasing(
                    start, count: run.clusterCount, in: working, totalClusters: total)
            else { return false }
            working = released
        }
        return writeVolumeBitmapLocked(working, touching: runs, changedFrom: bitmap)
    }

    /// Give an index block back to the directory that owned it.
    ///
    /// Must be called with `lock` held.
    private func freeIndexBlockBitLocked(_ block: UInt64, of directory: UInt64) -> Bool {
        guard let record = reader.record(directory),
            let blockBitmap = reader.attributes(of: record).first(where: { $0.kind == .bitmap }),
            blockBitmap.isResident
        else { return false }
        let base = record.data.startIndex
        var bits = [UInt8](
            record.data[
                (base + blockBitmap.valueOffset)..<(base + blockBitmap.valueOffset
                    + blockBitmap.valueLength)])
        guard Int(block / 8) < bits.count else { return false }
        bits[Int(block / 8)] &= ~(1 << UInt8(block % 8))
        guard
            let edited = NTFSRecordEdit.replacing(
                .bitmap, named: "$I30", with: Data(bits), in: record.data, header: record.header),
            let header = NTFSRecord.header(
                edited, expectedLength: reader.geometry.bytesPerFileRecord)
        else { return false }
        return writeRecordLocked(directory, edited, header: header, mirrorLast: true)
    }

    /// The largest name below a node, and the leaf it lives in.
    ///
    /// Always down the last child, which is where the largest keys are. This is
    /// the entry that replaces a key being taken out of an internal node: it is
    /// bigger than everything else under that key, so putting it in the key's
    /// place leaves every name still on the side of it that it was.
    ///
    /// Must be called with `lock` held.
    private func largestBelow(_ entry: Data, in shape: IndexShape) -> (leaf: NodeAt, entry: Data)? {
        guard var current = NTFSIndexSplit.child(of: entry).flatMap({ node(at: $0, in: shape) })
        else { return nil }
        for _ in 0..<32 {
            if let deeper = NTFSIndexSplit.child(of: current.marker).flatMap({
                node(at: $0, in: shape)
            }) {
                current = deeper
                continue
            }
            guard let last = current.entries.last,
                NTFSIndexWrite.read16(last, NTFSIndexWrite.entryFlagsField)
                    & NTFSIndexWrite.hasChild == 0
            else { return nil }
            return (current, last)
        }
        return nil
    }

    /// Give a file another name, or another directory, or both.
    ///
    /// Three things change: the entry in the old directory, the `$FILE_NAME` in
    /// the file's own record, and the entry in the new directory. **The record
    /// is not the name -- the index is** -- so the order is chosen by what a
    /// reader finds between the writes:
    ///
    /// 1. The new entry goes in. The file is now reachable by both names, and
    ///    both lead to the same record. A crash here leaves a file with two
    ///    names, which chkdsk resolves and nobody loses anything over.
    /// 2. The record's `$FILE_NAME` is rewritten to the new name and parent.
    /// 3. The old entry comes out.
    ///
    /// The other order -- old entry first -- leaves the file reachable by no
    /// name at all for as long as the writes take, which is a file that has
    /// vanished.
    ///
    /// Renaming onto a name that is taken is refused. NTFS has one entry per
    /// name; replacing means removing the other file first, and doing that
    /// silently inside a rename is how somebody loses the wrong one.
    public func rename(
        _ name: String, in source: FSHandle, to newName: String, in destination: FSHandle
    ) -> Bool {
        guard writeBytes != nil, !name.isEmpty, !newName.isEmpty,
            let from = ours(source), from.isDirectory,
            let into = ours(destination), into.isDirectory
        else { return false }

        return lock.withLock {
            guard volumeIsSafeToWrite, let collation = reader.collation() else { return false }
            if from.record == into.record, collation.isSameName(name, newName) { return true }

            guard let fromShape = indexShape(of: from.record),
                let found = findNode(name, in: fromShape, collation: collation)
            else { return false }
            let entry = found.node.entries[found.index]
            var reference: UInt64 = 0
            for byte in 0..<8 {
                reference |= UInt64(entry[entry.startIndex + byte]) << (8 * UInt64(byte))
            }
            let number = reference & 0x0000_FFFF_FFFF_FFFF
            guard let record = reader.record(number), let intoRecord = reader.record(into.record)
            else { return false }
            guard markLocked() else { return false }

            // The entry that will carry the new name is built before anything
            // is written: finding out it cannot be means a file with two names
            // and no way back.
            //
            // Whether the name is already taken is not asked here. `place`
            // refuses a name that is already in the node, and that is the check
            // that has to hold -- asking twice makes one of the two answers
            // untestable, and the untestable one is the one that rots.
            guard let intoShape = indexShape(of: into.record) else { return false }

            let attributes = reader.attributes(of: record)
            guard let existing = attributes.first(where: { $0.kind == .fileName }),
                existing.isResident,
                let times = reader.times(of: record)
            else { return false }
            let base = record.data.startIndex
            var flags: UInt32 = 0
            for byte in 0..<4 {
                flags |=
                    UInt32(record.data[base + existing.valueOffset + 56 + byte])
                    << (8 * UInt32(byte))
            }
            var size: UInt64 = 0
            var allocated: UInt64 = 0
            for byte in 0..<8 {
                allocated |=
                    UInt64(record.data[base + existing.valueOffset + 40 + byte])
                    << (8 * UInt64(byte))
                size |=
                    UInt64(record.data[base + existing.valueOffset + 48 + byte])
                    << (8 * UInt64(byte))
            }
            let plan = NTFSNewRecord.Plan(
                record: number, sequence: 1, parent: into.record,
                parentSequence: sequenceOf(intoRecord), name: newName, namespace: .posix,
                times: times, dosFlags: flags & ~NTFSNewRecord.directoryFlag, securityID: 0,
                isDirectory: record.header.isDirectory)
            var value = [UInt8](
                NTFSNewRecord.fileNameValue(plan, units: Array(newName.utf16)))
            // The sizes the old name carried, kept: they are a copy of what the
            // record says, and a rename does not change how long a file is.
            for byte in 0..<8 {
                value[40 + byte] = UInt8((allocated >> (8 * UInt64(byte))) & 0xFF)
                value[48 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF)
            }
            guard
                let carried = NTFSIndexWrite.entry(
                    key: Data(value), record: number,
                    sequence: sequenceOf(record))
            else { return false }

            // 1. The new name.
            guard let target = descent(to: newName, in: intoShape, collation: collation)?.last
            else { return false }
            var room = target.freeBytes(sectorSize: reader.geometry.bytesPerSector) >= carried.count
            if case .root = target.site {
                room =
                    intoShape.record.header.allocatedLength - intoShape.record.header.usedLength
                    >= carried.count + 8
            }
            guard room, let placed = place(carried, into: target, collation: collation) else {
                // No room means the node must split, which a rename does not
                // do. Refusing is a rename that did not happen; going on is a
                // file in two directories or none.
                return false
            }
            if case .root = target.site {
                guard let fresh = indexShape(of: into.record),
                    writeNodeLocked(target, entries: placed, in: fresh)
                else { return false }
            } else {
                guard writeNodeLockedRaw(target, entries: placed) else { return false }
            }

            // 2. The record.
            guard
                let edited = NTFSRecordEdit.replacing(
                    .fileName, named: nil, with: Data(value), in: record.data,
                    header: record.header),
                let header = NTFSRecord.header(
                    edited, expectedLength: reader.geometry.bytesPerFileRecord),
                writeRecordLocked(number, edited, header: header, mirrorLast: true)
            else { return false }

            // 3. The old name.
            guard let againShape = indexShape(of: from.record),
                let old = findNode(name, in: againShape, collation: collation),
                takeOutLocked(old.index, of: old.node, in: againShape, collation: collation)
            else { return false }
            forgetListing()
            return true
        }
    }

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

        // A write past the end of the file is a write that has to make the file
        // longer, which is a different operation and is done first. Afterwards
        // the write below is the ordinary one: bytes into clusters the file
        // already owns.
        let end = UInt64(offset) + UInt64(contents.count)
        if (reader.size(ofFile: handle.record) ?? 0) < end || isResident(handle.record) {
            guard growLocked(handle.record, to: end, writing: contents, at: UInt64(offset))
            else { return 0 }
            // The directory entry carries its own copy of the length, and it is
            // the copy a listing reads.
            lock.withLock {
                if let collation = reader.collation() {
                    refreshEntryLocked(for: handle.record, collation: collation)
                }
            }
            // A resident file's bytes went in with the record, so nothing is
            // left to write.
            if isResident(handle.record) { return contents.count }
        }

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
                guard
                    writeBytes(
                        piece.diskOffset,
                        contents[
                            contents.startIndex + piece.range.lowerBound..<contents.startIndex
                                + piece.range.upperBound])
                else { break }
                written += piece.range.count
            }
            return written
        }
    }

    /// Set a file's length.
    ///
    /// **This is how anything overwrites a file.** `cp`, Finder, every editor:
    /// open it, cut it to nothing, write the new contents. A filesystem that
    /// ignores the cutting leaves the tail of whatever was there before hanging
    /// off the end of the new file, and the person sees a file that is part
    /// theirs and part somebody else's.
    ///
    /// Shrinking keeps the clusters. NTFS allows `allocatedSize` to exceed
    /// `dataSize` -- that is what it is for -- and a file that is cut and
    /// rewritten, which is the common case, then needs no allocation at all.
    /// The bytes past the new end stay on the disk and are unreachable, exactly
    /// as they are for a removed file, and for the same reason.
    ///
    /// Growing past what is allocated goes through the same path a write does.
    /// The space between what is written and the new end reads as zeroes
    /// without touching the disk, which is what `initialisedSize` is for.
    public func truncate(_ handle: FSHandle, to size: Int) {
        guard writeBytes != nil, let handle = ours(handle), !handle.isDirectory, size >= 0
        else { return }
        let wanted = UInt64(size)
        if (reader.size(ofFile: handle.record) ?? 0) < wanted {
            // Longer. The same operation as a write, with nothing to write.
            _ = growLocked(handle.record, to: wanted, writing: Data(), at: 0)
        } else {
            _ = shortenLocked(handle.record, to: wanted)
        }
        lock.withLock {
            if let collation = reader.collation() {
                refreshEntryLocked(for: handle.record, collation: collation)
            }
        }
    }

    /// Cut a file down, without giving its clusters back.
    private func shortenLocked(_ number: UInt64, to size: UInt64) -> Bool {
        lock.withLock {
            forgetListing()
            guard volumeIsSafeToWrite, markLocked(), let held = reader.record(number),
                !reader.spillsAttributes(held)
            else { return false }
            let attributes = reader.attributes(of: held)
            guard let data = attributes.first(where: { $0.kind == .data }), data.isReadableAsIs
            else { return false }
            let base = held.data.startIndex

            if data.isResident {
                guard size <= UInt64(data.valueLength) else { return false }
                let value = held.data[
                    (base + data.valueOffset)..<(base + data.valueOffset + Int(size))]
                guard
                    let edited = NTFSRecordEdit.replacing(
                        .data, named: nil, with: Data(value), in: held.data, header: held.header),
                    let header = NTFSRecord.header(
                        edited, expectedLength: reader.geometry.bytesPerFileRecord),
                    let sized = sizedFileName(edited, header: header, size: size, allocated: 0),
                    let sizedHeader = NTFSRecord.header(
                        sized, expectedLength: reader.geometry.bytesPerFileRecord)
                else { return false }
                return writeRecordLocked(number, sized, header: sizedHeader, mirrorLast: true)
            }

            guard
                let runs = NTFSRunlist.decode(
                    held.data, at: data.runlistOffset, limit: held.data.count),
                let bytes = attributeBytes(data, in: held.data),
                let attribute = NTFSFileGrow.extended(
                    bytes, runs: runs, bytesPerCluster: reader.geometry.bytesPerCluster,
                    size: size, initialised: min(size, data.dataSize)),
                let edited = NTFSRecordEdit.replacingWhole(
                    .data, named: nil, with: attribute, in: held.data, header: held.header),
                let header = NTFSRecord.header(
                    edited, expectedLength: reader.geometry.bytesPerFileRecord),
                let sized = sizedFileName(
                    edited, header: header, size: size,
                    allocated: NTFSRunlist.clusterCount(runs)
                        * UInt64(reader.geometry.bytesPerCluster)),
                let sizedHeader = NTFSRecord.header(
                    sized, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            return writeRecordLocked(number, sized, header: sizedHeader, mirrorLast: true)
        }
    }

    /// Whether a file's bytes are inside its record.
    private func isResident(_ record: UInt64) -> Bool {
        lock.withLock {
            guard let held = reader.record(record) else { return false }
            return reader.attributes(of: held).first(where: { $0.kind == .data })?.isResident
                ?? false
        }
    }

    /// Make a file longer, and put the bytes in while doing it.
    ///
    /// A new file's bytes live inside its record. Beyond a few hundred they go
    /// out to clusters, and the record stops carrying the bytes and starts
    /// carrying a list of where they are. A file crosses between those two
    /// shapes exactly once.
    ///
    /// The order is the same as everywhere else here: clusters are claimed
    /// first, the bytes go into them second, and the record saying the file
    /// owns them is written last. A crash anywhere before that last write
    /// leaves clusters nobody owns -- space, which chkdsk reclaims -- and never
    /// a file claiming bytes that were never written.
    private func growLocked(
        _ number: UInt64, to size: UInt64, writing contents: Data, at offset: UInt64
    ) -> Bool {
        lock.withLock {
            // A grown file has a new length, and a listing carries lengths.
            forgetListing()
            guard let writeBytes, volumeIsSafeToWrite, markLocked(),
                let held = reader.record(number), !reader.spillsAttributes(held)
            else { return false }
            let attributes = reader.attributes(of: held)
            guard let data = attributes.first(where: { $0.kind == .data }), data.isReadableAsIs
            else { return false }
            let cluster = reader.geometry.bytesPerCluster
            let base = held.data.startIndex

            if data.isResident {
                // The bytes as they will be: what is there, extended with
                // zeroes to the write, then the write itself.
                var value = [UInt8](
                    held.data[
                        (base + data.valueOffset)..<(base + data.valueOffset + data.valueLength)])
                if UInt64(value.count) < size {
                    value.append(
                        contentsOf: [UInt8](repeating: 0, count: Int(size) - value.count))
                }
                let at = Int(offset)
                guard at + contents.count <= value.count else { return false }
                value.replaceSubrange(at..<(at + contents.count), with: [UInt8](contents))

                // Still inside the record? Then it is one write and nothing is
                // allocated.
                let others = attributes.filter { $0.kind != .data }.reduce(0) { $0 + $1.length }
                if value.count
                    <= NTFSFileGrow.residentRoom(
                        header: held.header, otherAttributesLength: others)
                {
                    guard
                        let edited = NTFSRecordEdit.replacing(
                            .data, named: nil, with: Data(value), in: held.data,
                            header: held.header),
                        let header = NTFSRecord.header(
                            edited, expectedLength: reader.geometry.bytesPerFileRecord),
                        let sized = sizedFileName(
                            edited, header: header, size: UInt64(value.count), allocated: 0),
                        let sizedHeader = NTFSRecord.header(
                            sized, expectedLength: reader.geometry.bytesPerFileRecord)
                    else { return false }
                    return writeRecordLocked(number, sized, header: sizedHeader, mirrorLast: true)
                }

                // Out to the disk, all of it, since the bytes already in the
                // record have to go somewhere too.
                guard
                    let claimed = claimClustersLocked(
                        NTFSFileGrow.clusters(for: size, bytesPerCluster: cluster) ?? 0, near: 0),
                    let attribute = NTFSFileGrow.nonResident(
                        type: data.type, id: 0, runs: claimed, bytesPerCluster: cluster,
                        size: size, initialised: size),
                    putLocked(Data(value), into: claimed, at: 0),
                    let edited = NTFSRecordEdit.replacingWhole(
                        .data, named: nil, with: attribute, in: held.data, header: held.header),
                    let header = NTFSRecord.header(
                        edited, expectedLength: reader.geometry.bytesPerFileRecord),
                    let sized = sizedFileName(
                        edited, header: header, size: size,
                        allocated: NTFSRunlist.clusterCount(claimed) * UInt64(cluster)),
                    let sizedHeader = NTFSRecord.header(
                        sized, expectedLength: reader.geometry.bytesPerFileRecord)
                else { return false }
                return writeRecordLocked(number, sized, header: sizedHeader, mirrorLast: true)
            }

            // Already out on the disk. More clusters if it needs them, then the
            // bytes, then the record.
            guard
                var runs = NTFSRunlist.decode(
                    held.data, at: data.runlistOffset, limit: held.data.count),
                let attributeBytes = attributeBytes(data, in: held.data)
            else { return false }
            let have = NTFSRunlist.clusterCount(runs)
            guard let want = NTFSFileGrow.clusters(for: size, bytesPerCluster: cluster) else {
                return false
            }
            if want > have {
                // Claim more than is needed, so the next append finds room
                // already there. This is what allocatedSize is for: NTFS keeps
                // it above dataSize on purpose, and a file written a megabyte
                // at a time otherwise pays for a bitmap search, a runlist
                // re-encode and a record rewrite on every one of them.
                //
                // Doubling, and never by more than sixteen megabytes at once --
                // a file that doubles without a bound claims a gigabyte for its
                // five-hundred-and-twelfth megabyte. If the volume has no run
                // that long, ask again for exactly what is needed: a file that
                // fails to grow because the greedy ask could not be met would
                // be refusing a write there is room for.
                var after: UInt64 = 0
                if let tail = runs.last, let physical = tail.physicalCluster {
                    after = physical + tail.clusterCount
                }
                let ceiling = max(UInt64(16 << 20) / UInt64(cluster), 1)
                let ahead = max(want - have, min(have, ceiling))
                guard
                    let more = claimClustersLocked(ahead, near: after)
                        ?? claimClustersLocked(want - have, near: after),
                    let joined = NTFSFileGrow.joining(runs, with: more)
                else { return false }
                runs = joined
            }
            guard putLocked(contents, into: runs, at: offset),
                let attribute = NTFSFileGrow.extended(
                    attributeBytes, runs: runs, bytesPerCluster: cluster, size: size,
                    // How much has been written, not how long the file is. A
                    // file extended past what anybody wrote has clusters in it
                    // that still hold the last file's bytes, and claiming they
                    // are written is handing those bytes over under a new name.
                    initialised: min(size, max(data.dataSize, offset + UInt64(contents.count)))),
                let edited = NTFSRecordEdit.replacingWhole(
                    .data, named: nil, with: attribute, in: held.data, header: held.header),
                let header = NTFSRecord.header(
                    edited, expectedLength: reader.geometry.bytesPerFileRecord),
                let sized = sizedFileName(
                    edited, header: header, size: size,
                    allocated: NTFSRunlist.clusterCount(runs) * UInt64(cluster)),
                let sizedHeader = NTFSRecord.header(
                    sized, expectedLength: reader.geometry.bytesPerFileRecord)
            else { return false }
            _ = writeBytes
            return writeRecordLocked(number, sized, header: sizedHeader, mirrorLast: true)
        }
    }

    /// Write the file's length into the copy its directory entry keeps.
    ///
    /// The record's `$FILE_NAME` is one copy; the entry in the parent's index
    /// is a copy of that copy, and **it is the one a listing reads**. Windows
    /// and Finder both take names, times and sizes straight out of the index
    /// without opening a single record -- which is what makes listing a million
    /// files one pass rather than a million reads, and what makes a stale entry
    /// a file that looks empty.
    ///
    /// The parent is found through the record's own `$FILE_NAME`, because a
    /// handle does not carry one: a file knows which directory it is in, and
    /// that is where the reference lives.
    ///
    /// Its failure is not the write's failure. By this point the bytes are on
    /// the disk and the record says how many; an entry left stale is a wrong
    /// number in a listing, which is worse than right and better than losing
    /// the write.
    ///
    /// Must be called with `lock` held.
    @discardableResult
    private func refreshEntryLocked(for number: UInt64, collation: NTFSCollation) -> Bool {
        guard let record = reader.record(number),
            let name = reader.attributes(of: record).first(where: { $0.kind == .fileName }),
            name.isResident, name.valueLength >= 66
        else { return false }
        let base = record.data.startIndex
        let value = Data(
            record.data[
                (base + name.valueOffset)..<(base + name.valueOffset + name.valueLength)])
        guard let parsed = NTFSFileName.read(value) else { return false }

        guard let shape = indexShape(of: parsed.parentRecord),
            let found = findNode(parsed.name, in: shape, collation: collation)
        else { return false }
        let existing = found.node.entries[found.index]
        // The entry keeps whatever it kept -- its reference, its flags, its
        // child if it has one -- and only the key changes.
        var rebuilt = [UInt8](existing)
        let keyLength = Int(NTFSIndexWrite.read16(existing, NTFSIndexWrite.keyLengthField))
        guard keyLength == value.count,
            NTFSIndexWrite.keyField + keyLength <= rebuilt.count
        else { return false }
        rebuilt.replaceSubrange(
            NTFSIndexWrite.keyField..<(NTFSIndexWrite.keyField + keyLength), with: [UInt8](value))

        var entries = found.node.entries
        entries[found.index] = Data(rebuilt)
        return writeNodeLocked(found.node, entries: entries, in: shape)
    }

    /// Write the file's length into the copy `$FILE_NAME` keeps of it.
    ///
    /// **A directory listing reads sizes out of the index, not out of the
    /// record.** `$FILE_NAME` carries a copy, the index entry carries a copy of
    /// that copy, and neither is updated by writing to the file. So a file
    /// created and then filled reads as its full length through any code that
    /// opens it -- ours does -- and as nothing at all in a listing, which is
    /// what Finder and Windows Explorer show.
    ///
    /// This updates the record's copy. The index entry's copy is stale until
    /// the name is written again, which is what NTFS itself does: Windows
    /// refreshes index entries lazily and chkdsk repairs the rest. A stale
    /// size in a listing is wrong; a zero in one is a file that looks empty.
    private func sizedFileName(
        _ record: Data, header: NTFSRecord.Header, size: UInt64,
        allocated: UInt64
    ) -> Data? {
        // The times move as well. A file that has been written has been
        // modified, and a filesystem that does not say so breaks every backup
        // tool, every sort by date, and every question anybody asks about what
        // changed. NTFS keeps four: created, modified, record-changed and
        // accessed. A write moves the middle two -- the contents changed and
        // the record describing them changed -- and leaves created alone,
        // because it did not.
        let now = NTFSNewRecord.ticks(Date())

        guard
            let name = NTFSAttribute.all(
                in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength
            ).first(where: { $0.kind == .fileName }), name.isResident, name.valueLength >= 56
        else { return nil }
        var value = [UInt8](
            record[
                (record.startIndex + name.valueOffset)..<(record.startIndex + name.valueOffset
                    + name.valueLength)])
        for byte in 0..<8 {
            // $FILE_NAME's own copy of the times begins at 8.
            value[16 + byte] = UInt8((now >> (8 * UInt64(byte))) & 0xFF)
            value[24 + byte] = UInt8((now >> (8 * UInt64(byte))) & 0xFF)
            value[40 + byte] = UInt8((allocated >> (8 * UInt64(byte))) & 0xFF)
            value[48 + byte] = UInt8((size >> (8 * UInt64(byte))) & 0xFF)
        }
        guard
            let named = NTFSRecordEdit.replacing(
                .fileName, named: nil, with: Data(value), in: record, header: header),
            let namedHeader = NTFSRecord.header(named, expectedLength: record.count),
            let information = NTFSAttribute.all(
                in: named, startingAt: namedHeader.firstAttributeOffset,
                usedLength: namedHeader.usedLength
            ).first(where: { $0.kind == .standardInformation }), information.isResident,
            information.valueLength >= 32
        else { return nil }

        // $STANDARD_INFORMATION is where the times a reader trusts live. The
        // copy in $FILE_NAME is for listings; this is the one anything that
        // opens the file asks.
        var carried = [UInt8](
            named[
                (named.startIndex + information.valueOffset)..<(named.startIndex
                    + information.valueOffset + information.valueLength)])
        for byte in 0..<8 {
            carried[8 + byte] = UInt8((now >> (8 * UInt64(byte))) & 0xFF)
            carried[16 + byte] = UInt8((now >> (8 * UInt64(byte))) & 0xFF)
        }
        return NTFSRecordEdit.replacing(
            .standardInformation, named: nil, with: Data(carried), in: named,
            header: namedHeader)
    }

    /// One attribute's own bytes, found by walking to it.
    private func attributeBytes(_ attribute: NTFSAttribute.Header, in record: Data) -> Data? {
        guard let header = NTFSRecord.header(record, expectedLength: record.count) else {
            return nil
        }
        var at = header.firstAttributeOffset
        let base = record.startIndex
        while at + 8 <= header.usedLength {
            var kind: UInt32 = 0
            for byte in 0..<4 { kind |= UInt32(record[base + at + byte]) << (8 * UInt32(byte)) }
            if kind == 0xFFFF_FFFF { return nil }
            var length = 0
            for byte in 0..<4 { length |= Int(record[base + at + 4 + byte]) << (8 * byte) }
            guard length >= 24, at + length <= header.usedLength else { return nil }
            if kind == attribute.type {
                return Data(record[(base + at)..<(base + at + length)])
            }
            at += length
        }
        return nil
    }

    /// Claim clusters from the volume's bitmap and write it back.
    ///
    /// Must be called with `lock` held.
    private func claimClustersLocked(_ count: UInt64, near hint: UInt64) -> [NTFSRunlist.Run]? {
        guard count > 0, let bitmap = clusterBitmapLocked() else { return nil }
        let total = reader.geometry.totalSectors / UInt64(reader.geometry.sectorsPerCluster)
        guard
            let plan = NTFSAllocator.plan(
                clusters: count, in: bitmap, totalClusters: total, near: hint),
            writeVolumeBitmapLocked(plan.bitmap, touching: plan.runs, changedFrom: bitmap)
        else { return nil }
        return plan.runs
    }

    /// Put bytes into a file's clusters.
    ///
    /// Must be called with `lock` held.
    private func putLocked(_ contents: Data, into runs: [NTFSRunlist.Run], at offset: UInt64)
        -> Bool
    {
        guard let writeBytes, !contents.isEmpty else { return true }
        let cluster = reader.geometry.bytesPerCluster
        guard
            let pieces = NTFSFileWrite.pieces(
                offset: offset, length: contents.count, runs: runs, bytesPerCluster: cluster,
                size: NTFSRunlist.clusterCount(runs) * UInt64(cluster))
        else { return false }
        for piece in pieces {
            let slice = contents[
                (contents.startIndex + piece.range.lowerBound)..<(contents.startIndex
                    + piece.range.upperBound)]
            guard writeBytes(piece.diskOffset, slice) else { return false }
        }
        return true
    }

    // MARK: - Extended attributes

    /// None yet. NTFS keeps them in `$EA`, which is a separate attribute and a
    /// separate piece of work; answering "none" is true rather than convenient.
    ///
    /// **Setting one says so, rather than saying it is missing.** A filesystem
    /// that does not keep extended attributes and a file that happens not to
    /// have the one asked for are different answers, and macOS acts on the
    /// difference: told the filesystem does not keep them, it puts them in a
    /// `._` file beside the real one, which is what every NTFS volume on a Mac
    /// already has and what v1 produces. Told the attribute is missing, it has
    /// been given a reply that makes no sense to a request to set something.
    public func xattr(_ name: String, of handle: FSHandle) -> Data? { nil }
    public func xattrNames(of handle: FSHandle) -> [String] { [] }
    public func setXattr(
        _ name: String, to value: Data?, on handle: FSHandle, mustCreate: Bool, mustReplace: Bool
    ) -> FSStore.XattrOutcome { .unsupported }

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
