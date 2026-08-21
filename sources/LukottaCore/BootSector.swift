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
    /// Not recognised, and not guessed at.
    case unknown
}

public enum BootSector {

    /// How many bytes are needed to tell. One sector.
    public static let length = 512

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
        if contains(sector, bitlockerIdentifier) { return .bitlocker }

        let oem = String(
            decoding: sector[sector.startIndex + 3..<sector.startIndex + 11], as: UTF8.self)
        switch oem {
        case "-FVE-FS-": return .bitlocker
        case "NTFS    ": return .ntfs
        case "EXFAT   ": return .exfat
        default: return .unknown
        }
    }

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        let bytes = [UInt8](haystack)
        for start in 0...(bytes.count - needle.count) {
            if Array(bytes[start..<start + needle.count]) == needle { return true }
        }
        return false
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
        // A character device wants a whole block; a short read is an error, not
        // a partial answer.
        guard let data = try? handle.read(upToCount: length), data.count == length else {
            return nil
        }
        return data
    }
}
