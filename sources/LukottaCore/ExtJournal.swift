// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What a Linux volume must be mounted with to keep what it was told to keep,
/// read out of its own superblock.
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

    /// XFS writes this at the very front of its superblock.
    public static let xfsMagic: [UInt8] = Array("XFSB".utf8)

    /// The mount option this volume needs, or nil where it needs none.
    ///
    /// Two filesystems lose the contents of files that were fsynced before the
    /// machine died, and each needs a different word for the same promise.
    /// Measured here, both on this Mac, both against NTFS through the same
    /// guest and the same accident, which loses nothing:
    ///
    ///     ext4 as it mounts     8 of 8 fsynced files present, 8 wrong
    ///     ext4 data=journal     8 of 8 present, 0 wrong
    ///     XFS  as it mounts     8 of 8 present, 8 wrong
    ///     XFS  sync             8 of 8 present, 0 wrong
    ///
    /// Neither costs anything measurable: 2024 files copy in nine seconds
    /// either way on ext4, and two thousand small ones in two seconds either
    /// way on XFS.
    ///
    /// btrfs is not here, and on 2026-09-03 that stopped being an admission
    /// and became a result. A fixture was made and the vectors run against it
    /// through the app, with no durability option applied because none is
    /// chosen for btrfs:
    ///
    ///     every fsynced file survived power loss
    ///     8 of 8 present, 0 wrong, 0 lost
    ///
    /// So btrfs does not have the fault that ext4 and XFS have, and needs no
    /// option. It is still not here, and now that is the measured answer
    /// rather than the absence of one.
    public static func durabilityOption(forDevice path: String) -> String? {
        guard let bytes = read(path) else { return nil }
        if isJournalled(superblock: bytes) { return "data=journal" }
        // XFS has no data-journalling mode: its journal covers metadata and
        // nothing else, so the word here is the blunt one.
        //
        // It was briefly moved onto a synchronous client instead, on a
        // measurement that only looked at small files. That was wrong and
        // shipped: a synchronous client writes a large file at 3 MB/s where an
        // ordinary one manages 190, and `-o sync` in the guest costs nothing on
        // a large file at all. The full picture, on a fresh XFS volume:
        //
        //     no option        190 MB/s large,  44 s for 2000 small files
        //     -o sync          190 MB/s large,  65 s for 2000 small
        //     client sync        3 MB/s large,  43 s for 2000 small
        //
        // Half a minute on a folder of small files is worth paying. A sixtieth
        // of the speed on every large file is not.
        if bytes.count >= xfsMagic.count,
            Array(bytes.prefix(xfsMagic.count)) == xfsMagic
        {
            return "sync"
        }
        return nil
    }

    private static func read(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let wanted = superblockOffset + featureCompatOffset + 4
        guard let bytes = try? handle.read(upToCount: wanted), bytes.count == wanted
        else { return nil }
        return bytes
    }

    /// The same, for a device this process can read.
    ///
    /// False for anything that cannot be read or is not ext at all, which is
    /// the safe answer in both cases: no option is added, and the mount is
    /// exactly what it was before this existed. A LUKS container answers false
    /// too -- its superblock is encrypted from out here -- so a journalled ext4
    /// inside one does not get the option yet.
    public static func isJournalled(forDevice path: String) -> Bool {
        guard let bytes = read(path) else { return false }
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
