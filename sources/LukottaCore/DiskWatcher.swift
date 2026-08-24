// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import DiskArbitration
import Foundation

/// Notices drives arriving and leaving, as it happens.
///
/// Polling would eventually notice too, but the delay is the whole problem: a
/// drive pulled out while the list is on screen leaves a row offering to open
/// something that is no longer there. DiskArbitration reports both events
/// immediately and needs no privileges.
public final class DiskWatcher {
    private var session: DASession?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    /// Partition types that hold something macOS cannot read but Lukotta can.
    ///
    /// Claiming one of these stops the system offering to initialise it. The
    /// values are what DiskArbitration reports as the media content: a GPT
    /// type GUID, or a name for the older partition schemes.
    private static let ourContent = [
        "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",  // Microsoft Basic Data — BitLocker or NTFS
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4",  // Linux filesystem
        "E6D6D379-F507-44C2-A23C-238F2A3DF928",  // Linux LVM
        "A19D880F-05FC-4D3B-A006-743F0F84911E",  // Linux RAID
        "Windows_NTFS",  // the MBR name, which is what Windows writes on a stick
        "Linux",  // likewise, for an MBR Linux partition
    ]

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        // Unretained: the watcher owns the session, so it cannot outlive one.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notify: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        DARegisterDiskAppearedCallback(session, nil, notify, context)
        DARegisterDiskDisappearedCallback(session, nil, notify, context)

        // Claim the drives Lukotta understands, so macOS stops offering to
        // initialise them — an offer that sits one click from destroying an
        // encrypted drive, made precisely because macOS cannot read it.
        //
        // Done from the peek callback rather than on appearance: peek is
        // delivered synchronously and the daemon waits for the answer, so the
        // claim is registered before it can decide the disk is unreadable.
        // Appearance callbacks are fire-and-forget, and would be a race.
        let peek: DADiskPeekCallback = { disk, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().claim(disk)
        }
        for content in Self.ourContent {
            let match =
                [kDADiskDescriptionMediaContentKey as String: content] as CFDictionary
            DARegisterDiskPeekCallback(session, match, 0, peek, context)
        }
        DASessionScheduleWithRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func stop() {
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.session = nil
        pending?.cancel()
        pending = nil
    }

    /// Take the disk, so it is not reported as unreadable.
    ///
    /// The claim lasts as long as this session and is dropped when the app
    /// quits, so nothing is left holding a drive afterwards. The release
    /// callback answers nil, yielding to anyone who genuinely wants it —
    /// refusing would make Lukotta the reason a disk tool could not work.
    private func claim(_ disk: DADisk) {
        let yield: DADiskClaimReleaseCallback = { _, _ in nil }
        DADiskClaim(disk, DADiskClaimOptions(kDADiskClaimOptionDefault), yield, nil, nil, nil)
    }

    /// One drive produces a callback per partition, and unplugging a drive with
    /// three volumes on it produces a burst. Rescanning on each would run the
    /// scan several times over for a single event, so let the burst finish.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    deinit { stop() }
}
