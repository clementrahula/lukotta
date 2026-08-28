// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Reading an NTFS volume, over anything that can hand back bytes at an offset.
///
/// The layers below this each do one thing to a buffer somebody else read. This
/// puts them together and adds the one thing they refuse to do: going to the
/// disk. What "the disk" is stays out of it -- on a mounted volume the reads go
/// through `FSBlockDeviceResource`, in a check they go through a file handle,
/// and neither belongs in a parser.
///
/// It reads and does not write. Writing NTFS means allocating clusters, keeping
/// `$Bitmap` in step, growing runlists and journalling to `$LogFile` so that a
/// power cut does not leave a volume chkdsk has to repair. None of that is here,
/// and a volume served from this is served read-only.
public final class NTFSVolumeReader: @unchecked Sendable {

    /// Where the bytes come from. One function, so that the same reader works
    /// against a device, a file, or a stub in a check.
    public typealias ReadBytes = @Sendable (_ offset: UInt64, _ length: Int) -> Data?

    public let geometry: NTFSGeometry
    private let read: ReadBytes
    private let mftRuns: [NTFSRunlist.Run]
    private let tableSize: UInt64
    /// Read once, because Finder asks for free space on every window.
    ///
    /// Guarded by a lock of its own rather than by whoever happens to be
    /// calling. The class says `@unchecked Sendable`, and that claim has to be
    /// true on its own terms: FSKit calls a volume on several queues at once,
    /// and a reader used directly -- as a check does, and as anything that
    /// skipped the backing would -- has nothing else protecting it. Two threads
    /// filling this at once is a data race whatever the outcome looks like.
    private var cachedBitmap: Data?
    private let cacheLock = NSLock()

    /// Open a volume, or refuse.
    ///
    /// Refuses anything that is not NTFS, and anything whose table cannot be
    /// found -- there is no reading a volume whose master file table is
    /// unreadable, and pretending otherwise produces an empty drive rather than
    /// an error.
    public init?(read: @escaping ReadBytes) {
        guard let boot = read(0, 4096), let geometry = NTFSGeometry.read(boot) else { return nil }
        self.geometry = geometry
        self.read = read

        // The table's own record is the one place the boot sector points at
        // directly. Everything else is found through its runs.
        guard let raw = read(geometry.mftByteOffset, geometry.bytesPerFileRecord),
            let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
            let record = NTFSRecord.applyFixup(
                raw, header: header, sectorSize: geometry.bytesPerSector),
            let data = NTFSAttribute.all(
                in: record, startingAt: header.firstAttributeOffset, usedLength: header.usedLength
            ).first(where: { $0.kind == .data }),
            !data.isResident,
            let runs = NTFSRunlist.decode(record, at: data.runlistOffset, limit: record.count)
        else { return nil }
        self.mftRuns = runs
        self.tableSize = data.dataSize
    }

    /// How much of the volume is in use, in bytes, and how large it is.
    ///
    /// Read from `$Bitmap`, which is the only structure that knows. Counting
    /// records instead would mean reading the whole master file table to answer
    /// a question Finder asks every time a window opens.
    ///
    /// The bitmap is read once and kept: it is 128 KB on a 4 GB volume and
    /// grows with the disk, and reading it per call would make every window a
    /// disk read. It goes stale only if something else writes to the drive,
    /// which for a read-only volume means somebody has unplugged it and put it
    /// back.
    public func spaceInUse() -> (used: UInt64, total: UInt64)? {
        let total = geometry.totalSectors / UInt64(geometry.sectorsPerCluster)
        guard total > 0 else { return nil }
        let bitmap: Data
        cacheLock.lock()
        let cached = cachedBitmap
        cacheLock.unlock()
        if let cached {
            bitmap = cached
        } else {
            // Read outside the lock: it is a disk read, and holding a lock
            // across one blocks every other window. Two threads arriving
            // together both read and both store, which costs one extra read
            // and is correct -- the bitmap does not change under a read-only
            // volume.
            guard let read = contents(ofFile: bitmapRecord), !read.isEmpty else { return nil }
            cacheLock.lock()
            cachedBitmap = read
            cacheLock.unlock()
            bitmap = read
        }
        let free = NTFSBitmap.freeClusters(in: bitmap, totalClusters: total)
        let cluster = UInt64(geometry.bytesPerCluster)
        return ((total - free) * cluster, total * cluster)
    }

    /// `$Bitmap` is record 6 on every NTFS volume.
    public static let bitmapRecord: UInt64 = 6
    private var bitmapRecord: UInt64 { Self.bitmapRecord }

