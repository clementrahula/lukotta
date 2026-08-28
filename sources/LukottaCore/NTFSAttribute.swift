// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The attributes inside a file record.
///
/// Everything NTFS knows about a file is an attribute: its name, its
/// timestamps, its size, and its contents. A record is a header followed by
/// attributes one after another, each with its own header saying what it is and
/// how long it is, ending at a type of `0xFFFFFFFF`.
///
/// The distinction that matters most is resident against non-resident. A small
/// file's contents live *inside* the record -- a few hundred bytes of data in
/// the middle of the MFT, which is why a volume of tiny files is so much faster
/// on NTFS than its cluster size suggests. A large file's contents live out on
/// the disk, and the attribute holds a *runlist*: a compressed list of extents,
/// each a length and a starting cluster.
///
/// That runlist is what kernel-offloaded I/O needs. `FSExtentPacker` wants a
/// physical offset and a length on a block device (see architecture.md §15), and
/// a runlist is exactly that list, in NTFS's own encoding.
///
/// Nothing here does I/O.
public enum NTFSAttribute {

    /// The types this needs to know by name. There are more; these are the ones
    /// a file cannot be read without.
    public enum Kind: UInt32, Sendable {
        case standardInformation = 0x10
        case attributeList = 0x20
        case fileName = 0x30
        case objectID = 0x40
        case securityDescriptor = 0x50
        case volumeName = 0x60
        case volumeInformation = 0x70
        case data = 0x80
        case indexRoot = 0x90
        case indexAllocation = 0xA0
        case bitmap = 0xB0
        case reparsePoint = 0xC0
    }

    /// The end marker that closes a record's attribute list.
    public static let endOfAttributes: UInt32 = 0xFFFF_FFFF

    /// One attribute's header.
    public struct Header: Sendable, Equatable {
        public let type: UInt32
        /// How long the whole attribute is, header included. Walking the list
        /// means adding this; a zero would loop for ever and is refused.
        public let length: Int
        /// Whether the contents are inside the record or out on the disk.
        public let isResident: Bool
        /// For a resident attribute: where its value is, and how long.
        public let valueOffset: Int
        public let valueLength: Int
        /// For a non-resident attribute: where its runlist is, and the clusters
        /// it covers.
        public let runlistOffset: Int
        public let startingCluster: UInt64
        public let lastCluster: UInt64
        /// The size a reader should report, which for a non-resident attribute
        /// is the real length rather than the space allocated for it.
        public let dataSize: UInt64

        public var kind: Kind? { Kind(rawValue: type) }
    }

    /// Read one attribute header at an offset inside a record.
    ///
    /// - Returns: nil at the end marker, or when the numbers do not fit inside
    ///   the record. Both are ordinary: a record ends, and a corrupt one must
    ///   not be walked off the end of.
    public static func header(_ record: Data, at offset: Int) -> Header? {
        let base = record.startIndex
        guard offset >= 0, offset + 16 <= record.count else { return nil }

        func word(_ o: Int) -> Int { Int(record[base + o]) | (Int(record[base + o + 1]) << 8) }
        func long(_ o: Int) -> UInt32 {
            UInt32(word(o)) | (UInt32(word(o + 2)) << 16)
        }
        func quad(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(record[base + o + i]) }
            return v
        }

        let type = long(offset)
        guard type != endOfAttributes, type != 0 else { return nil }

        let length = Int(long(offset + 4))
        // A zero length would walk this list for ever. A length past the end of
        // the record is a corrupt record, not a long attribute.
        guard length >= 16, offset + length <= record.count else { return nil }

        let resident = record[base + offset + 8] == 0

        if resident {
            guard offset + 24 <= record.count else { return nil }
            let valueLength = Int(long(offset + 16))
            let valueOffset = word(offset + 20)
            // The value has to sit inside this attribute, not merely inside the
            // record: an attribute claiming a value belonging to the next one
            // reads somebody else's bytes as this file's contents.
            guard valueOffset >= 16, valueOffset + valueLength <= length else { return nil }
            return Header(
                type: type, length: length, isResident: true,
                valueOffset: offset + valueOffset, valueLength: valueLength,
                runlistOffset: 0, startingCluster: 0, lastCluster: 0,
                dataSize: UInt64(valueLength))
        }

        guard offset + 64 <= record.count else { return nil }
        let runlistOffset = word(offset + 32)
        guard runlistOffset >= 16, offset + runlistOffset <= offset + length else { return nil }
        let start = quad(offset + 16)
        let last = quad(offset + 24)
        guard last >= start else { return nil }
        return Header(
            type: type, length: length, isResident: false,
            valueOffset: 0, valueLength: 0,
            runlistOffset: offset + runlistOffset,
            startingCluster: start, lastCluster: last,
            dataSize: quad(offset + 48))
    }

    /// Every attribute in a record, in order.
    ///
    /// Stops at the end marker, at the used length, or at anything that does not
    /// fit -- whichever comes first. A record is walked once and never twice,
    /// and a malformed one yields what was readable rather than nothing or a
    /// crash.
    public static func all(in record: Data, startingAt firstOffset: Int, usedLength: Int)
        -> [Header]
    {
        var found: [Header] = []
        var offset = firstOffset
        let limit = min(usedLength, record.count)
        // A record holds few attributes; a bound stops a cycle from a corrupt
        // length even if one slipped past the checks above.
        while offset + 16 <= limit, found.count < 64 {
            guard let header = header(record, at: offset) else { break }
            found.append(header)
            offset += header.length
        }
        return found
    }
}
