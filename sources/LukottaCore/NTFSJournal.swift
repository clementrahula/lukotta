// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What `$LogFile` says about work the volume has not finished.
///
/// NTFS writes down what it is about to do before doing it. A change that
/// touches more than one structure -- claiming a cluster and recording it in a
/// file, say -- is written to the journal first, performed, then marked done. On
/// the next mount, anything unfinished is completed or undone, so the volume is
/// never left with two structures disagreeing.
///
/// **This does not write the journal, and that is the whole point of it.** A
/// filesystem that changes two structures without journalling can leave a
/// cluster claimed by a file the bitmap says is free -- which the next
/// allocation hands to somebody else, and both files are gone. So until v2 can
/// journal, it may only make changes that touch exactly one thing.
///
/// What it can do is *read* the journal's state, and refuse a volume that has
/// unfinished work in it. That is a real protection with no journalling
/// required: a volume Windows left mid-transaction must be given back to
/// Windows, or to chkdsk, and not written to by anybody else.
public enum NTFSJournal {

    /// `$LogFile` is record 2 on every NTFS volume.
    public static let record: UInt64 = 2

    /// A restart page, which is where the journal's own bookkeeping lives.
    public static let restartSignature = Array("RSTR".utf8)
    /// A page of log records.
    public static let recordSignature = Array("RCRD".utf8)
    /// What mkntfs leaves behind, and what a journal reset to empty looks
    /// like: every byte 0xFF.
    public static let emptyByte: UInt8 = 0xFF

    public enum State: Equatable, Sendable {
        /// Never used, or reset. Nothing outstanding, and safe.
        case empty
        /// In use, with its bookkeeping intact. Whether anything is
        /// outstanding cannot be told without replaying it, which is not done
        /// here -- so this is treated as unsafe.
        case inUse
        /// Neither of the above: not a journal this understands.
        case unrecognised
    }

    /// Read the journal's state from its first page.
    ///
    /// - Parameter page: the beginning of `$LogFile`. A page is 4096 bytes on
    ///   every volume seen, but only the first bytes are needed.
    public static func state(firstPage page: Data) -> State {
        guard page.count >= 8 else { return .unrecognised }
        let start = page.startIndex

        // A journal that has never been written is every byte 0xFF. Checking a
        // generous prefix rather than the first four bytes: four bytes of 0xFF
        // could be a coincidence in a page that holds something else.
        let prefix = min(page.count, 512)
        if page[start..<start + prefix].allSatisfy({ $0 == emptyByte }) {
            return .empty
        }

        let signature = Array(page[start..<start + 4])
        if signature == restartSignature || signature == recordSignature {
            return .inUse
        }
        return .unrecognised
    }

    /// Whether a volume with a journal in this state may be written to.
    ///
    /// Only an empty one. A journal in use may hold a transaction that was
    /// never completed, and finishing or undoing it is what a mount is supposed
    /// to do -- writing over it instead leaves the volume in a state no
    /// implementation can reason about, including chkdsk.
    ///
    /// Unrecognised is refused for the same reason as everywhere else in this
    /// reader: not understanding something is not the same as knowing it is
    /// harmless.
    public static func mayWrite(_ state: State) -> Bool {
        state == .empty
    }

    /// Whether a volume with a journal in this state may be read.
    ///
    /// Always. A drive with unfinished work in its journal is precisely the
    /// drive somebody wants their files off, and reading changes nothing --
    /// the worst case is that a file reflects a change that was never
    /// completed, which is the same thing Windows would show before replaying.
    public static func mayRead(_ state: State) -> Bool { true }
}
