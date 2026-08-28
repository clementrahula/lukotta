// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What is in a directory.
///
/// A directory's contents are a B-tree of index entries, sorted by name. A small
/// directory keeps the whole tree inside its record, in `$INDEX_ROOT`; a large
/// one keeps the root there and the rest out on the disk in `$INDEX_ALLOCATION`,
/// in blocks that carry the same entries with a header in front.
///
/// An entry is a file reference, a copy of the file's `$FILE_NAME`, and -- for a
/// node with children -- the block number of the subtree below it. Listing a
/// directory means walking the entries; finding one name means using the sort
/// order rather than walking them all.
///
/// **The last entry in every node is a marker with no name**, carrying only the
/// pointer to the subtree past the last real key. A reader that treats it as a
/// file shows an empty-named entry in every folder, and one that stops at it
/// without following its child misses everything in the last subtree.
///
/// Nothing here does I/O.
public enum NTFSIndex {

    /// Flags on an index entry.
    private static let hasSubNode: UInt8 = 0x01
    private static let isLastEntry: UInt8 = 0x02

    public struct Entry: Sendable, Equatable {
        /// The record this entry names. Meaningless on the last entry.
        public let record: UInt64
        public let sequence: UInt16
        /// Nil on the last entry, which has no name.
        public let name: NTFSFileName.Name?
        /// The index block holding the subtree below this entry, if any.
        public let childBlock: UInt64?
        /// Whether this is the marker that ends a node.
        public let isLast: Bool

        public init(
            record: UInt64, sequence: UInt16, name: NTFSFileName.Name?, childBlock: UInt64?,
            isLast: Bool
        ) {
            self.record = record
            self.sequence = sequence
            self.name = name
            self.childBlock = childBlock
            self.isLast = isLast
        }
    }

    /// Read one entry at an offset.
    ///
    /// - Returns: nil when the entry does not fit or its length is unusable.
    ///   An entry length of zero would walk a node for ever.
    public static func entry(_ data: Data, at offset: Int, limit: Int) -> (Entry, Int)? {
        guard offset >= 0, limit <= data.count, offset + 16 <= limit else { return nil }
        let base = data.startIndex

        func word(_ o: Int) -> Int { Int(data[base + o]) | (Int(data[base + o + 1]) << 8) }
        func quad(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(data[base + o + i]) }
            return v
        }

        let reference = quad(offset)
        let entryLength = word(offset + 8)
        let contentLength = word(offset + 10)
        let flags = data[base + offset + 12]

        // A zero length loops for ever; one past the node reads past the end.
        guard entryLength >= 16, offset + entryLength <= limit else { return nil }
        // Every field has to sit inside the entry.
        guard contentLength <= entryLength - 16 else { return nil }

        var child: UInt64?
        if flags & hasSubNode != 0 {
            // The child block number is the last eight bytes of the entry.
            let childOffset = offset + entryLength - 8
            guard childOffset >= offset + 16 else { return nil }
            child = quad(childOffset)
        }

        let last = flags & isLastEntry != 0
        let (record, sequence) = NTFSTable.reference(reference)

        // The last entry carries no name, whatever its content length claims.
        var name: NTFSFileName.Name?
        if !last, contentLength >= 66 {
            let start = base + offset + 16
            name = NTFSFileName.read(data[start..<start + contentLength])
        }
        // An entry that is not the last and has no readable name is a corrupt
        // node, not a nameless file.
        guard last || name != nil else { return nil }

        return (
            Entry(
                record: record, sequence: sequence, name: name, childBlock: child, isLast: last),
            entryLength
        )
    }

    /// Every entry in one node, in the order they are written.
    ///
    /// Stops at the last entry, which is included: it carries the pointer to
    /// the subtree past the final name, and a caller that drops it misses
    /// everything in that subtree.
    public static func entries(_ data: Data, from offset: Int, limit: Int) -> [Entry] {
        var found: [Entry] = []
        var cursor = offset
        // A node holds far fewer than this; the bound stops a cycle a corrupt
        // length could otherwise cause.
        while found.count < 4096 {
            guard let (entry, length) = entry(data, at: cursor, limit: limit) else { break }
            found.append(entry)
            if entry.isLast { break }
            cursor += length
        }
        return found
    }

    /// Which way to go, looking for a name in a node.
    ///
    /// The entries are sorted, so a search does not read them all: it stops at
    /// the first entry that is not less than the name it wants. If that entry
    /// *is* the name, it is found; otherwise the answer is in the subtree below
    /// it, if there is one.
    ///
    /// **NTFS sorts case-insensitively, by uppercased UTF-16 code unit.** Not
    /// by byte, not by Unicode collation, and not case-sensitively. A search
    /// that compares any other way walks past the entry it is looking for and
    /// reports a file that is plainly there as missing -- which looks like a
    /// corrupt directory rather than a comparison bug.
    public enum Step: Equatable, Sendable {
        /// The name is this entry.
        case found(Entry)
        /// It is not in this node; look in the block below this entry.
        case descend(UInt64)
        /// It is not here and there is nowhere further down.
        case absent
    }

    /// Search one node.
    public static func find(_ name: String, in entries: [Entry]) -> Step {
        let wanted = name.uppercased()
        for entry in entries {
            if entry.isLast {
                if let child = entry.childBlock { return .descend(child) }
                return .absent
            }
            guard let candidate = entry.name?.name else { continue }
            let upper = candidate.uppercased()
            if upper == wanted { return .found(entry) }
            // Past where it would have been: it is below this entry, or nowhere.
            if upper > wanted {
                if let child = entry.childBlock { return .descend(child) }
                return .absent
            }
        }
        return .absent
    }

    /// The names in a node, in order, with the end marker left out.
    public static func names(_ entries: [Entry]) -> [String] {
        entries.compactMap { $0.isLast ? nil : $0.name?.name }
    }

    /// Where a node's entries begin, relative to the start of an `$INDEX_ROOT`
    /// value or an index block's node header.
    ///
    /// The header says so itself rather than it being a constant, because the
    /// two carry different amounts in front of the node.
    public static func firstEntryOffset(nodeHeader data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 16 <= data.count else { return nil }
        let base = data.startIndex
        let relative = Int(data[base + offset]) | (Int(data[base + offset + 1]) << 8)
        guard relative >= 16 else { return nil }
        let absolute = offset + relative
        guard absolute < data.count else { return nil }
        return absolute
    }
}
