// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What a "Microsoft Basic Data" partition actually holds.
///
/// The GPT partition type says nothing: BitLocker, plain NTFS and exFAT all
/// use the same one. The first sector does say, and until it is read the app
/// cannot tell a locked drive from an ordinary Windows disk — which is why
/// people have been finding out by typing a password and watching it fail.
public enum VolumeFormat: String, Sendable {
    case bitlocker
    case ntfs
    case exfat
    /// A LUKS container. Recognised on a whole disk with no partition table,
    /// which is what `cryptsetup luksFormat container.img` makes and what a
    /// container file almost always is.
    case luks
    /// ext2, ext3 or ext4 — a Linux filesystem with no encryption over it.
    case ext
    case btrfs
    case xfs
    /// Not recognised, and not guessed at.
    case unknown

    /// What it is called on screen. Product and filesystem names, the same in
    /// every language, so they are written rather than translated.
    public var name: String {
        switch self {
        case .bitlocker: return "BitLocker"
        case .ntfs: return "NTFS"
        case .exfat: return "exFAT"
        case .luks: return "LUKS"
        case .ext: return "ext"
        case .btrfs: return "Btrfs"
        case .xfs: return "XFS"
        case .unknown: return ""
        }
    }

    /// What to call the filesystem the engine says it mounted.
    ///
    /// It names the driver it used, and two of those are one filesystem:
    /// ntfs3 is the kernel's and ntfs-3g is not, and a reader looking at a
    /// drive wants neither name.
    public static func filesystemName(fromDriver driver: String) -> String {
        switch driver.lowercased() {
        case "ntfs", "ntfs3", "ntfs-3g", "lowntfs-3g": return "NTFS"
        case "exfat": return "exFAT"
        case "vfat", "msdos": return "FAT"
        case "btrfs": return "Btrfs"
        case "xfs": return "XFS"
        case "f2fs": return "F2FS"
        case "apfs": return "APFS"
        case "hfs", "hfsplus": return "HFS+"
        default: return driver
        }
    }

    /// Nothing to unlock: it can be opened without asking for anything.
    public var isUnencrypted: Bool {
        switch self {
        case .ntfs, .exfat, .ext, .btrfs, .xfs: return true
        case .bitlocker, .luks, .unknown: return false
        }
    }

    /// Whether something has to be unlocked before anything can be read.
    public var isEncrypted: Bool {
        self == .luks || self == .bitlocker
    }

    /// Whether macOS reads and writes this on its own.
    ///
    /// exFAT it mounts locally, read and write, through FSKit — so opening one
    /// here would take a local volume and turn it into a network one for no
    /// gain. NTFS is not on this list: macOS mounts it read-only, and writing
    /// to it is the whole reason to open it here.
    public var macOSHandlesFully: Bool {
        self == .exfat
    }
}

public enum BootSector {

    /// How many bytes are needed to tell.
    ///
    /// Far more than a boot sector, because the Linux filesystems do not put
    /// their magic near the front: ext puts its superblock at 1024 and btrfs
    /// its signature at 65600. Reading 128 KB costs nothing and covers them
    /// all with room to spare.
    public static let length = 128 * 1024

    /// Where each filesystem writes what it is.
    static let extMagicOffset = 1080  // 1024 + 56, inside the superblock
    static let btrfsMagicOffset = 65600

    /// The identifier BitLocker writes into its volume header, as it appears
    /// on disk: a GUID in Microsoft's mixed-endian form, so the first three
    /// fields are byte-swapped from how it is usually written.
    ///
    /// 4967D63B-2E29-4AD8-8399-F6A339E3D001
    public static let bitlockerIdentifier: [UInt8] = [
        0x3B, 0xD6, 0x67, 0x49, 0x29, 0x2E, 0xD8, 0x4A,
        0x83, 0x99, 0xF6, 0xA3, 0x39, 0xE3, 0xD0, 0x01,
    ]

    /// Read the format out of a first sector.
    ///
    /// Two signals, in this order. The identifier is looked for first because
    /// BitLocker To Go leaves the OEM name saying "MSWIN4.1" — a drive that
    /// reads as plain FAT while being encrypted — and getting that one wrong
    /// is the case that matters most: telling someone their locked drive is
    /// not locked.
    /// "LUKS" and two bytes, at the very start. Both LUKS1 and LUKS2 write it.
    public static let luksMagic: [UInt8] = [0x4C, 0x55, 0x4B, 0x53, 0xBA, 0xBE]

    public static func identify(_ sector: Data) -> VolumeFormat {
        guard sector.count >= 11 else { return .unknown }
        // At offset zero, and only there: the bytes are short enough to turn up
        // by chance in the middle of something else.
        if Array(sector.prefix(luksMagic.count)) == luksMagic { return .luks }
        if Array(sector.prefix(4)) == Array("XFSB".utf8) { return .xfs }
        if contains(sector, bitlockerIdentifier) { return .bitlocker }

        let oem = String(
            decoding: sector[sector.startIndex + 3..<sector.startIndex + 11], as: UTF8.self)
        switch oem {
        case "-FVE-FS-": return .bitlocker
        case "NTFS    ": return .ntfs
        case "EXFAT   ": return .exfat
        default: break
        }

        // The Linux filesystems, each at the one place it writes its magic.
        // Anywhere else would be a coincidence: two bytes for ext especially.
        if at(sector, extMagicOffset, [0x53, 0xEF]) { return .ext }
        if at(sector, btrfsMagicOffset, Array("_BHRfS_M".utf8)) { return .btrfs }
        return .unknown
    }

    /// Whether these bytes sit at exactly this offset.
    private static func at(_ data: Data, _ offset: Int, _ bytes: [UInt8]) -> Bool {
        guard data.count >= offset + bytes.count else { return false }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: bytes.count)
        return Array(data[start..<end]) == bytes
    }

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.range(of: Data(needle)) != nil
    }

    /// The first sector of a device.
    ///
    /// Needs root: /dev/diskNsM is mode 640, owned by root and the operator
    /// group, which an ordinary account is not in. Full Disk Access does not
    /// change that — it is a POSIX permission, not a privacy one — so this runs
    /// in the helper and nowhere else.
    public static func read(devicePath: String) -> Data? {
        // The raw device, so the read is not served out of the buffer cache
        // for a disk macOS has its own opinion about.
        let raw = devicePath.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        guard
            let handle = FileHandle(forReadingAtPath: raw)
                ?? FileHandle(forReadingAtPath: devicePath)
        else { return nil }
        defer { try? handle.close() }
        // A short read is not an error here: a container can be smaller than
        // the window we ask for, and everything before the end of it is still
        // worth reading. Only nothing at all is nothing.
        guard let data = try? handle.read(upToCount: length), !data.isEmpty else { return nil }
        return data
    }
}
