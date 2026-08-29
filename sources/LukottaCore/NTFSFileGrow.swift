// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Making a file longer.
///
/// A new file's bytes live inside its record, which holds a few hundred of
/// them. Beyond that they have to go out to clusters, and the record stops
/// carrying the bytes and starts carrying a list of where they are. Those are
/// two different shapes for the same attribute, and a file crosses between them
/// exactly once as it grows.
///
/// **The two sizes NTFS keeps are not the same number and must not be set to
/// the same value.** `dataSize` is how long the file is; `initialisedSize` is
/// how much of it has actually been written. Everything between them reads as
/// zeroes without touching the disk, which is what makes a file that is
/// extended and not yet written cheap -- and what stops the last file's bytes
/// showing through in the new one's tail. Setting them equal without writing
/// the bytes hands whoever reads it whatever the clusters held before.
///
/// Nothing here does I/O. It works out what the attribute should become, and
/// the caller writes the record and the bytes.
public enum NTFSFileGrow {

    /// Where the fields of a non-resident attribute header live.
    public static let startingClusterField = 0x10
    public static let lastClusterField = 0x18
    public static let runlistOffsetField = 0x20
    public static let allocatedSizeField = 0x28
    public static let dataSizeField = 0x30
    public static let initialisedSizeField = 0x38
    public static let nonResidentHeaderLength = 0x40

    /// How long a resident value may be before it has to go out to the disk.
    ///
    /// What is left of the record once everything else in it is accounted for.
    /// A caller that guesses instead gets a record that will not lay out, and
    /// finds out after it has allocated clusters.
    public static func residentRoom(
        header: NTFSRecord.Header, otherAttributesLength: Int, attributeNameLength: Int = 0
    ) -> Int {
        let fixed = 24 + ((attributeNameLength * 2 + 7) & ~7)
        let room =
            header.allocatedLength - header.firstAttributeOffset - otherAttributesLength - 8
            - fixed
        return max(0, room & ~7)
    }

