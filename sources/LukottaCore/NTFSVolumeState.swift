// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Whether a volume is in a state anybody should write to.
///
/// `$Volume`, record 3, carries the volume's name, the NTFS version, and a set
/// of flags of which one decides everything: **dirty**. Windows sets it when a
/// volume is mounted for writing and clears it on a clean unmount, so a drive
/// that was pulled out mid-write, or that Windows left in fast-startup
/// hibernation, still has it set.
///
/// **A dirty volume must not be written to.** Its metadata may be half-updated
/// -- a cluster allocated in the bitmap but not yet in a runlist, or the other
/// way round -- and `$LogFile` holds the record needed to finish or undo that.
/// Writing on top means writing against structures that are not yet consistent,
/// and the result is a volume chkdsk cannot fully repair. It is also exactly the
/// state a person's drive is in after the failure that made them reach for this
/// application.
///
/// v1 already understands this: the engine's ntfs3 refuses a dirty volume and
/// falls back to ntfs-3g, and `SPECS.md` records that. This is the same rule
/// read directly, so v2 knows before it mounts rather than after it fails.
public enum NTFSVolumeState {

    /// The record `$Volume` always occupies.
    public static let volumeRecord: UInt64 = 3

    public struct Info: Sendable, Equatable {
        /// The name somebody gave the drive, as Finder would show it.
        public let label: String?
        public let majorVersion: UInt8
        public let minorVersion: UInt8
        /// Set when the volume was not unmounted cleanly.
        public let isDirty: Bool
        /// Windows wants to run chkdsk on it at next boot.
        public let wantsCheck: Bool
        /// Windows wants to write its own log entries at next mount.
        public let wantsLogFileUpdate: Bool

        public init(
            label: String?, majorVersion: UInt8, minorVersion: UInt8, isDirty: Bool,
            wantsCheck: Bool, wantsLogFileUpdate: Bool
        ) {
            self.label = label
            self.majorVersion = majorVersion
            self.minorVersion = minorVersion
            self.isDirty = isDirty
            self.wantsCheck = wantsCheck
            self.wantsLogFileUpdate = wantsLogFileUpdate
        }

        /// Whether writing to this volume is safe.
        ///
        /// Read-only is always allowed: somebody with a drive in this state
        /// most likely wants their files off it, and refusing to show them
        /// anything would be the application failing at the one job it has.
        public var isSafeToWrite: Bool { !isDirty && !wantsCheck }
    }

    /// Read `$VOLUME_INFORMATION` and `$VOLUME_NAME` out of a record.
    public static func read(
        record: Data, attributes: [NTFSAttribute.Header]
    ) -> Info? {
        guard let information = attributes.first(where: { $0.kind == .volumeInformation }),
            information.isResident
        else { return nil }
        let start = record.startIndex + information.valueOffset
        // Eight reserved bytes, then major, minor, and two bytes of flags.
        guard information.valueLength >= 12, start + 12 <= record.endIndex else { return nil }

        let major = record[start + 8]
        let minor = record[start + 9]
        let flags = UInt16(record[start + 10]) | (UInt16(record[start + 11]) << 8)

        var label: String?
        if let name = attributes.first(where: { $0.kind == .volumeName }), name.isResident,
            name.valueLength > 0
        {
            let from = record.startIndex + name.valueOffset
            if from + name.valueLength <= record.endIndex {
                var units: [UInt16] = []
                var index = from
                while index + 1 < from + name.valueLength {
                    units.append(UInt16(record[index]) | (UInt16(record[index + 1]) << 8))
                    index += 2
                }
                let text = String(decoding: units, as: UTF16.self)
                if !text.isEmpty { label = text }
            }
        }

        return Info(
            label: label,
            majorVersion: major,
            minorVersion: minor,
            isDirty: flags & 0x0001 != 0,
            wantsCheck: flags & 0x0002 != 0,
            wantsLogFileUpdate: flags & 0x0004 != 0)
    }
}
