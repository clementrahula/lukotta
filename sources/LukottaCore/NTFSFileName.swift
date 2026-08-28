// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A file's name, as NTFS stores it.
///
/// The `$FILE_NAME` attribute holds the name, the record number of the
/// directory holding it, and a second copy of the timestamps and sizes. It is
/// what turns a record into something anybody can see.
///
/// **A file usually has more than one of these, and picking the wrong one shows
/// the wrong name.** NTFS keeps a short DOS-compatible name alongside the real
/// one -- `PROGRA~1` beside `Program Files` -- so a record can carry two or
/// three `$FILE_NAME` attributes that differ only in their namespace byte. A
/// reader that takes the first one it finds shows eight-character names for
/// half a disk.
///
/// The name itself is UTF-16 little-endian, and its length is in *characters*
/// rather than bytes, which is the other easy mistake: a name read at byte
/// length comes out doubled and truncated.
public enum NTFSFileName {

    /// Which naming rules a name follows.
    ///
    /// The order matters when a record carries several: Win32 is the name
    /// somebody typed, POSIX is a name only a case-sensitive system could make,
    /// and DOS is the short one nobody wants to see.
    public enum Namespace: UInt8, Sendable, Comparable {
        /// Case-sensitive, any character but `/` and NUL. Rare.
        case posix = 0
        /// The ordinary name, the one to show.
        case win32 = 1
        /// The 8.3 short name. Never shown when anything else exists.
        case dos = 2
        /// One name that satisfies both rules at once, so it is the real name.
        case win32AndDos = 3

        /// How much this name is worth showing, highest first.
        var preference: Int {
            switch self {
            case .win32: return 3
            case .win32AndDos: return 2
            case .posix: return 1
            case .dos: return 0
            }
        }

        public static func < (a: Namespace, b: Namespace) -> Bool {
            a.preference < b.preference
        }
    }

    public struct Name: Sendable, Equatable {
        /// The record number of the directory this name is in. A file hard-
        /// linked into two directories has a `$FILE_NAME` for each.
        public let parentRecord: UInt64
        public let namespace: Namespace
        public let name: String

        public init(parentRecord: UInt64, namespace: Namespace, name: String) {
            self.parentRecord = parentRecord
            self.namespace = namespace
            self.name = name
        }
    }

    /// Read one `$FILE_NAME` value.
    ///
    /// - Parameter value: the attribute's value, not the whole record.
    public static func read(_ value: Data) -> Name? {
        // 8 bytes of parent reference, 32 of timestamps, 16 of sizes, flags,
        // reparse, then the length and namespace bytes: 66 before the name.
        guard value.count >= 66 else { return nil }
        let base = value.startIndex

        // The parent is a file reference: 48 bits of record number and 16 of
        // sequence number. Only the record number addresses anything.
        var reference: UInt64 = 0
        for i in (0..<8).reversed() {
            reference = (reference << 8) | UInt64(value[base + i])
        }
        let parent = reference & 0x0000_FFFF_FFFF_FFFF

        let characters = Int(value[base + 64])
        guard let namespace = Namespace(rawValue: value[base + 65] & 0x03) else { return nil }

        // The length is in UTF-16 characters. Read as bytes it comes out
        // doubled and truncated, which is the mistake that shows half a name.
        let bytes = characters * 2
        guard characters > 0, 66 + bytes <= value.count else { return nil }

        let start = base + 66
        var units: [UInt16] = []
        units.reserveCapacity(characters)
        for i in 0..<characters {
            let low = UInt16(value[start + i * 2])
            let high = UInt16(value[start + i * 2 + 1])
            units.append(low | (high << 8))
        }
        let name = String(decoding: units, as: UTF16.self)
        // A name with a separator or a NUL in it did not come from a filesystem
        // that meant it, and would let a listing escape its own directory.
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }

        return Name(parentRecord: parent, namespace: namespace, name: name)
    }

    /// The one to show, out of everything a record carries.
    ///
    /// A record with a Win32 name and a DOS name has both; showing the DOS one
    /// gives `PROGRA~1` where somebody wrote `Program Files`.
    public static func preferred(_ names: [Name]) -> Name? {
        names.max { $0.namespace.preference < $1.namespace.preference }
    }
}