    /// What the volume says about itself: its name, its version, and whether
    /// it was unmounted cleanly.
    ///
    /// Read on demand rather than at open, because a volume that cannot answer
    /// is still a volume worth reading. A drive whose `$Volume` record is
    /// damaged is precisely one somebody wants their files off.
    public func state() -> NTFSVolumeState.Info? {
        guard let record = record(NTFSVolumeState.volumeRecord) else { return nil }
        return NTFSVolumeState.read(record: record.data, attributes: attributes(of: record))
    }

    /// Whether this volume may be written to.
    ///
    /// Nothing writes yet, so this is the gate being put in place before there
    /// is anything to gate -- which is the right order for a rule whose whole
    /// purpose is to stop a change that cannot be undone. A volume that cannot
    /// say is treated as unsafe: not knowing is not the same as knowing it is
    /// clean, and the expensive mistake here is only in one direction.
    public var isSafeToWrite: Bool {
        guard state()?.isSafeToWrite == true else { return false }
        // And the journal. A volume whose $LogFile holds unfinished work has a
        // change half made in it, and finishing or undoing that is what a mount
        // is meant to do. v2 cannot, so it must not write over the evidence --
        // that leaves a volume no implementation can reason about, chkdsk
        // included.
        guard let page = contents(ofFile: NTFSJournal.record, offset: 0, length: 4096) else {
            // No journal readable is not "no journal outstanding".
            return false
        }
        return NTFSJournal.mayWrite(NTFSJournal.state(firstPage: page))
    }

    // MARK: - Records

    /// One record, repaired, with its header.
    /// Where a record physically lies, without reading it.
    ///
    /// A writer needs this and a reader does not, which is why it is separate:
    /// putting a record back means knowing the byte it came from, and working
    /// that out a second time somewhere else is how a writer ends up writing to
    /// a different place than the reader read from.
    public func diskOffset(ofRecord number: UInt64) -> UInt64? {
        guard
            NTFSTable.isWithin(
                record: number, tableSizeInBytes: tableSize,
                bytesPerFileRecord: geometry.bytesPerFileRecord),
            let inTable = NTFSTable.offsetInTable(
                record: number, bytesPerFileRecord: geometry.bytesPerFileRecord),
            let placed = NTFSTable.diskOffset(
                forFileOffset: inTable, runs: mftRuns, bytesPerCluster: geometry.bytesPerCluster),
            placed.availableBytes >= UInt64(geometry.bytesPerFileRecord)
        else { return nil }
        return placed.offset
    }

    public func record(_ number: UInt64) -> (data: Data, header: NTFSRecord.Header)? {
        guard
            let offset = diskOffset(ofRecord: number),
            let raw = read(offset, geometry.bytesPerFileRecord),
            let header = NTFSRecord.header(raw, expectedLength: geometry.bytesPerFileRecord),
            let repaired = NTFSRecord.applyFixup(
                raw, header: header, sectorSize: geometry.bytesPerSector)
        else { return nil }
        return (repaired, header)
    }

    public func attributes(of record: (data: Data, header: NTFSRecord.Header))
        -> [NTFSAttribute.Header]
    {
        NTFSAttribute.all(
            in: record.data, startingAt: record.header.firstAttributeOffset,
            usedLength: record.header.usedLength)
    }

    /// The name a record should be shown under.
    public func name(of record: (data: Data, header: NTFSRecord.Header)) -> String? {
        let names = attributes(of: record)
            .filter { $0.kind == .fileName && $0.isResident }
            .compactMap { attribute -> NTFSFileName.Name? in
                let start = record.data.startIndex + attribute.valueOffset
                guard start + attribute.valueLength <= record.data.endIndex else { return nil }
                return NTFSFileName.read(record.data[start..<start + attribute.valueLength])
            }
        return NTFSFileName.preferred(names)?.name
    }

    /// When a record's file was made and last changed.
    ///
    /// Without this every file on the volume shows the same date, which no
    /// error reports and anybody looking at a Finder window sees at once.
    public func times(of record: (data: Data, header: NTFSRecord.Header))
        -> NTFSTimestamps.Times?
    {
        guard
            let info = attributes(of: record)
                .first(where: { $0.kind == .standardInformation && $0.isResident })
        else { return nil }
        let start = record.data.startIndex + info.valueOffset
        guard start + info.valueLength <= record.data.endIndex else { return nil }
        return NTFSTimestamps.read(record.data[start..<start + info.valueLength])
    }

