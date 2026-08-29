// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A directory's entries when there are too many to fit in its record.
///
/// A small directory keeps its whole B-tree in `$INDEX_ROOT`, inside the file
/// record. A large one keeps only the root there and puts the rest out on the
/// disk in `$INDEX_ALLOCATION`, as fixed-size blocks each beginning `INDX`.
///
/// **This is not the rare case.** The root directory of a freshly formatted
/// volume already has its names out here: NTFS's own metadata files fill the
/// record's index root immediately, leaving nothing there but the marker
/// pointing at the first block. A reader that handles only `$INDEX_ROOT` lists
/// an empty root directory on every volume it will ever see, and reports no
/// error while doing it.
///
/// A block carries the same fixup as a file record -- a signature at the end of
/// every sector, with the displaced bytes at the front -- for the same reason
/// and with the same consequence if it is skipped: garbage exactly where an
/// entry crosses a sector boundary.
///
/// Nothing here does I/O.
public enum NTFSIndexBlock {

    /// `INDX` at the start of a block in use.
    public static let signature = Array("INDX".utf8)

    public struct Header: Sendable, Equatable {
        /// Where the fixup array is, and how many entries it has.
        public let fixupOffset: Int
        public let fixupCount: Int
        /// Which block this is, counted in index-block units from the start of
        /// `$INDEX_ALLOCATION`. It is written into the block so that a block
        /// read from the wrong place can be noticed.
        public let blockNumber: UInt64
        /// Where the node's entries begin, from the start of the block.
        public let firstEntryOffset: Int
        /// The first byte past the entries.
        public let endOfEntries: Int
    }

    /// Read a block's header, or refuse.
    public static func header(_ block: Data, blockSize: Int) -> Header? {
        guard blockSize >= 512, block.count >= min(blockSize, 40) else { return nil }
        guard block.count >= 40 else { return nil }
        let base = block.startIndex
        guard Array(block[base..<base + 4]) == signature else { return nil }

        func word(_ o: Int) -> Int { Int(block[base + o]) | (Int(block[base + o + 1]) << 8) }
        func long(_ o: Int) -> Int { word(o) | (word(o + 2) << 16) }
        func quad(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(block[base + o + i]) }
            return v
        }

        let fixupOffset = word(0x04)
        let fixupCount = word(0x06)
        let blockNumber = quad(0x10)
        // The node header sits at 0x18, and its offsets are relative to itself
        // rather than to the block. Getting that wrong reads entries 24 bytes
        // from where they are.
        let nodeHeader = 0x18
        let firstEntry = nodeHeader + long(nodeHeader)
        let endOfEntries = nodeHeader + long(nodeHeader + 4)

        guard fixupOffset >= 40, fixupCount >= 1 else { return nil }
        guard fixupOffset + fixupCount * 2 <= blockSize else { return nil }
        guard firstEntry >= nodeHeader + 16, firstEntry < blockSize else { return nil }
        guard endOfEntries >= firstEntry, endOfEntries <= blockSize else { return nil }
        // One fixup entry per sector, plus the signature.
        guard fixupCount - 1 <= blockSize / 512 + 1 else { return nil }