    /// A non-resident `$DATA` attribute, built from scratch.
    ///
    /// Used when a file's bytes leave its record for the first time. The
    /// attribute keeps its type, its id and its name; everything else about it
    /// changes, because a resident attribute and a non-resident one share only
    /// their first sixteen bytes.
    ///
    /// - Parameters:
    ///   - runs: where the clusters are.
    ///   - size: how long the file is.
    ///   - initialised: how much of it has been written. Never more than
    ///     `size`, and the space between is read as zeroes.
    /// - Returns: nil when the runlist will not encode, or when the numbers do
    ///   not agree with each other.
    public static func nonResident(
        type: UInt32, id: UInt16, runs: [NTFSRunlist.Run], bytesPerCluster: Int, size: UInt64,
        initialised: UInt64
    ) -> Data? {
        guard bytesPerCluster > 0, initialised <= size, let encoded = NTFSRunlist.encode(runs)
        else { return nil }
        let clusters = NTFSRunlist.clusterCount(runs)
        let allocated = clusters * UInt64(bytesPerCluster)
        guard allocated >= size else { return nil }

        let runlistAt = nonResidentHeaderLength
        let length = (runlistAt + encoded.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        write32(&bytes, 0x00, type)
        write32(&bytes, 0x04, UInt32(length))
        bytes[0x08] = 1  // out on the disk
        bytes[0x09] = 0  // the attribute itself has no name
        write16(&bytes, 0x0A, UInt16(runlistAt))
        write16(&bytes, 0x0C, 0)  // not compressed, encrypted or sparse
        write16(&bytes, 0x0E, id)
        write64(&bytes, startingClusterField, 0)
        write64(&bytes, lastClusterField, clusters == 0 ? 0 : clusters - 1)
        write16(&bytes, runlistOffsetField, UInt16(runlistAt))
        write16(&bytes, 0x22, 0)  // no compression unit
        write64(&bytes, allocatedSizeField, allocated)
        write64(&bytes, dataSizeField, size)
        write64(&bytes, initialisedSizeField, initialised)
        bytes.replaceSubrange(runlistAt..<(runlistAt + encoded.count), with: [UInt8](encoded))
        return Data(bytes)
    }

    /// The same attribute with more clusters and a greater length.
    ///
    /// The header is kept as it was apart from the numbers that describe the
    /// extent of the data. Changing a runlist without them is an attribute that
    /// ends before its own clusters do; changing them without the runlist is
    /// one that claims bytes it has nowhere to keep.
    public static func extended(
        _ attribute: Data, runs: [NTFSRunlist.Run], bytesPerCluster: Int, size: UInt64,
        initialised: UInt64
    ) -> Data? {
        guard attribute.count >= nonResidentHeaderLength, bytesPerCluster > 0,
            initialised <= size, attribute[attribute.startIndex + 0x08] == 1,
            let encoded = NTFSRunlist.encode(runs)
        else { return nil }
        let clusters = NTFSRunlist.clusterCount(runs)
        let allocated = clusters * UInt64(bytesPerCluster)
        guard allocated >= size else { return nil }

        let runlistAt = Int(read16(attribute, runlistOffsetField))
        guard runlistAt >= nonResidentHeaderLength else { return nil }
        let length = (runlistAt + encoded.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }

        var bytes = [UInt8](attribute.prefix(min(attribute.count, runlistAt)))
        if bytes.count < runlistAt {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: runlistAt - bytes.count))
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: length - runlistAt))
        bytes.replaceSubrange(runlistAt..<(runlistAt + encoded.count), with: [UInt8](encoded))

        write32(&bytes, 0x04, UInt32(length))
        write64(&bytes, lastClusterField, clusters == 0 ? 0 : clusters - 1)
        write64(&bytes, allocatedSizeField, allocated)
        write64(&bytes, dataSizeField, size)
        write64(&bytes, initialisedSizeField, initialised)
        return Data(bytes)
    }

    /// How many clusters a file of this length needs.
    public static func clusters(for size: UInt64, bytesPerCluster: Int) -> UInt64? {
        guard bytesPerCluster > 0 else { return nil }
        let per = UInt64(bytesPerCluster)
        guard size <= UInt64.max - (per - 1) else { return nil }
        return (size + per - 1) / per
    }

    /// The runs a file would have with more clusters on the end.
    ///
    /// Extends the last run where the new clusters sit next to it, which keeps
    /// the runlist the length it was. A runlist that grows can outgrow its
    /// record; one that gets longer in place cannot.
    public static func joining(_ runs: [NTFSRunlist.Run], with added: [NTFSRunlist.Run])
        -> [NTFSRunlist.Run]?
    {
        guard !added.isEmpty else { return runs }
        var out = runs
        var next = NTFSRunlist.clusterCount(runs)
        for run in added {
            guard let physical = run.physicalCluster else { return nil }
            if let last = out.last, let lastPhysical = last.physicalCluster,
                lastPhysical + last.clusterCount == physical
            {
                out[out.count - 1] = NTFSRunlist.Run(
                    logicalCluster: last.logicalCluster, physicalCluster: lastPhysical,
                    clusterCount: last.clusterCount + run.clusterCount)
            } else {
                out.append(
                    NTFSRunlist.Run(
                        logicalCluster: next, physicalCluster: physical,
                        clusterCount: run.clusterCount))
            }
            next += run.clusterCount
        }
        return out
    }

    // MARK: - Arithmetic

    public static func read16(_ bytes: Data, _ at: Int) -> UInt16 {
        let base = bytes.startIndex + at
        guard base + 1 < bytes.endIndex else { return 0 }
        return UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8)
    }
    static func write16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt16) {
        bytes[at] = UInt8(value & 0xFF)
        bytes[at + 1] = UInt8(value >> 8)
    }
    static func write32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
    static func write64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
}