    /// The DOS-era flags, of which hidden is the one that matters: a volume
    /// that shows its own metadata files to whoever opens it looks broken.
    public func flags(of record: (data: Data, header: NTFSRecord.Header))
        -> NTFSTimestamps.Flags?
    {
        guard
            let info = attributes(of: record)
                .first(where: { $0.kind == .standardInformation && $0.isResident })
        else { return nil }
        let start = record.data.startIndex + info.valueOffset
        guard start + info.valueLength <= record.data.endIndex else { return nil }
        return NTFSTimestamps.flags(record.data[start..<start + info.valueLength])
    }

    // MARK: - Directories

    /// What is in a directory, by record number.
    ///
    /// Reads the entries held in the record and then those in each index block,
    /// which is where the names of any directory worth listing actually live.
    /// One node of a directory's B-tree, and where it lives.
    ///
    /// A listing does not need to know which node a name came from, but an
    /// insertion needs nothing else: the entry goes into one node, that node is
    /// written back, and the disk offset is where it goes.
    public struct IndexNode: Sendable {
        /// The entries, in the order the volume keeps them -- which is sorted,
        /// within this node.
        public let entries: [NTFSIndex.Entry]
        /// Where the block lies on the disk, or nil for `$INDEX_ROOT`, which
        /// lives inside the directory's record.
        public let diskOffset: UInt64?
        /// Its number within `$INDEX_ALLOCATION`, which is what a parent entry
        /// points at.
        public let blockNumber: UInt64?
        /// How many bytes of the block are used, and how many it has.
        public let usedBytes: Int
        public let allocatedBytes: Int

        public init(
            entries: [NTFSIndex.Entry], diskOffset: UInt64?, blockNumber: UInt64?,
            usedBytes: Int, allocatedBytes: Int
        ) {
            self.entries = entries
            self.diskOffset = diskOffset
            self.blockNumber = blockNumber
            self.usedBytes = usedBytes
            self.allocatedBytes = allocatedBytes
        }

        /// Room left for another entry.
        public var freeBytes: Int { max(0, allocatedBytes - usedBytes) }
    }

    /// Every node of a directory's index.
    ///
    /// The blocks are swept in the order they lie in `$INDEX_ALLOCATION`, not
    /// walked as a tree. For a listing that is the faster of the two and the
    /// order does not matter; for anything that cares about order, each node is
    /// sorted within itself and that is the invariant the volume keeps.
    public func indexNodes(ofDirectory number: UInt64) -> [IndexNode] {
        guard let record = record(number), record.header.isDirectory else { return [] }
        let attributes = attributes(of: record)
        var nodes: [IndexNode] = []

        var blockSize = 0
        if let indexRoot = attributes.first(where: { $0.kind == .indexRoot }), indexRoot.isResident
        {
            let value = record.data.startIndex + indexRoot.valueOffset
            guard value + 16 <= record.data.endIndex else { return nodes }
            for i in 0..<4 { blockSize |= Int(record.data[value + 8 + i]) << (8 * i) }
            let node = indexRoot.valueOffset + 16
            if let first = NTFSIndex.firstEntryOffset(nodeHeader: record.data, at: node) {
                let limit = min(indexRoot.valueOffset + indexRoot.valueLength, record.data.count)
                nodes.append(
                    IndexNode(
                        entries: NTFSIndex.entries(record.data, from: first, limit: limit),
                        diskOffset: nil, blockNumber: nil,
                        usedBytes: indexRoot.valueLength, allocatedBytes: indexRoot.valueLength))
            }
        }

        guard blockSize >= 512,
            let allocation = attributes.first(where: { $0.kind == .indexAllocation }),
            !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return nodes }

