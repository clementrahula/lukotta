// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Putting a record of the master file table back on the disk.
///
/// Two things make this harder than writing the bytes where they came from.
///
/// **The fixup has to go back on.** A record in memory has the bytes NTFS
/// displaced put back; a record on the disk has the volume's signature at the
/// end of every sector instead, and the displaced bytes in an array at the
/// front. A record written without that is read by the next reader -- ours,
/// Windows's, chkdsk's -- as a torn write and refused. That is a file that
/// vanishes.
///
/// **The first few records exist twice.** `$MFTMirr` holds a copy of the
/// beginning of the table, so that a volume whose first records are damaged can
/// still be understood: without record 0 the table cannot be found at all, and
/// the mirror is the only way back. Measured on a real volume, it covers
/// records 0 to 3 -- `$MFT`, `$MFTMirr`, `$LogFile` and `$Volume`. `$Volume` is
/// where the dirty flag lives, so *the very first write this filesystem makes
/// is one that must go to two places.* Writing one copy leaves the two
/// disagreeing, which is exactly what chkdsk looks for.
///
/// Nothing here does I/O. It says what bytes go where, and the caller puts them
/// down -- which is what lets both halves be checked without a disk.
public enum NTFSRecordWrite {

    /// `$MFTMirr` is record 1, always.
    public static let mirrorRecord: UInt64 = 1

    /// One place a record has to go.
    public struct Destination: Sendable, Equatable {
        public let offset: UInt64
        /// Whether this is the copy in `$MFTMirr` rather than in `$MFT`. Only
        /// for saying so in a log or a test; the bytes are the same.
        public let isMirror: Bool

        public init(offset: UInt64, isMirror: Bool) {
            self.offset = offset
            self.isMirror = isMirror
        }
    }

    /// Every place a record has to be written.
    ///
    /// - Parameters:
    ///   - number: which record.
    ///   - tableOffset: where it lies in `$MFT`, which only the reader knows,
    ///     because the table can be in several pieces.
    ///   - mirrorOffset: where `$MFTMirr` begins. The boot sector says, and
    ///     that is the pointer chkdsk itself follows.
    ///   - mirrorLength: how many bytes the mirror holds. Records past it are
    ///     not mirrored and must not be written there -- that would be writing
    ///     over whatever comes after.
    /// - Returns: one destination, or two, or nil when the record is not
    ///   somewhere it can be written. Nil is a refusal, not an empty list: a
    ///   caller that writes to no destinations and reports success has lost the
    ///   change silently.
    public static func destinations(
        record number: UInt64, tableOffset: UInt64, mirrorOffset: UInt64,
        mirrorLength: UInt64, bytesPerFileRecord: Int
    ) -> [Destination]? {
        guard bytesPerFileRecord > 0 else { return nil }
        let size = UInt64(bytesPerFileRecord)
        var places = [Destination(offset: tableOffset, isMirror: false)]

        // The mirror holds the first records and no more. A record beyond it is
        // simply not mirrored, which is normal and not a fault.
        let mirrored = mirrorLength / size
        if number < mirrored {
            guard number <= (UInt64.max - mirrorOffset) / size else { return nil }
            places.append(
                Destination(offset: mirrorOffset + number * size, isMirror: true))
        }
        return places
    }

    /// Turn a record held in memory into the bytes that go on the disk.
    ///
    /// The signature moves on with every write, which is the point of the
    /// scheme: a record caught half-written has some sectors carrying the old
    /// signature and some the new, and the mismatch is what makes it detectable
    /// rather than plausible.
    ///
    /// - Returns: nil when the record cannot be laid out -- a fixup array that
    ///   does not fit, a sector size that makes no sense. Refusing beats
    ///   writing a record that the next reader will refuse.
    public static func onDisk(
        _ record: Data, header: NTFSRecord.Header, sectorSize: Int
    ) -> Data? {
        guard record.count >= header.fixupOffset + 2 else { return nil }
        let start = record.startIndex + header.fixupOffset
        let current = UInt16(record[start]) | (UInt16(record[start + 1]) << 8)
        return NTFSRecord.removeFixup(
            record, header: header, signature: NTFSRecord.nextSignature(after: current),
            sectorSize: sectorSize)
    }
}
