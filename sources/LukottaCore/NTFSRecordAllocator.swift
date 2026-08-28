// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Choosing which record of the master file table a new file should take.
///
/// `$MFT` keeps a `$BITMAP` attribute with one bit per record: set means the
/// record describes a file that exists, clear means the slot is free. It is the
/// same layout as `$Bitmap` uses for clusters, so the bit arithmetic is
/// `NTFSBitmap`'s and only the meaning of the number changes.
///
/// **The first records are not available.** Records 0 to 15 are the volume's
/// own files -- `$MFT`, `$MFTMirr`, `$LogFile`, `$Volume`, `$AttrDef`, the root
/// directory, `$Bitmap`, `$Boot`, `$BadClus`, `$Secure`, `$UpCase`, `$Extend`
/// -- and 16 to 23 are held in reserve by every implementation that writes
/// NTFS. Handing one out would be handing out a slot Windows expects to find
/// where it left it.
///
/// Nothing here writes. It says which record to take and what the bitmap would
/// become, and the caller commits both.
public enum NTFSRecordAllocator {

    /// The first record a file may be given.
    ///
    /// Sixteen system files, then eight held in reserve. ntfs-3g and Windows
    /// both begin here, so a volume written by this one looks to them like a
    /// volume written by themselves.
    public static let firstAvailable: UInt64 = 24

    public struct Choice: Sendable, Equatable {
        public let record: UInt64
        /// The bitmap as it would be with that record taken.
        public let bitmap: Data

        public init(record: UInt64, bitmap: Data) {
            self.record = record
            self.bitmap = bitmap
        }
    }

    /// Find a free record.
    ///
    /// - Parameters:
    ///   - bitmap: `$MFT`'s `$BITMAP` attribute, whole.
    ///   - recordCount: how many records the table actually holds, which is its
    ///     length divided by the record size. The bitmap is rounded up to a
    ///     byte and often further, so its last bits describe records that do
    ///     not exist -- handing one out is handing out a slot past the end of
    ///     the table.
    ///   - near: where to start looking.
    /// - Returns: nil when there is no free record. That means the table is
    ///   full and must grow, which is an allocation and a runlist change, and
    ///   is not here. Nil is "no room", which is a full disk and not a fault.
    public static func choose(
        in bitmap: Data, recordCount: UInt64, near hint: UInt64 = firstAvailable
    ) -> Choice? {
        // From the hint, then from the beginning, in case the hint was past
        // the last free record. The search only ever goes forwards, so a hint
        // pointing into the reserve is raised rather than followed -- and
        // nothing below `firstAvailable` can come back from either pass.
        //
        // The bound is `recordCount` and it is stated once, in the search and
        // in the claim. Stating it twice reads as two rules and is one, and the
        // spare version is never the reason for any refusal.
        for start in [max(hint, firstAvailable), firstAvailable] where start < recordCount {
            guard
                let found = NTFSBitmap.firstFreeRun(
                    count: 1, in: bitmap, totalClusters: recordCount, from: start),
                let taken = NTFSBitmap.claiming(
                    found, count: 1, in: bitmap, totalClusters: recordCount)
            else { continue }
            return Choice(record: found, bitmap: taken)
        }
        return nil
    }

    /// The bitmap with a record given back.
    ///
    /// A system record is never released, whatever is asked: clearing one of
    /// those bits tells the next allocation that `$MFT` itself is free.
    public static func releasing(_ record: UInt64, in bitmap: Data, recordCount: UInt64) -> Data? {
        guard record >= firstAvailable, record < recordCount else { return nil }
        return NTFSBitmap.releasing(record, count: 1, in: bitmap, totalClusters: recordCount)
    }

    /// Whether a record is in use, as the bitmap sees it.
    ///
    /// The record's own header carries an in-use flag too, and the two can
    /// disagree on a volume that was interrupted. Neither is authoritative on
    /// its own, which is why a caller wanting to know whether a file exists
    /// should ask both.
    public static func isInUse(_ record: UInt64, in bitmap: Data) -> Bool? {
        NTFSBitmap.isInUse(cluster: record, bitmap: bitmap)
    }
}