        let total = NTFSRunlist.clusterCount(runs) * UInt64(geometry.bytesPerCluster)
        var offset: UInt64 = 0
        var guardCount = 0
        while offset + UInt64(blockSize) <= total, guardCount < 4096 {
            guardCount += 1
            let at = offset
            defer { offset += UInt64(blockSize) }
            guard
                let placed = NTFSTable.diskOffset(
                    forFileOffset: at, runs: runs, bytesPerCluster: geometry.bytesPerCluster),
                let raw = read(placed.offset, blockSize),
                let header = NTFSIndexBlock.header(raw, blockSize: blockSize),
                let block = NTFSIndexBlock.applyFixup(
                    raw, header: header, sectorSize: geometry.bytesPerSector)
            else { continue }
            nodes.append(
                IndexNode(
                    entries: NTFSIndex.entries(
                        block, from: header.firstEntryOffset, limit: header.endOfEntries),
                    diskOffset: placed.offset,
                    blockNumber: at / UInt64(blockSize),
                    usedBytes: header.endOfEntries, allocatedBytes: blockSize))
        }
        return nodes
    }

    public func contents(ofDirectory number: UInt64) -> [(name: String, record: UInt64)]? {
        guard let record = record(number), record.header.isDirectory else { return nil }
        let attributes = attributes(of: record)

        var found: [(name: String, record: UInt64)] = []
        var seen = Set<UInt64>()

        func take(_ entries: [NTFSIndex.Entry]) {
            for entry in entries where !entry.isLast {
                guard let name = entry.name?.name, !seen.contains(entry.record) else { continue }
                seen.insert(entry.record)
                found.append((name, entry.record))
            }
        }

        // The root of the tree, inside the record.
        var blockSize = 0
        if let indexRoot = attributes.first(where: { $0.kind == .indexRoot }), indexRoot.isResident
        {
            let value = record.data.startIndex + indexRoot.valueOffset
            guard value + 16 <= record.data.endIndex else { return found }
            for i in 0..<4 { blockSize |= Int(record.data[value + 8 + i]) << (8 * i) }
            // The node header sits after the index root's own sixteen bytes.
            let node = indexRoot.valueOffset + 16
            if let first = NTFSIndex.firstEntryOffset(nodeHeader: record.data, at: node) {
                take(
                    NTFSIndex.entries(
                        record.data, from: first,
                        limit: min(
                            indexRoot.valueOffset + indexRoot.valueLength, record.data.count)))
            }
        }

        // And the blocks out on the disk, which is where a directory of any
        // size keeps its names.
        guard blockSize >= 512,
            let allocation = attributes.first(where: { $0.kind == .indexAllocation }),
            !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return found }

        let total = NTFSRunlist.clusterCount(runs) * UInt64(geometry.bytesPerCluster)
        var offset: UInt64 = 0
        // A directory has far fewer blocks than this; the bound stops a corrupt
        // runlist from being followed until the machine gives up.
        var guardCount = 0
        while offset + UInt64(blockSize) <= total, guardCount < 4096 {
            guardCount += 1
            defer { offset += UInt64(blockSize) }
            guard
                let placed = NTFSTable.diskOffset(
                    forFileOffset: offset, runs: runs, bytesPerCluster: geometry.bytesPerCluster),
                let raw = read(placed.offset, blockSize),
                let header = NTFSIndexBlock.header(raw, blockSize: blockSize),
                let block = NTFSIndexBlock.applyFixup(
                    raw, header: header, sectorSize: geometry.bytesPerSector)
            else { continue }
            take(
                NTFSIndex.entries(block, from: header.firstEntryOffset, limit: header.endOfEntries))
        }
        return found
    }

    /// One name in a directory, found through the tree rather than by listing
    /// it.
    ///
    /// A listing reads every block of a directory. A lookup does not have to:
    /// the entries are sorted, so each node says whether the name is here or
    /// which block to look in next. On a folder of a hundred thousand files the
    /// difference is every open of every file in it.
    public func find(_ name: String, inDirectory number: UInt64) -> UInt64? {
        guard let record = record(number), record.header.isDirectory else { return nil }
        let attributes = attributes(of: record)

        var blockSize = 0
        var next: UInt64?

        // The root of the tree, in the record itself.
        if let indexRoot = attributes.first(where: { $0.kind == .indexRoot }), indexRoot.isResident
        {
            let value = record.data.startIndex + indexRoot.valueOffset
            guard value + 16 <= record.data.endIndex else { return nil }
            for i in 0..<4 { blockSize |= Int(record.data[value + 8 + i]) << (8 * i) }
            let node = indexRoot.valueOffset + 16
            guard let first = NTFSIndex.firstEntryOffset(nodeHeader: record.data, at: node)
            else { return nil }
            let entries = NTFSIndex.entries(
                record.data, from: first,
                limit: min(indexRoot.valueOffset + indexRoot.valueLength, record.data.count))
            switch NTFSIndex.find(name, in: entries) {
            case .found(let entry): return entry.record
            case .descend(let block): next = block
            case .absent: return nil
            }
        }

        // Then down through the blocks on the disk.
        guard blockSize >= 512,
            let allocation = attributes.first(where: { $0.kind == .indexAllocation }),
            !allocation.isResident,
            let runs = NTFSRunlist.decode(
                record.data, at: allocation.runlistOffset, limit: record.data.count)
        else { return nil }

        // A B-tree of any plausible depth is far shallower than this; the bound
        // stops a corrupt tree whose blocks point at each other from being
        // followed for ever.
        var depth = 0
        while let block = next, depth < 64 {
            depth += 1
            guard let offset = NTFSIndexBlock.offsetOfBlock(block, blockSize: blockSize),
                let placed = NTFSTable.diskOffset(
                    forFileOffset: offset, runs: runs, bytesPerCluster: geometry.bytesPerCluster),
                let raw = read(placed.offset, blockSize),
                let header = NTFSIndexBlock.header(raw, blockSize: blockSize),
                let node = NTFSIndexBlock.applyFixup(
                    raw, header: header, sectorSize: geometry.bytesPerSector)
            else { return nil }
            let entries = NTFSIndex.entries(
                node, from: header.firstEntryOffset, limit: header.endOfEntries)
            switch NTFSIndex.find(name, in: entries) {
            case .found(let entry): return entry.record
            case .descend(let child):
                // A block that points at itself, or back up the tree, would
                // otherwise be followed until the bound above stops it.
                guard child != block else { return nil }
                next = child
            case .absent: return nil
            }
        }
        return nil
    }

    // MARK: - Files

    /// Whether a record's attributes spill into other records.
    ///
    /// A badly fragmented file, or one with many named streams, can have more
    /// attributes than a single record holds. NTFS then writes an
    /// `$ATTRIBUTE_LIST` saying which records the rest are in, and the record
    /// somebody looks at first may hold no `$DATA` at all.
    ///
    /// This reader does not follow that list. What it must not do is treat the
    /// absence as an empty file: a fragmented file reported as zero bytes is
    /// data loss that looks like a successful read. Saying so lets every caller
    /// refuse rather than each one having to notice.
    public func spillsAttributes(_ record: (data: Data, header: NTFSRecord.Header)) -> Bool {
        attributes(of: record).contains { $0.kind == .attributeList }
    }

    /// How long a file is.
    public func size(ofFile number: UInt64) -> UInt64? {
        guard let record = record(number), !spillsAttributes(record),
            let data = attributes(of: record).first(where: { $0.kind == .data })
        else { return nil }
        return data.dataSize
    }

    /// A file's contents, or the part of them asked for.
    public func contents(ofFile number: UInt64, offset: UInt64 = 0, length: Int? = nil) -> Data? {
        contents(ofFile: number, attribute: .data, offset: offset, length: length)
    }

    /// The contents of any one attribute of a record.
    ///
    /// `$DATA` is the file's bytes and is what almost everything wants, but not
    /// everything. `$MFT` keeps a `$BITMAP` saying which records exist, and a
    /// directory keeps its entries in `$INDEX_ALLOCATION` -- both are read the
    /// same way as a file, because on NTFS they are files: an attribute with a
    /// runlist and clusters behind it.
    public func contents(
        ofFile number: UInt64, attribute kind: NTFSAttribute.Kind, offset: UInt64 = 0,
        length: Int? = nil
    ) -> Data? {
        guard let record = record(number), !spillsAttributes(record),
            let data = attributes(of: record).first(where: { $0.kind == kind })
        else { return nil }
        // A compressed or encrypted attribute's clusters do not hold the file's
        // contents. Handing them over returns garbage with nothing reporting a
        // fault, which is worse than refusing: a refusal is visible, and a file
        // full of noise looks like a damaged drive.
        guard data.isReadableAsIs else { return nil }
        let wanted = length ?? Int(data.dataSize)

        if data.isResident {
            guard
                let range = NTFSFileData.residentRange(
                    data, offset: Int(offset), length: wanted, recordSize: record.data.count)
            else { return Data() }
            let start = record.data.startIndex
            return record.data[start + range.lowerBound..<start + range.upperBound]
        }

        guard
            let runs = NTFSRunlist.decode(
                record.data, at: data.runlistOffset, limit: record.data.count),
            let pieces = NTFSFileData.pieces(
                offset: offset, length: wanted, runs: runs,
                bytesPerCluster: geometry.bytesPerCluster, size: data.dataSize)
        else { return nil }

        var out = Data()
        out.reserveCapacity(NTFSFileData.totalLength(pieces))
        for piece in pieces {
            switch piece {
            case .zeroes(let length):
                out.append(Data(count: length))
            case .disk(let at, let length):
                guard let chunk = read(at, length), chunk.count == length else { return nil }
                out.append(chunk)
            }
        }
        return out
    }
}
