// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Where a file's contents actually are on the disk.
///
/// A non-resident attribute holds a runlist: the extents of the file, packed as
/// tightly as NTFS could manage. Each entry is a header byte giving the size of
/// the two numbers that follow -- low nibble for the length, high nibble for the
/// offset -- then the length in clusters, then the offset of the run's first
/// cluster **relative to the previous run's**. A zero header byte ends the list.
///
/// The relative offset is the part that catches people. Runs are not absolute
/// and not ascending: a file written over time scatters, and a later run can sit
/// before an earlier one, which is what the signed delta is for. Decoding it as
/// unsigned gives extents pointing at the wrong end of the disk, which reads as
/// a file full of somebody else's data rather than as an error.
///
/// A run with no offset at all is a hole -- a sparse file's unwritten middle,
/// which reads as zeroes and occupies nothing. FSKit has a name for this:
/// `FSExtentTypeZeroFill`, the other half of `FSExtentType`.
///
/// This is what feeds kernel-offloaded I/O. `FSExtentPacker.packExtent` wants a
/// physical offset and a length on a block device, and that is exactly a decoded
/// run (architecture.md §15).
public enum NTFSRunlist {

    /// One extent of a file.
    public struct Run: Sendable, Equatable {
        /// Where in the file this run begins, in clusters.
        public let logicalCluster: UInt64
        /// Where on the disk it begins. Nil for a hole, which occupies nothing
        /// and reads as zeroes.
        public let physicalCluster: UInt64?
        /// How many clusters long.
        public let clusterCount: UInt64

        public init(logicalCluster: UInt64, physicalCluster: UInt64?, clusterCount: UInt64) {
            self.logicalCluster = logicalCluster
            self.physicalCluster = physicalCluster
            self.clusterCount = clusterCount
        }

        public var isHole: Bool { physicalCluster == nil }
    }

    /// Decode a runlist.
    ///
    /// - Parameters:
    ///   - data: the record the runlist sits in.
    ///   - offset: where in it the runlist starts.
    ///   - limit: the first byte past the attribute. Nothing is read at or
    ///     beyond it, whatever the runlist claims.
    /// - Returns: the runs, or nil when the list is malformed. Nil rather than
    ///   a partial list: half a file's extents is a file that reads as
    ///   truncated, which is worse than one that refuses to open.
    /// The largest cluster number this reader will accept.
    ///
    /// Every consumer of a run multiplies its cluster number by the cluster
    /// size to get a byte offset, and on UInt64 an overflow is a trap rather
    /// than a wrong answer -- the extension dies instead of refusing the drive.
    /// A runlist can encode a cluster number up to 64 bits wide, so the bound
    /// has to be here, where the numbers are made, rather than at each of the
    /// eleven places they are used.
    ///
    /// 2^48 clusters is 1 exabyte at 4 KB, which is far past any volume and far
    /// short of overflowing when multiplied by any cluster size NTFS permits.
    public static let maximumCluster: UInt64 = 1 << 48

    public static func decode(_ data: Data, at offset: Int, limit: Int) -> [Run]? {
        let base = data.startIndex
        guard offset >= 0, limit <= data.count, offset < limit else { return nil }

        var runs: [Run] = []
        var cursor = offset
        var previousPhysical: Int64 = 0
        var logical: UInt64 = 0

        // A file has far fewer extents than this. The bound stops a corrupt
        // list from being decoded until memory runs out.
        while runs.count < 65536 {
            guard cursor < limit else { return nil }
            let control = Int(data[base + cursor])
            cursor += 1
            // Zero ends the list. This is the only clean way out.
            if control == 0 { return runs }

            let lengthBytes = control & 0x0F
            let offsetBytes = (control >> 4) & 0x0F
            // A length of no bytes is a run of unknown size: meaningless, and a
            // sign the bytes are not a runlist at all.
            guard lengthBytes >= 1, lengthBytes <= 8, offsetBytes <= 8 else { return nil }
            guard cursor + lengthBytes + offsetBytes <= limit else { return nil }

            var count: UInt64 = 0
            for i in 0..<lengthBytes {
                count |= UInt64(data[base + cursor + i]) << (8 * UInt64(i))
            }
            cursor += lengthBytes
            guard count > 0, count < maximumCluster else { return nil }
            // The file's own extent has to stay inside the same bound: a run
            // starting low and running for 2^63 clusters overflows just as
            // surely as one starting high.
            guard logical < maximumCluster, logical + count <= maximumCluster else { return nil }

            if offsetBytes == 0 {
                // A hole. It advances the file's position and points nowhere.
                runs.append(
                    Run(logicalCluster: logical, physicalCluster: nil, clusterCount: count))
                logical += count
                continue
            }

            // Signed, and sign-extended from however many bytes it was written
            // in. A later run may sit before an earlier one.
            var delta: Int64 = 0
            for i in 0..<offsetBytes {
                delta |= Int64(data[base + cursor + i]) << (8 * Int64(i))
            }
            let signBit: Int64 = 1 << (8 * Int64(offsetBytes) - 1)
            if delta & signBit != 0 {
                delta -= 1 << (8 * Int64(offsetBytes))
            }
            cursor += offsetBytes

            let physical = previousPhysical + delta
            // A run before the start of the disk is not a run, and one past
            // what any volume can hold would overflow when it is turned into a
            // byte offset -- which traps rather than answering wrongly.
            guard physical >= 0, UInt64(physical) < maximumCluster else { return nil }
            previousPhysical = physical

            runs.append(
                Run(
                    logicalCluster: logical, physicalCluster: UInt64(physical),
                    clusterCount: count))
            logical += count
        }
        return nil
    }

    /// How many clusters the runs cover, holes included.
    public static func clusterCount(_ runs: [Run]) -> UInt64 {
        runs.reduce(0) { $0 + $1.clusterCount }
    }

    /// Whether the runs cover a file of this many clusters, exactly.
    ///
    /// A runlist that covers less than the attribute claims is a truncated
    /// file; one that covers more has an entry that does not belong to it.
    /// Either way the file should not be read.
    public static func covers(_ runs: [Run], clusters: UInt64) -> Bool {
        clusterCount(runs) == clusters
    }
}
