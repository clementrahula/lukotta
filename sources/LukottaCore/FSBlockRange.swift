// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Turning a read or write of a file into reads and writes of whole blocks.
///
/// A block device answers in blocks. `FSBlockDeviceResource` will read at any
/// offset, but the device underneath moves a whole block whichever byte was
/// asked for, and a write of anything smaller than a block has to read the
/// block, change the part that moved, and put it back -- or the rest of the
/// block is lost.
///
/// That read-modify-write is where a naive filesystem loses most of its write
/// speed, and getting the arithmetic wrong is worse than slow: it is somebody
/// else's bytes written over, or a file that reads back with a hole in it. So
/// it is worked out here, once, where the checks can reach every edge of it,
/// rather than inline in a method that also has to talk to FSKit.
///
/// Nothing here does any I/O. It is arithmetic about where the I/O has to
/// happen.
public enum FSBlockRange {

    /// The whole blocks covering a byte range.
    ///
    /// - Parameters:
    ///   - offset: the first byte wanted. Negative is nonsense and answers nil.
    ///   - length: how many bytes. Zero touches no blocks at all, which is not
    ///     the same as touching one.
    ///   - blockSize: what the device moves at once. Zero or negative is a
    ///     device that has not answered yet, and answers nil rather than
    ///     dividing by it.
    /// - Returns: the offset of the first block, and how many bytes of blocks
    ///   the range spans.
    public static func covering(
        offset: Int, length: Int, blockSize: Int
    ) -> (start: Int, span: Int)? {
        guard blockSize > 0, offset >= 0, length >= 0 else { return nil }
        guard length > 0 else { return (offset - offset % blockSize, 0) }
        let start = offset - offset % blockSize
        let end = offset + length
        // Round the end up to a whole block, without overflowing on a length
        // somebody has handed us from outside.
        let (rounded, overflow) = end.addingReportingOverflow(blockSize - 1)
        guard !overflow else { return nil }
        let alignedEnd = rounded - rounded % blockSize
        return (start, alignedEnd - start)
    }

    /// Where the wanted bytes sit inside the blocks that were read.
    ///
    /// The caller reads `span` bytes starting at `start`, and the bytes it
    /// actually asked for begin this far into that buffer.
    public static func offsetWithinBlocks(offset: Int, blockSize: Int) -> Int? {
        guard blockSize > 0, offset >= 0 else { return nil }
        return offset % blockSize
    }

    /// Whether a range is already whole blocks, so nothing has to be read
    /// before it is written.
    ///
    /// This is the fast path and the only one that reaches the device's own
    /// speed: an aligned write is one write, and an unaligned one is a read, a
    /// copy and a write.
    public static func isAligned(offset: Int, length: Int, blockSize: Int) -> Bool {
        guard blockSize > 0, offset >= 0, length >= 0 else { return false }
        return offset % blockSize == 0 && length % blockSize == 0
    }

    /// How much of a write is wasted on blocks that had to be read first.
    ///
    /// Zero for an aligned write. For an unaligned one it is the two partial
    /// blocks at the ends, which is the whole of the read-modify-write cost and
    /// the number worth watching when a copy is slower than the device.
    public static func readModifyWriteBytes(
        offset: Int, length: Int, blockSize: Int
    ) -> Int {
        guard blockSize > 0, offset >= 0, length > 0 else { return 0 }
        guard let range = covering(offset: offset, length: length, blockSize: blockSize) else {
            return 0
        }
        return range.span - length
    }
}
