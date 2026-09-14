// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Keeps the guest filesystem in step with the engine the app ships.
///
/// The engine copies `vmproxy` from its bundle into the guest filesystem when
/// the bundled file is a different size or newer, and it takes an exclusive
/// lock on /tmp/anylinuxfs.lock to do it. Every mount holds that lock shared,
/// so with any drive open the copy is refused and so is the mount asking for
/// it: "another instance is already running". A rebuild or an update gives the
/// bundled file a newer timestamp over identical bytes, which is enough.
///
/// Settled here before each mount instead. Identical bytes need only the
/// timestamp; different bytes are staged and renamed over the old file, which a
/// machine running from it keeps. Neither needs the lock, and afterwards the
/// engine's own test finds nothing to copy.
public enum GuestRuntime {
    static let overrideStatAttribute = "user.containers.override_stat"

    static var guestVMProxy: URL {
        EngineEnvironment.alpineDirectory
            .appendingPathComponent("rootfs/vmproxy")
    }

    static var bundledVMProxy: URL? {
        EnginePaths.engineRoot?.appendingPathComponent("anylinuxfs/libexec/vmproxy")
    }

    /// The engine's own test, reproduced: size first, then whether the bundled
    /// one is newer, to the nanosecond, as the engine compares them.
    public static func needsSync(
        bundledSize: Int64, bundledModified: timespec,
        guestSize: Int64, guestModified: timespec
    ) -> Bool {
        if bundledSize != guestSize { return true }
        if bundledModified.tv_sec != guestModified.tv_sec {
            return bundledModified.tv_sec > guestModified.tv_sec
        }
        return bundledModified.tv_nsec > guestModified.tv_nsec
    }

    /// Bring the guest copy up to date, if it is out of date.
    ///
    /// Returns whether anything changed.
    @discardableResult
    public static func syncIfNeeded() -> Bool {
        guard let bundled = bundledVMProxy else { return false }
        return sync(bundled: bundled, guest: guestVMProxy)
    }

    public static func sync(bundled: URL, guest: URL) -> Bool {
        var bundledInfo = stat()
        var guestInfo = stat()
        guard stat(bundled.path, &bundledInfo) == 0, stat(guest.path, &guestInfo) == 0,
            needsSync(
                bundledSize: bundledInfo.st_size, bundledModified: bundledInfo.st_mtimespec,
                guestSize: guestInfo.st_size, guestModified: guestInfo.st_mtimespec)
        else { return false }

        let fm = FileManager.default
        if bundledInfo.st_size == guestInfo.st_size,
            fm.contentsEqual(atPath: bundled.path, andPath: guest.path)
        {
            return setModificationTime(bundledInfo.st_mtimespec, of: guest)
        }

        // The attribute tells the runtime what owner and mode to report. A guest
        // file without one is not the file this expects, so it is left alone.
        guard let override = extendedAttribute(overrideStatAttribute, of: guest) else {
            return false
        }

        let staging = guest.deletingLastPathComponent()
            .appendingPathComponent(".vmproxy.lukotta-staged-\(getpid())")
        try? fm.removeItem(at: staging)
        guard (try? fm.copyItem(at: bundled, to: staging)) != nil,
            setExtendedAttribute(overrideStatAttribute, to: override, of: staging),
            setModificationTime(bundledInfo.st_mtimespec, of: staging),
            rename(staging.path, guest.path) == 0
        else {
            try? fm.removeItem(at: staging)
            return false
        }
        return true
    }

    /// The exact time, nanoseconds included: a Date rounds to microseconds, and
    /// rounded down the engine still finds its own copy newer.
    static func setModificationTime(_ time: timespec, of url: URL) -> Bool {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), time]
        return utimensat(AT_FDCWD, url.path, &times, 0) == 0
    }

    // MARK: Extended attributes

    static func extendedAttribute(_ name: String, of url: URL) -> Data? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length >= 0 else { return nil }
        var buffer = Data(count: length)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(url.path, name, raw.baseAddress, length, 0, 0)
        }
        return read == length ? buffer : nil
    }

    static func setExtendedAttribute(_ name: String, to value: Data, of url: URL) -> Bool {
        value.withUnsafeBytes { raw in
            setxattr(url.path, name, raw.baseAddress, value.count, 0, 0) == 0
        }
    }
}
