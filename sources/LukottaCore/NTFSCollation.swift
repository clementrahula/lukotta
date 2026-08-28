// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Ordering names the way the volume orders them.
///
/// A directory on NTFS is a B-tree, and a B-tree is only searchable if
/// everybody agrees on the order. Windows looks a name up by comparing its way
/// and stepping left or right; an entry filed anywhere else is an entry Windows
/// walks straight past. The file is on the disk, in the record, with its bytes
/// -- and not in the directory as far as anything asking Windows is concerned.
///
/// **The order is not the language's.** NTFS uppercases each UTF-16 code unit
/// through `$UpCase`, a table the volume carries, and compares the results as
/// numbers. Swift's `uppercased()` does Unicode case mapping instead, and the
/// two disagree on real names:
///
/// - `ß` U+00DF: `$UpCase` leaves it alone, Swift makes it `SS` -- a different
///   length as well as a different value.
/// - `ı` U+0131, the dotless i: `$UpCase` leaves it alone, Swift makes it `I`.
///
/// Both were read out of the table on a volume, not looked up in a
/// specification. A directory holding `straße.txt` filed by Swift's ordering is
/// a directory Windows cannot find `straße.txt` in.
///
/// So the table comes off the volume. Every volume carries its own, and using
/// one volume's on another would be assuming Microsoft has never revised it.
public struct NTFSCollation: Sendable {

    /// `$UpCase` is record 10 on every NTFS volume.
    public static let record: UInt64 = 10

    /// One entry per UTF-16 code unit: 65536 of them, 128 KB.
    public static let entries = 65536

    private let table: [UInt16]

    /// Read the table. Refuses anything that is not the full 128 KB: a partial
    /// table would order some names correctly and others silently wrongly,
    /// which is worse than not ordering them at all.
    public init?(_ data: Data) {
        guard data.count >= Self.entries * 2 else { return nil }
        var table = [UInt16](repeating: 0, count: Self.entries)
        let base = data.startIndex
        for index in 0..<Self.entries {
            table[index] =
                UInt16(data[base + index * 2]) | (UInt16(data[base + index * 2 + 1]) << 8)
        }
        self.table = table
    }

    /// The identity table, for a volume whose `$UpCase` cannot be read.
    ///
    /// Not a fallback for ordering -- a caller that needs to write must have
    /// the real one. This exists so that comparison has a definition at all in
    /// tests that are about something else.
    public static var identity: NTFSCollation {
        NTFSCollation(identityTable: (0..<UInt32(entries)).map { UInt16($0) })
    }

    private init(identityTable: [UInt16]) { self.table = identityTable }

    /// One code unit, uppercased as this volume uppercases it.
    public func upper(_ unit: UInt16) -> UInt16 { table[Int(unit)] }

    /// Compare two names as NTFS orders them.
    ///
    /// Code unit by code unit, uppercased, as numbers. Where one is a prefix of
    /// the other the shorter comes first -- which is the same rule, applied to
    /// a name that has run out.
    public func compare(_ first: [UInt16], _ second: [UInt16]) -> ComparisonResult {
        let shared = min(first.count, second.count)
        for index in 0..<shared {
            let a = upper(first[index])
            let b = upper(second[index])
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if first.count == second.count { return .orderedSame }
        return first.count < second.count ? .orderedAscending : .orderedDescending
    }

    /// The same, for names held as strings.
    ///
    /// UTF-16 because that is what NTFS stores and what the table is indexed
    /// by. A name that cannot be held in UTF-16 cannot be an NTFS name.
    public func compare(_ first: String, _ second: String) -> ComparisonResult {
        compare(Array(first.utf16), Array(second.utf16))
    }

    /// Whether two names are the same name to this volume.
    ///
    /// Case-insensitively, which is what makes `README.txt` and `readme.txt`
    /// the same file on NTFS and two files on a case-sensitive filesystem.
    public func isSameName(_ first: String, _ second: String) -> Bool {
        compare(first, second) == .orderedSame
    }

    /// Whether a list of names is in the order this volume keeps them in.
    ///
    /// A directory read off the disk should satisfy this. One that does not
    /// means the comparison here is not the comparison that filed them, and
    /// anything inserted using it lands where nothing will look.
    public func isSorted(_ names: [String]) -> Bool {
        for index in 1..<max(names.count, 1) where index < names.count {
            if compare(names[index - 1], names[index]) != .orderedAscending { return false }
        }
        return true
    }
}
