// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// One record of the master file table.
///
/// Every file and directory on an NTFS volume is a record here, found through
/// `NTFSGeometry.mftByteOffset`. A record is a header followed by attributes,
/// and the attributes hold everything: the name, the timestamps, and either the
/// file's contents or a list of where on the disk they are.
///
/// **The fixup is the part that surprises people.** NTFS writes a two-byte
/// signature at the end of every sector of a record, and keeps the bytes it
/// displaced in an array at the front. A record read straight off the disk
/// therefore has two bytes of rubbish at the end of each sector, and anything
/// parsing it without putting them back reads garbage at exactly the places a
/// long attribute crosses a sector. The point of the scheme is that a torn
/// write is detectable: if the signatures do not all match, the record was
/// half-written and must not be trusted.
///
/// Nothing here does I/O. It takes bytes that have already been read and says
/// what they are, which is what lets every edge of it be checked without a disk.
public enum NTFSRecord {

    /// `FILE` at the start of a record in use. `BAAD` is what chkdsk leaves
    /// where a record was found to be corrupt.
    public static let signature = Array("FILE".utf8)
    public static let corruptSignature = Array("BAAD".utf8)

    /// What a record says about itself, before its attributes are read.
    public struct Header: Sendable, Equatable {
        /// Where the fixup array is, from the start of the record.
        public let fixupOffset: Int
        /// How many entries it has: one signature plus one per sector.
        public let fixupCount: Int
        /// Where the first attribute begins.
        public let firstAttributeOffset: Int
        /// How much of the record is used, including the header.
        public let usedLength: Int
        /// How long the record is on disk.
        public let allocatedLength: Int
        /// Set when the record describes a file that exists rather than a slot
        /// waiting to be reused.
        public let inUse: Bool
        /// Set when the record describes a directory.
        public let isDirectory: Bool
    }

    /// Read the header, or refuse.
    ///
    /// Refuses a record whose numbers do not fit inside it. Every one of these
    /// is a read past the end of the buffer if it is believed: an attribute
    /// offset beyond the record, a used length longer than the record, a fixup
    /// array that does not fit.
    public static func header(_ record: Data, expectedLength: Int) -> Header? {
        guard expectedLength >= 42, record.count >= min(42, expectedLength) else { return nil }
        guard record.count >= 42 else { return nil }
        let base = record.startIndex
        guard Array(record[base..<base + 4]) == signature else { return nil }

        func word(_ offset: Int) -> Int {
            Int(record[base + offset]) | (Int(record[base + offset + 1]) << 8)
        }
        func long(_ offset: Int) -> Int {
            word(offset) | (word(offset + 2) << 16)
        }

        let fixupOffset = word(0x04)
        let fixupCount = word(0x06)
        let firstAttribute = word(0x14)
        let used = long(0x18)
        let allocated = long(0x1C)
        let flags = word(0x16)

        // Everything has to fit inside the record as it was read.
        guard allocated > 0, allocated <= expectedLength else { return nil }
        guard used >= 42, used <= allocated else { return nil }
        guard firstAttribute >= 42, firstAttribute < used else { return nil }
        guard fixupOffset >= 42, fixupCount >= 1 else { return nil }
        // The array is `fixupCount` two-byte entries and must sit inside the
        // header, before the first attribute.
        guard fixupOffset + fixupCount * 2 <= firstAttribute else { return nil }
        // One entry per sector, plus the signature itself. A count claiming more
        // sectors than the record has is a corrupt record, not a long one.
        guard fixupCount - 1 <= allocated / 512 + 1 else { return nil }

        return Header(
            fixupOffset: fixupOffset,
            fixupCount: fixupCount,
            firstAttributeOffset: firstAttribute,
            usedLength: used,
            allocatedLength: allocated,
            inUse: flags & 0x0001 != 0,
            isDirectory: flags & 0x0002 != 0)
    }

    /// Put back the bytes NTFS displaced, and say whether the record is whole.
    ///
    /// - Returns: the repaired record, or nil when a sector's signature does not
    ///   match. That mismatch means the record was being written when the power
    ///   went, and half of it is from before and half from after -- the one case
    ///   where believing the bytes is worse than refusing them.
    public static func applyFixup(
        _ record: Data, header: Header, sectorSize: Int = 512
    ) -> Data? {
        guard sectorSize > 2, header.fixupCount >= 1 else { return nil }
        var bytes = [UInt8](record)
        guard header.fixupOffset + header.fixupCount * 2 <= bytes.count else { return nil }

        let signature = [bytes[header.fixupOffset], bytes[header.fixupOffset + 1]]
        // Entry 0 is the signature; the rest are the displaced bytes, one pair
        // per sector.
        for sector in 1..<header.fixupCount {
            let end = sector * sectorSize - 2
            guard end + 1 < bytes.count else { return nil }
            guard bytes[end] == signature[0], bytes[end + 1] == signature[1] else {
                // A torn write. Refusing is the whole reason the scheme exists.
                return nil
            }
            let entry = header.fixupOffset + sector * 2
            bytes[end] = bytes[entry]
            bytes[end + 1] = bytes[entry + 1]
        }
        return Data(bytes)
    }
}
