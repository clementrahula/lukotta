// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// When a file was made, changed and last looked at.
///
/// `$STANDARD_INFORMATION` is the first attribute of every record and holds four
/// timestamps and the DOS-era attribute flags. Without it every file on a volume
/// shows the same date, which is not an error anybody can report but is
/// immediately obvious in a Finder window.
///
/// **NTFS counts in 100-nanosecond intervals since 1 January 1601.** Not
/// seconds, and not from 1970: the epoch is the start of the Gregorian calendar
/// cycle Microsoft chose, and the unit is ten million to the second. Reading it
/// as a Unix time gives dates in 1601, and reading it as seconds gives dates
/// hundreds of millions of years out. Both are wrong in ways that look like a
/// corrupt disk rather than a units mistake.
public enum NTFSTimestamps {

    /// Seconds between 1601-01-01 and 1970-01-01. 369 years, of which 89 were
    /// leap years under the Gregorian rules.
    public static let epochDifference: Int64 = 11_644_473_600
    /// NTFS ticks per second.
    public static let ticksPerSecond: Int64 = 10_000_000

    public struct Times: Sendable, Equatable {
        public let created: Date
        public let modified: Date
        /// When the record itself last changed, which is not the same as when
        /// the contents did: a rename changes this and not `modified`.
        public let recordChanged: Date
        public let accessed: Date

        public init(created: Date, modified: Date, recordChanged: Date, accessed: Date) {
            self.created = created
            self.modified = modified
            self.recordChanged = recordChanged
            self.accessed = accessed
        }
    }

    /// DOS-era flags. The two that matter to anybody looking at a drive.
    public struct Flags: Sendable, Equatable {
        public let isReadOnly: Bool
        public let isHidden: Bool
        public let isSystem: Bool
        /// Set on the metadata files NTFS keeps for itself.
        public let isArchive: Bool
    }

    /// Turn an NTFS tick count into a date.
    ///
    /// - Returns: nil for a zero, which means "never set" rather than 1601, and
    ///   for anything that would not fit a `Date` -- a corrupt record can hold
    ///   a count that overflows every unit it is converted through.
    public static func date(fromTicks ticks: UInt64) -> Date? {
        guard ticks > 0 else { return nil }
        // Under 64 bits signed after the division, always; the guard is against
        // the multiplication inside Foundation rather than this arithmetic.
        let seconds = Int64(ticks / UInt64(ticksPerSecond))
        let remainder = Int64(ticks % UInt64(ticksPerSecond))
        let (unix, overflow) = seconds.subtractingReportingOverflow(epochDifference)
        guard !overflow else { return nil }
        // Dates before the Unix epoch are real -- a file copied off an old
        // volume can carry one -- but a date before 1601 cannot exist in this
        // encoding, and one past the year 30000 is a corrupt record.
        guard unix > -12_219_292_800, unix < 883_612_800_000 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(unix)
                + TimeInterval(remainder) / TimeInterval(ticksPerSecond))
    }

    /// Read the four timestamps from a `$STANDARD_INFORMATION` value.
    public static func read(_ value: Data) -> Times? {
        // Four eight-byte timestamps, then four bytes of flags: 36 at least.
        guard value.count >= 36 else { return nil }
        let base = value.startIndex

        func quad(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in (0..<8).reversed() { v = (v << 8) | UInt64(value[base + o + i]) }
            return v
        }

        // A record with no creation time at all is not one to trust; the other
        // three may legitimately be unset on an old volume and fall back to it.
        guard let created = date(fromTicks: quad(0)) else { return nil }
        return Times(
            created: created,
            modified: date(fromTicks: quad(8)) ?? created,
            recordChanged: date(fromTicks: quad(16)) ?? created,
            accessed: date(fromTicks: quad(24)) ?? created)
    }

    /// Read the DOS flags from the same value.
    public static func flags(_ value: Data) -> Flags? {
        guard value.count >= 36 else { return nil }
        let base = value.startIndex
        var raw: UInt32 = 0
        for i in (0..<4).reversed() { raw = (raw << 8) | UInt32(value[base + 32 + i]) }
        return Flags(
            isReadOnly: raw & 0x0001 != 0,
            isHidden: raw & 0x0002 != 0,
            isSystem: raw & 0x0004 != 0,
            isArchive: raw & 0x0020 != 0)
    }
}
