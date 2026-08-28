// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Choosing which clusters a file should take.
///
/// `NTFSBitmap` says whether a run may be claimed and hands back a new bitmap.
/// This decides *which* run to ask for, and it is a decision with consequences
/// that outlive the write: clusters chosen badly are a file scattered across a
/// disk, which costs a seek per fragment for the rest of that file's life and
/// grows the runlist until it no longer fits its record.
///
/// **Nothing here writes.** It produces a plan -- a set of runs, and the bitmap
/// as it would be -- and the caller commits it. That separation is deliberate:
/// a plan can be checked, discarded, or written in one go, and an allocator
/// that changed the bitmap as it searched would leave the disk disagreeing with
/// memory at every step of a search that might yet fail.
public enum NTFSAllocator {

    /// What an allocation came to.
    public struct Plan: Sendable, Equatable {
        /// The runs to give the file, in order.
        public let runs: [NTFSRunlist.Run]
        /// The bitmap as it would be once these are claimed.
        public let bitmap: Data

        public init(runs: [NTFSRunlist.Run], bitmap: Data) {
            self.runs = runs
            self.bitmap = bitmap
        }

        /// How many clusters the plan covers.
        public var clusterCount: UInt64 { NTFSRunlist.clusterCount(runs) }
        /// How many separate pieces the file would be in. One is ideal; a
        /// number that grows is a file being scattered.
        public var fragments: Int { runs.count }
    }

    /// Find room for a file, preferring as few pieces as possible.
    ///
    /// Tries for one run first. Where the volume has no single stretch long
    /// enough, takes the longest stretches it can find rather than the first
    /// ones -- a file in three large pieces reads far better than one in thirty
    /// small ones, and the runlist stays short enough to fit its record.
    ///
    /// - Parameters:
    ///   - clusters: how many are needed.
    ///   - near: where to start looking. A file being extended should start
    ///     from where it already ends, so the new clusters sit beside the old.
    ///   - maximumFragments: refuse rather than scatter a file beyond this. A
    ///     runlist that outgrows its record needs an `$ATTRIBUTE_LIST`, which
    ///     does not exist here, so producing one would be producing a file that
    ///     cannot be written down.
    /// - Returns: nil when the volume cannot take the file in few enough
    ///   pieces. Nil is "no room", which is a full disk and not a fault.
    public static func plan(
        clusters: UInt64, in bitmap: Data, totalClusters: UInt64,
        near hint: UInt64 = 0, maximumFragments: Int = 16
    ) -> Plan? {
        guard clusters > 0, totalClusters > 0, maximumFragments > 0 else { return nil }

        // One run, from the hint, is the best case and the common one.
        if let start = NTFSBitmap.firstFreeRun(
            count: clusters, in: bitmap, totalClusters: totalClusters, from: hint),
            let claimed = NTFSBitmap.claiming(
                start, count: clusters, in: bitmap, totalClusters: totalClusters)
        {
            return Plan(
                runs: [
                    NTFSRunlist.Run(
                        logicalCluster: 0, physicalCluster: start, clusterCount: clusters)
                ],
                bitmap: claimed)
        }
        // And from the beginning, in case the hint was past the free space.
        if hint > 0,
            let start = NTFSBitmap.firstFreeRun(
                count: clusters, in: bitmap, totalClusters: totalClusters),
            let claimed = NTFSBitmap.claiming(
                start, count: clusters, in: bitmap, totalClusters: totalClusters)
        {
            return Plan(
                runs: [
                    NTFSRunlist.Run(
                        logicalCluster: 0, physicalCluster: start, clusterCount: clusters)
                ],
                bitmap: claimed)
        }

        // Otherwise take the largest stretches available, longest first, so the
        // file ends up in as few pieces as the volume allows.
        var stretches = freeStretches(in: bitmap, totalClusters: totalClusters)
        stretches.sort { $0.count > $1.count }

        var runs: [NTFSRunlist.Run] = []
        var working = bitmap
        var remaining = clusters
        var logical: UInt64 = 0

        for stretch in stretches {
            guard remaining > 0 else { break }
            guard runs.count < maximumFragments else { break }
            let take = min(remaining, stretch.count)
            guard
                let claimed = NTFSBitmap.claiming(
                    stretch.start, count: take, in: working, totalClusters: totalClusters)
            else { continue }
            working = claimed
            runs.append(
                NTFSRunlist.Run(
                    logicalCluster: logical, physicalCluster: stretch.start, clusterCount: take))
            logical += take
            remaining -= take
        }

        // All of it, or none. A file half allocated is worse than one refused:
        // the clusters are gone and nothing owns them.
        guard remaining == 0 else { return nil }
        return Plan(runs: runs, bitmap: working)
    }

    /// Every stretch of free clusters on the volume.
    ///
    /// Walks the whole bitmap, which on a 4 GB volume is 128 KB and on a 4 TB
    /// one is 128 MB. That is why an allocator keeps a hint and tries a single
    /// run first: this is the slow path and should be reached rarely.
    public static func freeStretches(
        in bitmap: Data, totalClusters: UInt64
    ) -> [(start: UInt64, count: UInt64)] {
        var stretches: [(start: UInt64, count: UInt64)] = []
        var runStart: UInt64?
        var cluster: UInt64 = 0

        while cluster < totalClusters {
            guard let used = NTFSBitmap.isInUse(cluster: cluster, bitmap: bitmap) else { break }
            if used {
                if let start = runStart {
                    stretches.append((start, cluster - start))
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = cluster
            }
            cluster += 1
        }
        if let start = runStart, cluster > start {
            stretches.append((start, cluster - start))
        }
        return stretches
    }
}
