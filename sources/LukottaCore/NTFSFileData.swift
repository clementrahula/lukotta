// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Reading a file's contents.
///
/// Two entirely different things wear the same name. A small file's `$DATA` is
/// *resident*: its bytes sit inside the file record, and reading it is a copy
/// out of memory already held. A large one's is *non-resident*: the attribute
/// holds a runlist, and reading it means going to the disk at the places those
/// runs name.
///
/// This works out what to read and from where. It performs no I/O itself --
/// the caller does that, because on a mounted volume the reads go through
/// `FSBlockDeviceResource` and in a test they go through a file handle, and
/// neither belongs in the arithmetic.
///
/// **Holes read as zeroes and are not on the disk at all.** A sparse file's
/// unwritten middle has no address; asking for its bytes means producing
/// zeroes, not reading them. Getting that wrong reads whatever is at cluster
/// zero and hands it over as the file's contents.
public enum NTFSFileData {

    /// One piece of a read: either somewhere on the disk, or zeroes.
    public enum Piece: Sendable, Equatable {
        /// Read this many bytes from this offset on the disk.
        case disk(offset: UInt64, length: Int)
        /// Produce this many zero bytes. A hole, which occupies nothing.
        case zeroes(length: Int)

        public var length: Int {
            switch self {
            case .disk(_, let length): return length
            case .zeroes(let length): return length
            }
        }
    }

    /// Where a resident file's bytes are, inside its record.
    ///
    /// - Returns: the range within the record, or nil when the attribute does
    ///   not hold what it claims.
    public static func residentRange(
        _ attribute: NTFSAttribute.Header, offset: Int, length: Int, recordSize: Int
    ) -> Range<Int>? {
        guard attribute.isResident, offset >= 0, length >= 0 else { return nil }
        guard attribute.valueOffset >= 0,
            attribute.valueOffset + attribute.valueLength <= recordSize
        else { return nil }
        guard offset < attribute.valueLength else { return nil }
        let available = attribute.valueLength - offset
        let wanted = min(length, available)
        let start = attribute.valueOffset + offset
        return start..<(start + wanted)
    }

    /// What to read, for a non-resident file.
    ///
    /// - Parameters:
    ///   - offset: the first byte of the file wanted.
    ///   - length: how many bytes.
    ///   - runs: the file's extents.
    ///   - size: the file's real length. Nothing past it is read, whatever the
    ///     runs cover: the last run is rounded up to a cluster and the bytes
    ///     beyond the file are whatever was there before it.
    /// - Returns: the pieces in order, or nil if the request cannot be met.
    public static func pieces(
        offset: UInt64, length: Int, runs: [NTFSRunlist.Run], bytesPerCluster: Int, size: UInt64
    ) -> [Piece]? {
        guard bytesPerCluster > 0, length >= 0 else { return nil }
        guard offset <= size else { return nil }
        guard length > 0 else { return [] }

        // A read that runs off the end of the file stops at the end of it. The
        // clusters past it belong to the file's allocation and hold whatever
        // was on the disk before.
        let wanted = min(UInt64(length), size - offset)
        guard wanted > 0 else { return [] }

        var pieces: [Piece] = []
        var position = offset
        var remaining = Int(wanted)
        let clusterSize = UInt64(bytesPerCluster)

        while remaining > 0 {
            guard
                let run = runs.first(where: {
                    let start = $0.logicalCluster * clusterSize
                    return position >= start && position < start + $0.clusterCount * clusterSize
                })
            else {
                // The runs do not cover the file they claim to. A short read
                // here would look like a truncated file rather than a fault.
                return nil
            }
            let runStart = run.logicalCluster * clusterSize
            let into = position - runStart
            let leftInRun = run.clusterCount * clusterSize - into
            let take = Int(min(UInt64(remaining), leftInRun))

            if let physical = run.physicalCluster {
                pieces.append(.disk(offset: physical * clusterSize + into, length: take))
            } else {
                pieces.append(.zeroes(length: take))
            }
            position += UInt64(take)
            remaining -= take
        }
        return pieces
    }

    /// How many bytes a set of pieces produces.
    public static func totalLength(_ pieces: [Piece]) -> Int {
        pieces.reduce(0) { $0 + $1.length }
    }
}
