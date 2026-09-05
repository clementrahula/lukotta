// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What it takes for a write that was told it succeeded to still be there
/// afterwards.
///
/// A file written through this app is written over NFS. The client sends the
/// data unstably and asks the server to commit it, and the guest's nfsd answers
/// that commit before the bytes are on the drive. `dd conv=fsync` returns, the
/// application is told the write is safe, and a machine that dies in the next
/// half-minute takes it. The same fsync issued inside the guest, on the same
/// volume, at the same moment, is durable -- so the fault is the commit and
/// nothing below it.
///
/// Measured on a real USB stick on 2026-09-05, 8 MiB fsynced and the engine
/// killed:
///
///     killed at once      130,556 bytes wrong -- the file's whole first
///                         cluster, read back as zeros
///     ten seconds later   130,520 bytes wrong, the same shape
///     sixty seconds later byte-identical
///     ejected cleanly     byte-identical
///
/// Sixty seconds is the guest's own writeback catching up. So the data is not
/// lost, and it is not the client's cache: it sits in the guest waiting for a
/// timer, while the application has been told it is on the drive.
///
/// Three ways to close that, and the cheapest that fits each volume is the one
/// used:
///
///     data=journal     ext with a journal. The filesystem batches into its
///                      own journal, so the guarantee costs almost nothing.
///     -o sync (guest)  everything else, LUKS containers included. The volume
///                      is mounted synchronously inside the guest, so a write
///                      the guest has taken is a write the device has.
///
/// Client-side stable writes were the other candidate and are not used. They
/// keep the data just as well -- six of six on two drives -- and cost the same
/// as the guest option, so the one that reaches every volume of a container
/// wins. Both were measured on the drives, 256 MiB in one stream to the 247 GB
/// BitLocker drive:
///
///     nothing applied (what shipped)   7.7 - 8.5 MB/s, and 3 of 3 lost
///     client stable writes, 32 KiB     1.7 MB/s
///     guest -o sync, 32 KiB            2.0 MB/s
///     guest -o sync, 128 KiB           14.0 MB/s, and 3 of 3 kept
///
/// The rate was never a bandwidth limit: a durable stream at a 32 KiB write
/// size is 53 writes a second, which is one device flush of about 19 ms each.
/// The write size is what sets it, and at 128 KiB the durable mount is nearly
/// twice as fast as the unsafe one it replaces.
///
/// Nothing is left without one. NTFS and exFAT had nothing until today, on a
/// measurement that turned out to have been taken by a harness which never ran
/// past the line that opens the drive -- and both lose fsynced data on a real
/// drive, which is what the images could never show: an image is backed by a
/// file, so the host's own buffer cache writes it out even when the guest dies.
public enum Durability {
    public struct Choice: Equatable, Sendable {
        /// Passed to the volume's mount inside the guest, when one applies.
        public let guestOption: String?
        /// Whether the client is asked to write stably rather than to write
        /// and commit.
        public let stableWrites: Bool
    }

    /// The guarantee for one volume, read from the volume itself.
    ///
    /// Needs to be able to read the device node, so it is asked where that is
    /// true: in the daemon for a real drive, and in the app for a container
    /// file this user attached.
    public static func choice(forDevice path: String) -> Choice {
        if let journalled = ExtJournal.durabilityOption(forDevice: path) {
            return Choice(guestOption: journalled, stableWrites: false)
        }
        if LUKSHeader.isContainer(forDevice: path) {
            return Choice(guestOption: "sync", stableWrites: false)
        }
        return Choice(guestOption: "sync", stableWrites: false)
    }
}
