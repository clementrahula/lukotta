// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// What a volume needs for a write it has acknowledged to survive the machine
/// dying. The cheapest that fits is used: `data=journal` for ext with a
/// journal, whose own journal carries the guarantee almost free; stable writes
/// for everything else, BitLocker and LUKS included, where the client writes
/// each block stably and the server has it on the device before it answers.
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
        // BitLocker writes stably too, though the engine's COMMIT is durable.
        // Written unstably, the Mac's client holds each block until it commits,
        // and here it stalled: a 256 MiB write sat 200 seconds with the guest
        // idle and holding no request, until another request on the mount set
        // it going. Written stably, six runs went at 8.5 to 16.1 MB/s and none
        // paused for more than six seconds.
        // A LUKS container takes the client's option too, since 2026-09-06.
        //
        // It had the guest's `-o sync` because the superblock inside cannot be
        // read from outside to choose anything cheaper, and that was the only
        // durable option there was. It is not the cheapest one: measured with
        // Finder-shaped copies onto a real LUKS stick holding ext4, the guest
        // option moves 1.2 GB in three large files at 1.0 MB/s. The client's
        // option is durable on the same hardware and does not touch how the
        // filesystem itself writes.
        //
        // The volumes inside a container are mounted by the guest and never see
        // a client option, so `MountScript.perVolumeOptions` carries the same
        // intent down to them when stable writes were asked for. That path
        // exists for exactly this.
        // The client's option, not the guest's, for everything else.
        //
        // Both keep a committed write on real hardware. They are not the same
        // inside the guest: `-o sync` changes how the filesystem itself writes,
        // and on 2026-09-06 that cost two things the client option does not.
        // The NTFS vectors came back with seven of eight fsynced files wrong
        // after a killed machine, on an image where nothing had been wrong
        // before it; and a full volume took 45 seconds to say so where NTFS had
        // taken 2. A person watching a copy stop for three quarters of a minute
        // before being told the drive is full is a UX cost, and item 10 does not
        // allow one.
        return Choice(guestOption: nil, stableWrites: true)
    }
}
