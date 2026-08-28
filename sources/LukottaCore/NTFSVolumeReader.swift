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
        state()?.isSafeToWrite ?? false
    }

    // MARK: - Records

    /// One record, repaired, with its header.
    public func record(_ number: UInt64) -> (data: Data, header: NTFSRecord.Header)? {
        guard
            NTFSTable.isWithin(
                record: number, tableSizeInBytes: tableSize,
                bytesPerFileRecord: geometry.bytesPerFileRecord)
        else { return nil }
        guard
            let inTable = NTFSTable.offsetInTable(
                record: number, bytesPerFileRecord: geometry.bytesPerFileRecord),
            let placed = NTFSTable.diskOffset(
                forFileOffset: inTable, runs: mftRuns, bytesPerCluster: geometry.bytesPerCluster),
            placed.availableBytes >= UInt64(geometry.bytesPerFileRecord),
            let raw = read(placed.offset, geometry.bytesPerFileRecord),
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
        guard let record = record(number), !spillsAttributes(record),
            let data = attributes(of: record).first(where: { $0.kind == .data })
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
