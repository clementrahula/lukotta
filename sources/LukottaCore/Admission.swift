// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Whether a volume the partition types threw away belongs in the list after
/// all.
///
/// `diskutil` reports the partition table macOS chose to read, and on a stick
/// that has been reformatted since it was partitioned that table is out of
/// date. Two shapes of that were measured on 2026-09-05:
///
///     a volume of a type this app makes nothing of, whose first sector names
///     a filesystem it opens -- an Apple_HFS partition holding exFAT
///
///     a whole disk none of whose partitions is openable and whose own first
///     sector is a partition table rather than a filesystem -- a stale Apple
///     partition map over an NTFS stick formatted on Windows, where macOS saw
///     a 4 MB Apple_HFS volume and nothing else on 123 GB
///
/// The first is decided by the sector. The second cannot be: the guest reads
/// tables macOS refuses to, so the disk is offered whole and the engine finds
/// what is on it -- but only where nothing else on that disk was openable and
/// macOS is using none of it. A stick macOS has mounted is one macOS can
/// already serve, and a second row for it would be a row that does nothing.
public enum Admission {
    public static func admitsVolume(sectorSays format: VolumeFormat) -> Bool {
        format != .unknown && format.kind != nil
    }

    public static func admitsWholeDisk(
        otherRowsOnTheSameDisk: Bool, macOSIsUsingTheDisk: Bool
    ) -> Bool {
        !otherRowsOnTheSameDisk && !macOSIsUsingTheDisk
    }
}
