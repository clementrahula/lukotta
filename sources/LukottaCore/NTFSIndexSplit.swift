// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Cutting a full directory node in two.
///
/// A leaf fills up, and a name that will not fit has nowhere to go. NTFS's
/// answer is the B-tree's: take the middle entry out, put the names below it in
/// a new block, leave the names above it where they are, and hand the middle
/// entry up to the parent with a pointer to the new block.
///
/// Afterwards a search still works, and it is worth seeing why. A parent entry
/// points at the node holding keys **below** its own key. So a search for
/// something below the median steps into the new block; the median itself is
/// found in the parent; anything above it goes on to the node that was
/// already there.
///
/// **The order this is written down in is what makes it survivable.** The new
/// block is written first, then the parent is pointed at it, and only then is
/// the old node trimmed. Between the second and the third, the names below the
/// median exist in both places at once -- which no search can notice, because a
/// search below the median goes to the new block and never looks in the old
/// one. The other order, trimming first, makes those names exist nowhere for
/// as long as the write takes.
///
/// Nothing here does I/O and nothing allocates. It takes a node's bytes and
/// says what the two nodes should contain.
public enum NTFSIndexSplit {

    public struct Plan: Sendable {
        /// The entries for the new block: everything below the median.
        public let below: [Data]
        /// What the old node keeps: everything above the median.
        public let above: [Data]
        /// The node's end marker, which stays with the old node.
        public let marker: Data
        /// The median entry, to be handed to the parent with a child pointer.
        public let median: Data

        public init(below: [Data], above: [Data], marker: Data, median: Data) {
            self.below = below
            self.above = above
            self.marker = marker
            self.median = median
        }
    }

    /// Read a node's entries out as bytes, in order.
    ///
    /// - Returns: the real entries and the marker, or nil when the node does
    ///   not parse. The marker is separate because it is not a name and must
    ///   not move.
    public static func entries(of bytes: Data, nodeHeaderAt header: Int)
        -> (entries: [Data], marker: Data)?
    {
        guard let room = NTFSIndexWrite.room(of: bytes, nodeHeaderAt: header) else { return nil }
        let firstEntry = Int(NTFSIndexWrite.read32(bytes, header + NTFSIndexWrite.firstEntryField))
        guard firstEntry >= NTFSIndexWrite.nodeHeaderLength, firstEntry <= room.used else {
            return nil
        }

        var found: [Data] = []
        var at = header + firstEntry
        let end = header + room.used
        var seen = 0
        while at + NTFSIndexWrite.keyField <= end, seen < 8192 {
            seen += 1
            let length = Int(
                NTFSIndexWrite.read16(bytes, at + NTFSIndexWrite.entryLengthField))
            let flags = NTFSIndexWrite.read16(bytes, at + NTFSIndexWrite.entryFlagsField)
            guard length >= NTFSIndexWrite.keyField, at + length <= end else { return nil }
            let entry = bytes[(bytes.startIndex + at)..<(bytes.startIndex + at + length)]
            if flags & NTFSIndexWrite.isLast != 0 { return (found, Data(entry)) }
            found.append(Data(entry))
            at += length
        }
        return nil
    }

    /// Decide where to cut.
    ///
    /// By bytes rather than by count, so two nodes of similar fullness come out
    /// of names of wildly different lengths. A node cut by count with one very
    /// long name in it leaves one half nearly empty and the other nearly full,
    /// and the full one splits again on the next file.
    ///
    /// - Returns: nil when there is nothing to split -- fewer than two entries
    ///   means one of the halves would be empty, and an empty node is one no
    ///   search can pass through.
    public static func plan(of bytes: Data, nodeHeaderAt header: Int) -> Plan? {
        guard let (all, marker) = entries(of: bytes, nodeHeaderAt: header), all.count >= 3 else {
            return nil
        }
        // An entry that already points at a node below it cannot be the median:
        // handing it up means handing up its child as well, and the parent
        // entry has room for exactly one pointer.
        let total = all.reduce(0) { $0 + $1.count }
        var running = 0
        var cut = 0
        for (index, entry) in all.enumerated() {
            running += entry.count
            if running * 2 >= total {
                cut = index
                break
            }
        }
        // Never the first or the last: both halves must have something in them.
        cut = max(1, min(cut, all.count - 2))
        guard
            NTFSIndexWrite.read16(all[cut], NTFSIndexWrite.entryFlagsField)
                & NTFSIndexWrite.hasChild == 0
        else { return nil }

        return Plan(
            below: Array(all[0..<cut]), above: Array(all[(cut + 1)...]), marker: marker,
            median: all[cut])
    }

    /// The median, made into an entry that points at the new block.
    ///
    /// The child pointer is eight bytes on the end, and the entry grows to hold
    /// it -- which is why a node with room for the median alone may still have
    /// no room for this.
    public static func promoting(_ median: Data, toChild block: UInt64) -> Data? {
        let keyLength = Int(NTFSIndexWrite.read16(median, NTFSIndexWrite.keyLengthField))
        guard keyLength >= 66, NTFSIndexWrite.keyField + keyLength <= median.count else {
            return nil
        }
        let length = ((NTFSIndexWrite.keyField + keyLength + 7) & ~7) + 8
        guard length <= 0xFFFF else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        let carried = min(median.count, NTFSIndexWrite.keyField + keyLength)
        bytes.replaceSubrange(0..<carried, with: [UInt8](median.prefix(carried)))
        NTFSIndexWrite.write16(&bytes, NTFSIndexWrite.entryLengthField, UInt16(length))
        let flags =
            NTFSIndexWrite.read16(median, NTFSIndexWrite.entryFlagsField)
            | NTFSIndexWrite.hasChild
        NTFSIndexWrite.write16(&bytes, NTFSIndexWrite.entryFlagsField, flags)
        for byte in 0..<8 {
            bytes[length - 8 + byte] = UInt8((block >> (8 * UInt64(byte))) & 0xFF)
        }
        return Data(bytes)
    }

    /// The block number an entry points at, or nil if it points at nothing.
    public static func child(of entry: Data) -> UInt64? {
        let flags = NTFSIndexWrite.read16(entry, NTFSIndexWrite.entryFlagsField)
        guard flags & NTFSIndexWrite.hasChild != 0, entry.count >= 8 else { return nil }
        var value: UInt64 = 0
        let start = entry.endIndex - 8
        for byte in 0..<8 { value |= UInt64(entry[start + byte]) << (8 * UInt64(byte)) }
        return value
    }
}
