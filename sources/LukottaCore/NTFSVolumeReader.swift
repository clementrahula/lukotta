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

    // MARK: - Files

    /// How long a file is.
    public func size(ofFile number: UInt64) -> UInt64? {
        guard let record = record(number),
            let data = attributes(of: record).first(where: { $0.kind == .data })
        else { return nil }
        return data.dataSize
    }

    /// A file's contents, or the part of them asked for.
    public func contents(ofFile number: UInt64, offset: UInt64 = 0, length: Int? = nil) -> Data? {
        guard let record = record(number),
            let data = attributes(of: record).first(where: { $0.kind == .data })
        else { return nil }
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
