// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Which NTFS volumes this Mac has already inspected.
///
/// A full check reads the whole MFT — 59 seconds on a 247 GB drive — so it runs
/// once per volume and not on every open. The volume itself used to be the only
/// place that record could live: the check leaves `.lukotta-check.log` on it,
/// and the gate looks for that file before deciding.
///
/// That works for every volume a driver will mount, and fails for exactly the
/// one the rule exists to protect. A volume ntfs3 refuses is refused for ever if
/// ntfsck cannot bring it clean, so the gate reaches the branch that cannot
/// mount it, cannot read the marker, and orders a full scan — every open, for
/// the life of the drive, with nothing said and no way out.
///
/// Reading the marker without mounting was tried first and measured, because it
/// would have needed no state on this side at all:
///
///     ntfsls -f /dev/vda      $MFTMirr does not match $MFT (record 3).
///     ntfscat /dev/vda ...    Failed to mount '/dev/vda': I/O error
///
/// Both go through libntfs-3g, which refuses the volume for the same reason
/// ntfs3 does. There is no read-side tool in the guest that answers on a damaged
/// volume, so the record has to live somewhere that is not the volume.
///
/// What identifies it is the NTFS volume serial, eight bytes at offset 0x48 of
/// the boot sector — what `blkid` reports as the UUID. It is in the first
/// sector, so nothing about MFT damage touches it: read from a fixture before
/// and after a repair of 65 errors, it was `205DEDCB3E41DEF6` both times.
///
/// Nothing sensitive is kept here: a volume serial, and the fact that this Mac
/// has looked at it once.
public enum CheckedVolumes {
    private static let key = "checkedVolumeSerials"

    private static var store: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Upper case, no punctuation, so the guest's spelling and blkid's agree.
    ///
    /// blkid prints an NTFS serial as sixteen hex digits; some tools group it
    /// with a dash in the middle. Comparing the two spellings of one volume as
    /// different strings would check it twice and record it twice.
    public static func normalised(_ serial: String) -> String {
        serial.uppercased().filter { $0.isHexDigit }
    }

    /// Every serial this Mac has inspected.
    public static func all() -> [String] { store }

    /// Whether this volume has been looked at before.
    public static func hasSeen(_ serial: String) -> Bool {
        let wanted = normalised(serial)
        guard !wanted.isEmpty else { return false }
        return store.contains(wanted)
    }

    /// Remember that it has.
    public static func record(_ serial: String) {
        let wanted = normalised(serial)
        guard !wanted.isEmpty else { return }
        var current = store
        guard !current.contains(wanted) else { return }
        current.append(wanted)
        // Bounded, and oldest first out. Somebody who checks a great many
        // drives should not carry an unbounded list for ever, and forgetting
        // the oldest costs one scan on a drive that has not been seen in a
        // very long time.
        if current.count > limit { current.removeFirst(current.count - limit) }
        store = current
    }

    static let limit = 512

    /// The serials named by a mount's own output.
    ///
    /// The guest is the only side that can see inside a container: the app
    /// hands over one device and the engine finds however many NTFS volumes are
    /// in it, so the app cannot name them in advance. The check says which ones
    /// it looked at, on a `LUKOTTA_STAGE:` line like every other thing the
    /// mount reports upward, and this reads them back out.
    public static func serials(reportedIn lines: [String]) -> [String] {
        let marker = MountScript.stageMarker + "checked "
        return lines.compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            let serial = normalised(String(line[range.upperBound...]))
            return serial.isEmpty ? nil : serial
        }
    }

    /// Record everything a mount said it checked.
    @discardableResult
    public static func note(reportedIn lines: [String]) -> Int {
        let found = serials(reportedIn: lines)
        for serial in found { record(serial) }
        return found.count
    }

    /// The list as the guest reads it: one serial per line.
    ///
    /// Written into the machine rather than compiled into the check, because
    /// the check is one static script shared by every mount and this differs
    /// per Mac and per day.
    public static var guestList: String { store.joined(separator: "\n") }
}
