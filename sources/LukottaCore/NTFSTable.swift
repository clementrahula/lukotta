// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Finding a record in the master file table by its number.
///
/// Every file on an NTFS volume is a record number, and everything that refers
/// to a file -- a directory entry, a parent, a hard link -- refers to it by that
/// number. So this is the operation the rest of a reader is built on: given a
/// number, say where on the disk its record is.
///
/// The table is itself a file. Its records are laid out one after another from
/// its start, so the arithmetic is a multiplication -- but the file is
/// fragmented like any other, so the byte offset only means anything through
/// `$MFT`'s own runlist. Reading record 500,000 of a fragmented table at
/// `start + 500000 * recordSize` reads whatever else happens to be on the disk
/// there.
///
/// Record numbers 0 to 15 are the metadata files NTFS keeps for itself. 0 is
/// `$MFT`, 5 is the root directory, and the volume cannot be read without both.
///
/// Nothing here does I/O. It says where to read.
public enum NTFSTable {

    /// The records NTFS reserves for its own use.
    public static let reservedRecords: UInt64 = 16
    /// `$MFT` itself.
    public static let mftRecord: UInt64 = 0
    /// The root directory. Every path starts here.
    public static let rootRecord: UInt64 = 5

    /// Where a record sits inside the table, as a byte offset into the table
    /// *as a file* rather than into the disk.
    public static func offsetInTable(
        record: UInt64, bytesPerFileRecord: Int
    ) -> UInt64? {
        guard bytesPerFileRecord > 0 else { return nil }
        let (offset, overflow) = record.multipliedReportingOverflow(
            by: UInt64(bytesPerFileRecord))
        return overflow ? nil : offset
    }

    /// Turn an offset inside a file into an offset on the disk, using the
    /// file's runs.
    ///
    /// This is the step that a reader assuming a contiguous table gets wrong.
    /// It answers nil for an offset that falls in a hole -- a sparse file's
    /// unwritten middle, which has no disk address at all and reads as zeroes.
    ///
    /// - Returns: the byte offset on the disk, and how many bytes remain in the
    ///   run from there. A caller that wants more than that has to continue
    ///   into the next run rather than reading past the end of this one.
    public static func diskOffset(
        forFileOffset fileOffset: UInt64, runs: [NTFSRunlist.Run], bytesPerCluster: Int
    ) -> (offset: UInt64, availableBytes: UInt64)? {
        guard bytesPerCluster > 0 else { return nil }
        let clusterSize = UInt64(bytesPerCluster)

        for run in runs {
            let runStart = run.logicalCluster * clusterSize
            let runLength = run.clusterCount * clusterSize
            guard fileOffset >= runStart, fileOffset < runStart + runLength else { continue }
            // A hole has no address on the disk. Reading one means producing
            // zeroes, which is the caller's job and not a byte offset.
            guard let physical = run.physicalCluster else { return nil }
            let into = fileOffset - runStart
            return (physical * clusterSize + into, runLength - into)
        }
        return nil
    }

    /// Whether a record number could exist on a table of this size.
    ///
    /// A directory entry naming a record past the end of the table is corrupt,
    /// and following it reads whatever is on the disk after the table.
    public static func isWithin(
        record: UInt64, tableSizeInBytes: UInt64, bytesPerFileRecord: Int
    ) -> Bool {
        guard bytesPerFileRecord > 0 else { return false }
        guard let offset = offsetInTable(record: record, bytesPerFileRecord: bytesPerFileRecord)
        else { return false }
        return offset + UInt64(bytesPerFileRecord) <= tableSizeInBytes
    }

    /// A file reference as NTFS writes one: 48 bits of record number, 16 of
    /// sequence number.
    ///
    /// The sequence number counts how many times the record has been reused. It
    /// is what makes a stale reference detectable rather than silently pointing
    /// at whatever file took the slot over, so it is kept rather than masked
    /// away and forgotten.
    public static func reference(_ raw: UInt64) -> (record: UInt64, sequence: UInt16) {
        (raw & 0x0000_FFFF_FFFF_FFFF, UInt16(truncatingIfNeeded: raw >> 48))
    }
}
