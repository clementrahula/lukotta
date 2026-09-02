// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import CryptoKit
import Foundation

/// A name for a volume that survives it being replugged.
///
/// A saved passphrase has to be filed under something, and the obvious
/// candidate -- the partition UUID macOS reports -- is not always there. Only
/// GPT gives partitions a GUID. A stick partitioned the way Windows partitions
/// a stick has an MBR, whose entries carry no identifier of any kind, and
/// macOS reports a locked BitLocker partition as a nameless exFAT with no UUID
/// at all. Filing under the device node instead means `disk4s1`, which is a
/// position in an enumeration rather than a drive: plug the same stick into
/// another port, or plug anything in ahead of it, and the saved key belongs to
/// a drive that no longer exists.
///
/// So the volume is asked what it is, out of bytes it carries itself. Every
/// format here writes something unique when it is created and does not change
/// it afterwards, which is the whole requirement.
///
/// Being wrong is cheap in both directions: an identity that changes orphans a
/// saved key, and the app asks once more and saves it again. A collision offers
/// a passphrase that fails, and the app asks. Neither loses data, so this
/// prefers the identifier the format defines over anything cleverer.
public enum VolumeIdentity {

    /// LUKS1 and LUKS2 both put a 40-byte ASCII UUID here. The two headers
    /// disagree about nearly everything else and agree about this by accident
    /// of layout, but they do agree.
    static let luksUUIDOffset = 0xA8
    static let luksUUIDLength = 40

    /// What to file this volume's passphrase under, or nil when its header
    /// says nothing that would still be true after a replug.
    ///
    /// `header` is the leading bytes of the partition, as `BootSector.read`
    /// returns them.
    public static func fingerprint(_ header: Data, format: VolumeFormat) -> String? {
        switch format {
        case .luks:
            // The UUID itself, not a digest of the header. A LUKS2 header
            // carries a sequence number and a checksum that are rewritten
            // whenever a keyslot changes, so hashing the header would forget
            // the passphrase every time somebody added a second one.
            guard let uuid = ascii(header, at: luksUUIDOffset, length: luksUUIDLength),
                !uuid.isEmpty
            else { return nil }
            return "luks:\(uuid)"

        case .bitlocker, .ntfs, .exfat:
            // These have a volume serial number, but at three different offsets
            // depending on which of them it is and on whether BitLocker wrote a
            // Windows or a To Go header. The first sector holds the serial in
            // every one of those layouts, along with the boot code and the
            // parameter block, and none of it is rewritten while the volume
            // exists. Digesting the sector reads all of the layouts at once.
            return digest(header.prefix(512), as: format.rawValue)

        case .ext, .btrfs, .xfs:
            // A saved passphrase is not the reason these are here -- they are
            // not encrypted, so nothing is ever saved for them. Naming them
            // costs one line and means the identity of a drive is one question
            // with one answer, rather than something only encrypted drives have.
            return digest(superblock(header, format: format), as: format.rawValue)

        case .unknown:
            return nil
        }
    }

    /// Every name a volume could have been filed under, best first.
    ///
    /// The order is the whole point, and it is written once here because there
    /// are two places that unlock a drive -- the window and the headless
    /// route -- and when they each kept their own copy of it they drifted. One
    /// looked under the device node and the other did not, so a saved
    /// passphrase was found by one and not the other on the same stick.
    ///
    /// Everything after the first is a name to migrate away from.
    public static func names(
        fingerprint: String?, uuid: String, id: String, cache: [String: String] = [:]
    ) -> [String] {
        var names: [String] = []
        func add(_ name: String?) {
            guard let name, !name.isEmpty, !names.contains(name) else { return }
            names.append(name)
        }
        add(fingerprint)
        // The same fingerprint from the last time this drive was seen, for the
        // moments before this time's reading lands.
        for key in [uuid, id] where !key.isEmpty { add(cache[key]) }
        add(uuid)
        // A partition table carrying no UUID at all leaves nothing to tell one
        // drive from another. The device name is at least this drive, now.
        add(id)
        return names
    }

    /// The slice of a Linux superblock that holds its UUID, digested rather
    /// than read out, because each of the three keeps it somewhere different
    /// and none of them keeps anything else in these bytes.
    private static func superblock(_ header: Data, format: VolumeFormat) -> Data {
        switch format {
        case .ext: return slice(header, at: 1024 + 0x68, length: 16)
        case .btrfs: return slice(header, at: 65536 + 0x20, length: 16)
        case .xfs: return slice(header, at: 32, length: 16)
        default: return Data()
        }
    }

    private static func digest(_ bytes: Data, as label: String) -> String? {
        guard !bytes.isEmpty, bytes.contains(where: { $0 != 0 }) else { return nil }
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // Half of it. This names a volume on one Mac; it is not a checksum, and
        // the Keychain account field is nicer to read at this length.
        return "\(label):\(hex.prefix(32))"
    }

    private static func slice(_ data: Data, at offset: Int, length: Int) -> Data {
        guard data.count >= offset + length else { return Data() }
        let start = data.index(data.startIndex, offsetBy: offset)
        return data[start..<data.index(start, offsetBy: length)]
    }

    private static func ascii(_ data: Data, at offset: Int, length: Int) -> String? {
        let bytes = slice(data, at: offset, length: length)
        guard !bytes.isEmpty else { return nil }
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
