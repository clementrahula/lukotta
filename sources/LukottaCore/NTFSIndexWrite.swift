// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Putting a name into a directory.
///
/// A directory node -- whether it is an `INDX` block out on the disk or the
/// `$INDEX_ROOT` attribute inside the directory's own record -- is a header
/// followed by entries in order, ending with a marker. Adding a name means
/// finding where it belongs by the volume's own comparison, moving everything
/// after it along, and saying that the node is longer than it was.
///
/// **The two numbers in the node header are the whole safety story.** One says
/// where the entries end and one says how much room there is. A splice that
/// updates the first without checking the second writes past the end of the
/// node into whatever follows; a splice that updates neither leaves the entry
/// on the disk and invisible. So the room is checked first, the bytes are moved
/// second, and the length is written last.
///
/// Nothing here does I/O, and nothing here decides whether the node is the
/// right one. It takes the bytes of a node and gives back the bytes of a node.
public enum NTFSIndexWrite {

    /// Where a node header keeps its numbers, from the start of the header.
    public static let firstEntryField = 0
    public static let endOfEntriesField = 4
    public static let endOfAllocationField = 8
    public static let flagsField = 12
    public static let nodeHeaderLength = 16

    /// Where an entry keeps its own, from the start of the entry.
    public static let referenceField = 0
    public static let entryLengthField = 8
    public static let keyLengthField = 10
    public static let entryFlagsField = 12
    public static let keyField = 16

    /// Set when an entry points at a node below it.
    public static let hasChild: UInt16 = 0x0001
    /// Set on the marker that ends every node.
    public static let isLast: UInt16 = 0x0002

    /// The bytes of one index entry for a file.
    ///
    /// The key is the whole `$FILE_NAME` value, the same bytes the file's own
    /// record carries. That duplication is NTFS's: a listing reads names and
    /// times out of the index without opening a single record, which is what
    /// makes listing a directory of a million files one pass over the index
    /// rather than a million reads.
    public static func entry(key: Data, record: UInt64, sequence: UInt16) -> Data? {
        guard key.count >= 66 else { return nil }
        let length = (keyField + key.count + 7) & ~7
        guard length <= 0xFFFF else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        write64(&bytes, referenceField, NTFSNewRecord.reference(record, sequence: sequence))
        write16(&bytes, entryLengthField, UInt16(length))
        write16(&bytes, keyLengthField, UInt16(key.count))
        write16(&bytes, entryFlagsField, 0)
        bytes.replaceSubrange(keyField..<keyField + key.count, with: key)
        return Data(bytes)
    }

    /// What a node has room for.
    public struct Room: Sendable, Equatable {
        public let used: Int
        public let allocated: Int
        public var free: Int { max(0, allocated - used) }

        public init(used: Int, allocated: Int) {
            self.used = used
            self.allocated = allocated
        }
    }

    /// Read the two numbers that decide everything.
    public static func room(of bytes: Data, nodeHeaderAt header: Int) -> Room? {
        guard header >= 0, header + nodeHeaderLength <= bytes.count else { return nil }
        let used = Int(read32(bytes, header + endOfEntriesField))
        let allocated = Int(read32(bytes, header + endOfAllocationField))
        guard used >= nodeHeaderLength, allocated >= used else { return nil }
        guard header + allocated <= bytes.count else { return nil }
        return Room(used: used, allocated: allocated)
    }

    /// How long an `$INDEX_ROOT`'s own header is, before the node begins.
    ///
    /// Four numbers: which attribute the index is over, how names in it are
    /// compared, how big an index block is, and how many clusters that comes
    /// to. A caller that starts the node header at zero reads the block size as
    /// an entry offset.
    public static let indexRootHeaderLength = 16

    /// Rebuild an `$INDEX_ROOT` value with one entry added.
    ///
    /// Unlike a block, `$INDEX_ROOT` has no spare room: its allocated length is
    /// its used length, because it lives inside a record and every byte it does
    /// not need belongs to another attribute. So it is not spliced -- it is
    /// rebuilt at the size it now needs, and the record makes room for it.
    ///
    /// - Returns: nil when the value does not parse, or when the name is
    ///   already in it.
    public static func rootValue(
        _ value: Data, inserting entry: Data, collation: NTFSCollation
    ) -> Data? {
        let header = indexRootHeaderLength
        guard value.count >= header + nodeHeaderLength, entry.count >= keyField else {
            return nil
        }
        guard let room = room(of: value, nodeHeaderAt: header) else { return nil }
        let firstEntry = Int(read32(value, header + firstEntryField))
        guard firstEntry >= nodeHeaderLength, firstEntry <= room.used else { return nil }
        guard let name = key(of: entry, at: 0) else { return nil }

        // Take the entries out, put the new one where it belongs, lay them back.
        var existing: [Data] = []
        var marker: Data?
        var at = header + firstEntry
        let end = header + room.used
        var seen = 0
        while at + keyField <= end, seen < 8192 {
            seen += 1
            let length = Int(read16(value, at + entryLengthField))
            guard length >= keyField, at + length <= end else { return nil }
            let bytes = Data(value[(value.startIndex + at)..<(value.startIndex + at + length)])
            if read16(value, at + entryFlagsField) & isLast != 0 {
                marker = bytes
                break
            }
            existing.append(bytes)
            at += length
        }
        guard let marker else { return nil }

        var place = existing.count
        for (index, other) in existing.enumerated() {
            guard let otherName = key(of: other, at: 0) else { return nil }
            switch collation.compare(otherName, name) {
            case .orderedSame: return nil
            case .orderedDescending:
                place = index
                // The first entry that sorts after the new one; it goes here.
                return laidOut(
                    value, header: header,
                    entries: Array(existing[0..<place]) + [entry] + Array(existing[place...]),
                    marker: marker)
            case .orderedAscending: continue
            }
        }
        return laidOut(value, header: header, entries: existing + [entry], marker: marker)
    }