        return Header(
            fixupOffset: fixupOffset, fixupCount: fixupCount, blockNumber: blockNumber,
            firstEntryOffset: firstEntry, endOfEntries: endOfEntries)
    }

    /// Put back the bytes the fixup displaced, and refuse a torn block.
    ///
    /// The same scheme as a file record, and the same reason for refusing: a
    /// block whose sector signatures do not match was being written when the
    /// power went, and half of it is from before.
    public static func applyFixup(
        _ block: Data, header: Header, sectorSize: Int = 512
    ) -> Data? {
        guard sectorSize > 2, header.fixupCount >= 1 else { return nil }
        var bytes = [UInt8](block)
        guard header.fixupOffset + header.fixupCount * 2 <= bytes.count else { return nil }

        let signature = [bytes[header.fixupOffset], bytes[header.fixupOffset + 1]]
        for sector in 1..<header.fixupCount {
            let end = sector * sectorSize - 2
            guard end + 1 < bytes.count else { return nil }
            guard bytes[end] == signature[0], bytes[end + 1] == signature[1] else { return nil }
            let entry = header.fixupOffset + sector * 2
            bytes[end] = bytes[entry]
            bytes[end + 1] = bytes[entry + 1]
        }
        return Data(bytes)
    }

    /// Where the node header sits inside a block.
    ///
    /// After the block's own twenty-four bytes, and its offsets are relative to
    /// itself rather than to the block -- getting that wrong reads entries
    /// twenty-four bytes from where they are.
    public static let nodeHeaderOffset = 0x18

    /// Take the fixup off, ready to write the block back.
    ///
    /// The exact inverse of `applyFixup`, and the same reasoning as for a
    /// record: a block written without its per-sector signatures is one the
    /// next reader refuses as torn, which is a directory that loses names.
    ///
    /// The signature moves on with every write. Passing the same one twice
    /// would let a block caught half-written pass for a whole one, which is the
    /// single thing the scheme exists to prevent.
    public static func removeFixup(
        _ block: Data, header: Header, sectorSize: Int = 512
    ) -> Data? {
        guard sectorSize > 2, header.fixupCount >= 1 else { return nil }
        var bytes = [UInt8](block)
        guard header.fixupOffset + header.fixupCount * 2 <= bytes.count else { return nil }

        let current =
            UInt16(bytes[header.fixupOffset]) | (UInt16(bytes[header.fixupOffset + 1]) << 8)
        let signature = NTFSRecord.nextSignature(after: current)
        let low = UInt8(signature & 0xFF)
        let high = UInt8(signature >> 8)
        bytes[header.fixupOffset] = low
        bytes[header.fixupOffset + 1] = high

        for sector in 1..<header.fixupCount {
            let end = sector * sectorSize - 2
            guard end + 1 < bytes.count else { return nil }
            let entry = header.fixupOffset + sector * 2
            bytes[entry] = bytes[end]
            bytes[entry + 1] = bytes[end + 1]
            bytes[end] = low
            bytes[end + 1] = high
        }
        return Data(bytes)
    }

    /// Build a block from scratch, holding the entries given.
    ///
    /// Used when a node splits and half its names need somewhere to live. The
    /// entries go in as they are -- they are already in order, because they
    /// came out of a node that was.
    ///
    /// The fixup array is left with a signature of one and the per-sector
    /// bytes untouched: `removeFixup` puts the real signature in when the block
    /// is written, and that is the one place that decides what a signature is.
    ///
    /// - Returns: nil when the entries do not fit, which is a caller that
    ///   picked the wrong place to split.
    public static func compose(
        blockNumber: UInt64, blockSize: Int, sectorSize: Int, entries: [Data], marker: Data,
        hasChildren: Bool = false
    ) -> Data? {
        guard blockSize >= 512, sectorSize > 2, blockSize % sectorSize == 0 else { return nil }
        let fixupCount = blockSize / sectorSize + 1
        let fixupOffset = 40
        let nodeStart = nodeHeaderOffset
        // The fixup array sits at 40, which is past the node header at 24. So
        // the entries begin after the array rather than after the header, and
        // on an eight-byte boundary like everything else. Starting them at the
        // header would put the first entry underneath the array, and the array
        // is written last.
        let firstEntry = max(
            16, (fixupOffset + fixupCount * 2 - nodeStart + 7) & ~7)
        guard nodeStart + firstEntry < blockSize else { return nil }

        var bytes = [UInt8](repeating: 0, count: blockSize)
        bytes.replaceSubrange(0..<4, with: signature)
        write16(&bytes, 0x04, UInt16(fixupOffset))
        write16(&bytes, 0x06, UInt16(fixupCount))
        write64(&bytes, 0x10, blockNumber)
        // A signature of one to begin with. Zero is what an unwritten sector
        // holds, so a block whose signature was zero could match one that was
        // never written at all.
        write16(&bytes, fixupOffset, 1)

        var at = nodeStart + firstEntry
        for entry in entries + [marker] {
            guard at + entry.count <= blockSize else { return nil }
            bytes.replaceSubrange(at..<at + entry.count, with: [UInt8](entry))
            at += entry.count
        }

        write32(&bytes, nodeStart + 0, UInt32(firstEntry))
        write32(&bytes, nodeStart + 4, UInt32(at - nodeStart))
        write32(&bytes, nodeStart + 8, UInt32(blockSize - nodeStart))
        // Whether anything hangs below this node. A leaf says nothing does; a
        // node that took over a root's entries says it does, because those
        // entries point at the blocks the root used to point at.
        write32(&bytes, nodeStart + 12, hasChildren ? 1 : 0)
        return Data(bytes)
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

    /// Where a block sits inside `$INDEX_ALLOCATION`, as a byte offset into
    /// that attribute as a file.
    ///
    /// The child pointer in an index entry is a block number, not a byte
    /// offset, and not a cluster. Treating it as either reads the wrong part of
    /// the disk.
    public static func offsetOfBlock(_ number: UInt64, blockSize: Int) -> UInt64? {
        guard blockSize > 0 else { return nil }
        let (offset, overflow) = number.multipliedReportingOverflow(by: UInt64(blockSize))
        return overflow ? nil : offset
    }
}
