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

    /// The engine's own test, reproduced: size first, then "is the bundled one
    /// newer". Equal timestamps do not count as different, which is what lets a
    /// copy that keeps the timestamp settle the question for good.
    public static func needsSync(
        bundledSize: Int64, bundledModified: Date,
        guestSize: Int64, guestModified: Date
    ) -> Bool {
        if bundledSize != guestSize { return true }
        return bundledModified > guestModified
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
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled.path), fm.fileExists(atPath: guest.path),
            let bundledAttrs = try? fm.attributesOfItem(atPath: bundled.path),
            let guestAttrs = try? fm.attributesOfItem(atPath: guest.path),
            let bundledSize = (bundledAttrs[.size] as? NSNumber)?.int64Value,
            let guestSize = (guestAttrs[.size] as? NSNumber)?.int64Value,
            let bundledModified = bundledAttrs[.modificationDate] as? Date,
            let guestModified = guestAttrs[.modificationDate] as? Date
        else { return false }

        guard
            needsSync(
                bundledSize: bundledSize, bundledModified: bundledModified,
                guestSize: guestSize, guestModified: guestModified)
        else { return false }

        if bundledSize == guestSize, fm.contentsEqual(atPath: bundled.path, andPath: guest.path) {
            return
                (try? fm.setAttributes(
                    [.modificationDate: bundledModified], ofItemAtPath: guest.path))
                != nil
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
            (try? fm.setAttributes([.modificationDate: bundledModified], ofItemAtPath: staging.path))
                != nil,
            rename(staging.path, guest.path) == 0
        else {
            try? fm.removeItem(at: staging)
            return false
        }
        return true
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