    /// Put an `$INDEX_ROOT` value back together from its parts.
    public static func laidOut(_ value: Data, header: Int, entries: [Data], marker: Data) -> Data? {
        var bytes = [UInt8](value[value.startIndex..<(value.startIndex + header)])
        var node = [UInt8](repeating: 0, count: nodeHeaderLength)
        var laid: [UInt8] = []
        for entry in entries + [marker] { laid.append(contentsOf: [UInt8](entry)) }

        let used = nodeHeaderLength + laid.count
        write32(&node, firstEntryField, UInt32(nodeHeaderLength))
        write32(&node, endOfEntriesField, UInt32(used))
        // Allocated equals used: there is no spare room in a record, and a
        // number saying otherwise invites the next writer to splice into
        // somebody else's attribute.
        write32(&node, endOfAllocationField, UInt32(used))
        // Whether the root has nodes below it is decided by its entries, not
        // remembered from before: a root that gains its first child pointer has
        // to start saying so.
        let hasChildren = (entries + [marker]).contains {
            read16($0, entryFlagsField) & hasChild != 0
        }
        write32(&node, flagsField, hasChildren ? 1 : 0)

        bytes.append(contentsOf: node)
        bytes.append(contentsOf: laid)
        return Data(bytes)
    }

    /// An `$INDEX_ROOT` emptied of its entries, pointing at one block.
    ///
    /// When the root has no room for another promoted key it cannot grow --
    /// it lives in a record, and the record is full. NTFS's answer is to make
    /// the tree deeper: everything the root held goes into a block of its own,
    /// and the root keeps a single marker pointing at that block. The next
    /// promotion then has an empty root to go into.
    ///
    /// A search still works because the marker's child is where everything
    /// below the last key lives -- and after this, everything is below the last
    /// key, since there are no keys.
    public static func rootPointingAt(_ block: UInt64, keeping value: Data) -> Data? {
        let header = indexRootHeaderLength
        guard value.count >= header + nodeHeaderLength else { return nil }
        var marker = [UInt8](repeating: 0, count: keyField + 8)
        write16(&marker, entryLengthField, UInt16(keyField + 8))
        write16(&marker, keyLengthField, 0)
        write16(&marker, entryFlagsField, isLast | hasChild)
        for byte in 0..<8 {
            marker[keyField + byte] = UInt8((block >> (8 * UInt64(byte))) & 0xFF)
        }
        return laidOut(value, header: header, entries: [], marker: Data(marker))
    }

    /// The name inside an entry's `$FILE_NAME` key.
    public static func key(of bytes: Data, at entry: Int) -> [UInt16]? {
        let keyLength = Int(read16(bytes, entry + keyLengthField))
        guard keyLength >= 66, entry + keyField + keyLength <= bytes.count else { return nil }
        let key = entry + keyField
        let units = Int(bytes[bytes.startIndex + key + 0x40])
        guard key + 0x42 + units * 2 <= bytes.count else { return nil }
        var name = [UInt16]()
        name.reserveCapacity(units)
        for index in 0..<units {
            let at = bytes.startIndex + key + 0x42 + index * 2
            name.append(UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8))
        }
        return name
    }

    // MARK: - Arithmetic

    public static func read16(_ bytes: Data, _ at: Int) -> UInt16 {
        let base = bytes.startIndex + at
        guard base + 1 < bytes.endIndex else { return 0 }
        return UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8)
    }
    public static func read32(_ bytes: Data, _ at: Int) -> UInt32 {
        UInt32(read16(bytes, at)) | (UInt32(read16(bytes, at + 2)) << 16)
    }
    public static func write16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt16) {
        bytes[at] = UInt8(value & 0xFF)
        bytes[at + 1] = UInt8(value >> 8)
    }
    public static func write32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
    static func write64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[at + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
    }
}
