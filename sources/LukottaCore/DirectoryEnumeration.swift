// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Handing a directory to the kernel a bufferful at a time.
///
/// FSKit does not ask for a directory's contents in one call. It gives the
/// module a buffer, the module packs entries into it until it is full, and each
/// entry carries a *cookie* -- the place to start from next time. The kernel
/// then calls again with the cookie of the last entry that fitted.
///
/// **The cookie has to name the entry after the one it was handed with.** One
/// off in either direction is not an error anybody sees: too high and a file
/// disappears from the folder, too low and one appears twice. Both look like a
/// strange drive rather than like arithmetic.
///
/// Kept here rather than in the extension because the extension cannot be
/// tested -- it is an appex that only runs when macOS loads it -- and this is
/// the part of it with something to get wrong.
public enum DirectoryEnumeration {

    /// What to pack, and what cookie to give it.
    public struct Step<Entry>: Equatable where Entry: Equatable {
        public let entry: Entry
        /// Where a later call should resume to get the entry after this one.
        public let nextCookie: UInt64

        public init(entry: Entry, nextCookie: UInt64) {
            self.entry = entry
            self.nextCookie = nextCookie
        }
    }

    /// The entries to hand over, starting from a cookie.
    ///
    /// - Parameters:
    ///   - entries: the directory's contents, in a stable order. An order that
    ///     changes between calls makes every cookie point at a different file.
    ///   - cookie: where the last call stopped. Zero starts at the beginning.
    /// - Returns: each entry with the cookie that follows it. Empty when the
    ///   cookie is at or past the end, which is how an enumeration finishes.
    public static func steps<Entry>(
        _ entries: [Entry], from cookie: UInt64
    ) -> [Step<Entry>] where Entry: Equatable {
        // A cookie past the end is the ordinary way a listing ends, not a
        // fault. One that cannot be an index at all is treated the same way
        // rather than trusted into a subscript.
        guard cookie <= UInt64(Int.max) else { return [] }
        let start = Int(cookie)
        guard start >= 0, start < entries.count else { return [] }

        return entries[start...].enumerated().map { offset, entry in
            Step(entry: entry, nextCookie: UInt64(start + offset + 1))
        }
    }

    /// Whether a cookie means the listing is finished.
    public static func isFinished<Entry>(_ entries: [Entry], cookie: UInt64) -> Bool {
        cookie > UInt64(Int.max) || Int(cookie) >= entries.count
    }

    /// Where to resume after a buffer filled up.
    ///
    /// The kernel resumes from the cookie of the last entry that *fitted*, so
    /// an entry that did not fit is asked for again. Handing back the cookie of
    /// the entry that failed would skip it.
    public static func resumeCookie<Entry>(
        after packed: [Step<Entry>], from cookie: UInt64
    ) -> UInt64 where Entry: Equatable {
        packed.last?.nextCookie ?? cookie
    }
}
