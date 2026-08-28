// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Writing into clusters a file already owns.
///
/// This is the smallest write that is worth anything and the only one that is
/// safe to do first: the bytes go where the file's runlist already points, and
/// nothing about the volume's structure changes. No cluster is allocated, no
/// bitmap bit is set, no record is created, no directory index is touched, and
/// `$LogFile` has nothing to journal because there is no metadata change to
/// undo. A power cut in the middle leaves a file with some old bytes and some
/// new ones, which is what a power cut during a write to any filesystem leaves.
///
/// Everything harder -- growing a file, creating one, deleting one -- means
/// changing structures that must agree with each other, and a failure between
/// two of those changes leaves a volume that chkdsk has to repair. None of that
/// is here.
///
/// **What this refuses is more important than what it does.** A write outside
/// the file's own extents, or into a hole, or past its end, is a write onto
/// somebody else's data. Each is refused rather than clamped, because a clamped
/// write silently stores less than was asked for and the caller has no way to
/// know which bytes made it.
public enum NTFSFileWrite {

    /// One piece of a write: bytes, and where on the disk they go.
    public struct Piece: Sendable, Equatable {
        public let diskOffset: UInt64
        public let range: Range<Int>

        public init(diskOffset: UInt64, range: Range<Int>) {
            self.diskOffset = diskOffset
            self.range = range
        }
    }

    /// Work out where a write lands, or refuse it.
    ///
    /// - Parameters:
    ///   - offset: where in the file the write starts.
    ///   - length: how many bytes.
    ///   - runs: the file's extents.
    ///   - size: the file's current length. Nothing may be written past it:
    ///     growing a file means allocating, and allocating is not here.
    /// - Returns: the pieces, in order, or nil when the write cannot be made
    ///   exactly as asked.
    public static func pieces(
        offset: UInt64, length: Int, runs: [NTFSRunlist.Run], bytesPerCluster: Int,
        size: UInt64
    ) -> [Piece]? {
        guard bytesPerCluster > 0, length > 0 else { return nil }
        // Past the end means growing the file, which means allocating.
        guard offset <= size, UInt64(length) <= size - offset else { return nil }

        var pieces: [Piece] = []
        var position = offset
        var written = 0
        let clusterSize = UInt64(bytesPerCluster)

        while written < length {
            guard
                let run = runs.first(where: {
                    let start = $0.logicalCluster * clusterSize
                    return position >= start && position < start + $0.clusterCount * clusterSize
                })
            else { return nil }

            // A hole has no clusters behind it. Writing into one means
            // allocating them, which is not here -- and pretending otherwise
            // would drop the bytes silently.
            guard let physical = run.physicalCluster else { return nil }

            let runStart = run.logicalCluster * clusterSize
            let into = position - runStart
            let leftInRun = run.clusterCount * clusterSize - into
            let take = Int(min(UInt64(length - written), leftInRun))

            pieces.append(
                Piece(
                    diskOffset: physical * clusterSize + into,
                    range: written..<(written + take)))
            position += UInt64(take)
            written += take
        }
        return pieces
    }

    /// Where a resident file's bytes are, for a write that stays inside the
    /// record.
    ///
    /// A small file's contents live in its record, so writing them means
    /// writing the record back -- which is a metadata write, and touches the
    /// fixup. Refused here for that reason: the caller is told the file cannot
    /// be written this way rather than being handed an offset that would
    /// corrupt a record.
    public static func residentIsWritable(_ attribute: NTFSAttribute.Header) -> Bool {
        false
    }

    /// Whether a write may be attempted at all.
    ///
    /// Every one of these is a way to destroy a volume rather than to fail a
    /// write, so they are asked before anything is composed.
    public static func isAllowed(
        attribute: NTFSAttribute.Header, volumeIsClean: Bool, volumeIsWritable: Bool
    ) -> Bool {
        guard volumeIsClean, volumeIsWritable else { return false }
        // A compressed or encrypted attribute's clusters do not hold the file's
        // bytes; writing plaintext into them destroys the file.
        guard attribute.isReadableAsIs else { return false }
        // A resident file means rewriting its record.
        guard !attribute.isResident else { return false }
        return true
    }
}
