// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Whether an ext volume keeps a journal, read out of its own superblock.
///
/// ext4 as it mounts by default loses the contents of files that were fsynced
/// before the machine died. Measured on this Mac: eight files written and
/// fsynced, the machine killed, all eight present afterwards and all eight
/// wrong. NTFS through the same guest, the same harness and the same accident
/// loses nothing. `data=journal` fixes it, and costs nothing measurable -- the
/// same corpus copies in nine seconds either way.
///
/// The reason it was not simply switched on is that the option is not
/// universal. It is meaningless on a filesystem with no journal, and the kernel
/// does not ignore it there: an ext2 volume asked for `data=journal` refuses to
/// mount at all. The app passes no driver for Linux volumes, so an option added
/// blindly would reach every one of them.
///
/// So the volume is asked. The superblock says whether a journal exists, in the
/// same feature flag the kernel reads, and the option goes on only where it is
/// both meaningful and needed.
public enum ExtJournal {

    /// Every ext superblock lives here, whatever the block size.
    static let superblockOffset = 1024
    /// 0xEF53, little-endian, at this offset within the superblock.
    static let magicOffset = 0x38
    static let magic: UInt16 = 0xEF53
    /// s_feature_compat, whose bit 2 is "this filesystem has a journal".
    static let featureCompatOffset = 0x5C
    static let hasJournalFlag: UInt32 = 0x0004

    /// Read from the bytes of a superblock, so the decision can be asserted
    /// without a device.
    public static func isJournalled(superblock bytes: Data) -> Bool {
        guard read16(bytes, at: superblockOffset + magicOffset) == magic else { return false }
        guard let compat = read32(bytes, at: superblockOffset + featureCompatOffset)
        else { return false }
        return compat & hasJournalFlag != 0
    }

    /// The same, for a device this process can read.
    ///
    /// False for anything that cannot be read or is not ext at all, which is
    /// the safe answer in both cases: no option is added, and the mount is
    /// exactly what it was before this existed. A LUKS container answers false
    /// too -- its superblock is encrypted from out here -- so a journalled ext4
    /// inside one does not get the option yet.
    public static func isJournalled(forDevice path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let wanted = superblockOffset + featureCompatOffset + 4
        guard let bytes = try? handle.read(upToCount: wanted), bytes.count == wanted
        else { return false }
        return isJournalled(superblock: bytes)
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        let i = data.index(data.startIndex, offsetBy: offset)
        return UInt16(data[i]) | UInt16(data[data.index(after: i)]) << 8
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        var value: UInt32 = 0
        for byte in 0..<4 {
            let i = data.index(data.startIndex, offsetBy: offset + byte)
            value |= UInt32(data[i]) << (8 * byte)
        }
        return value
    }
}
