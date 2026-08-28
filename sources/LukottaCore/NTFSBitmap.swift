// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Which clusters of a volume are in use.
///
/// `$Bitmap` is one bit per cluster, in use or free, and it is the structure a
/// write path stands on: allocating a cluster means finding a zero bit, and
/// getting that wrong hands out a cluster that already holds somebody's file.
/// Every other kind of mistake in this reader misreads a drive; this one
/// destroys it.
///
/// **The bit order is the thing to get right.** Bit 0 of byte 0 is cluster 0,
/// bit 1 is cluster 1, and so on -- least significant bit first within each
/// byte. Reading it most-significant-first gives a bitmap that is right about
/// how *many* clusters are free and wrong about *which*, which is the worst
/// possible shape for the error: the volume looks healthy and the allocations
/// land on other people's data.
///
/// Reading only. Nothing here sets a bit, because nothing yet has the right to.
public enum NTFSBitmap {

    /// Whether a cluster is in use.
    ///
    /// - Returns: nil when the bitmap does not cover that cluster, which is a
    ///   different thing from "free" and must not be confused with it. A caller
    ///   that treats absent as free allocates past the end of the volume.
    public static func isInUse(cluster: UInt64, bitmap: Data) -> Bool? {
        let byteIndex = Int(cluster / 8)
        guard byteIndex >= 0, byteIndex < bitmap.count else { return nil }
        let bit = UInt8(cluster % 8)
        let byte = bitmap[bitmap.startIndex + byteIndex]
        return byte & (1 << bit) != 0
    }

    /// How many clusters the bitmap describes.
    ///
    /// The bitmap is rounded up to a whole number of bytes, so the last few
    /// bits may describe clusters the volume does not have. The volume's own
    /// count is what bounds a search, not this.
    public static func capacity(of bitmap: Data) -> UInt64 {
        UInt64(bitmap.count) * 8
    }

    /// The first run of free clusters at least this long, if there is one.
    ///
    /// - Parameters:
    ///   - count: how many contiguous clusters are wanted.
    ///   - totalClusters: the volume's own count. Bits past it exist in the
    ///     bitmap and describe nothing; allocating one writes past the end of
    ///     the partition.
    ///   - from: where to start looking. A write path keeps a hint here so that
    ///     filling a volume does not rescan from zero every time.
    /// - Returns: the first cluster of a free run, or nil when the volume has
    ///   no room. Nil means full, and is not an error.
    public static func firstFreeRun(
        count: UInt64, in bitmap: Data, totalClusters: UInt64, from start: UInt64 = 0
    ) -> UInt64? {
        guard count > 0, totalClusters > 0, start < totalClusters else { return nil }
        var run: UInt64 = 0
        var cluster = start
        while cluster < totalClusters {
            guard let used = isInUse(cluster: cluster, bitmap: bitmap) else { break }
            if used {
                run = 0
            } else {
                run += 1
                if run == count { return cluster - count + 1 }
            }
            cluster += 1
        }
        return nil
    }

    /// How many clusters are free, up to the volume's own count.
    ///
    /// Counted rather than trusted from anywhere else: this is the number
    /// Finder shows as free space, and the bits past the end of the volume must
    /// not be counted among them.
    public static func freeClusters(in bitmap: Data, totalClusters: UInt64) -> UInt64 {
        var free: UInt64 = 0
        var cluster: UInt64 = 0
        while cluster < totalClusters {
            guard let used = isInUse(cluster: cluster, bitmap: bitmap) else { break }
            if !used { free += 1 }
            cluster += 1
        }
        return free
    }

    /// Whether every cluster a runlist names is marked in use.
    ///
    /// Nothing calls this on a mounted volume -- it walks the whole runlist --
    /// but it is what a write path would check before trusting an allocation,
    /// and what a check can use to establish that a file's clusters really are
    /// claimed rather than merely pointed at.
    public static func allInUse(
        _ runs: [NTFSRunlist.Run], bitmap: Data, totalClusters: UInt64
    ) -> Bool {
        for run in runs {
            guard let physical = run.physicalCluster else { continue }
            for offset in 0..<run.clusterCount {
                let cluster = physical + offset
                guard cluster < totalClusters,
                    isInUse(cluster: cluster, bitmap: bitmap) == true
                else { return false }
            }
        }
        return true
    }
}
