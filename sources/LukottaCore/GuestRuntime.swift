import Foundation

/// Keeps the guest filesystem in step with the engine the app ships.
///
/// The engine holds a shared lock on /tmp/anylinuxfs.lock for the life of a
/// mount, so drives sit alongside each other. It upgrades that lock to an
/// exclusive one only when it has to write to the guest filesystem, and the one
/// thing it writes there is `vmproxy`, copied out of the app bundle whenever the
/// copy in the guest differs. The upgrade cannot succeed while another drive is
/// open, and the mount fails with "another instance is already running".
///
/// That only bites after the vendored engine changes, because the bundled file
/// keeps its timestamp through a rebuild. It bites exactly then, though: drives
/// stay open across an update, so the first mount afterwards is likely to have
/// company.
///
/// Doing the copy at launch, while nothing is mounted, means the engine never
/// needs the exclusive lock at a moment when it cannot have it.
public enum GuestRuntime {
    static let overrideStatAttribute = "user.containers.override_stat"

    static var guestVMProxy: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anylinuxfs/alpine/rootfs/vmproxy")
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

    /// Bring the guest copy up to date, if it is out of date and it is safe to.
    ///
    /// Returns whether anything was copied. Every reason to decline is a reason
    /// to leave the guest filesystem exactly as it is and let the engine deal
    /// with it: this writes into the engine's private state, so it does the
    /// smallest possible thing or nothing at all.
    @discardableResult
    public static func syncIfNeeded() -> Bool {
        let fm = FileManager.default
        guard let bundled = bundledVMProxy else { return false }
        let guest = guestVMProxy
        guard fm.fileExists(atPath: bundled.path), fm.fileExists(atPath: guest.path) else {
            return false
        }

        guard let bundledAttrs = try? fm.attributesOfItem(atPath: bundled.path),
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

        // The guest file carries an attribute telling the runtime what to report
        // for its owner and mode. Copy it across rather than invent one: if it
        // is missing or unreadable this is not the file we think it is, so leave
        // the whole thing alone.
        guard let override = extendedAttribute(overrideStatAttribute, of: guest) else {
            return false
        }

        // Take the lock the engine takes. Held exclusively, so this cannot run
        // beside a mount that is starting, and a mount cannot start beside it.
        // Failing to get it means a drive is open, which is precisely when this
        // must not happen.
        guard let lock = EngineLock() else { return false }
        guard lock.acquireExclusive() else { return false }
        defer { lock.release() }

        let staging = guest.deletingLastPathComponent()
            .appendingPathComponent(".vmproxy.lukotta-staged")
        try? fm.removeItem(at: staging)
        guard (try? fm.copyItem(at: bundled, to: staging)) != nil else {
            try? fm.removeItem(at: staging)
            return false
        }

        guard setExtendedAttribute(overrideStatAttribute, to: override, of: staging) else {
            try? fm.removeItem(at: staging)
            return false
        }
        // Match the timestamp too, so the engine's test comes out false rather
        // than merely closer, and stays false.
        try? fm.setAttributes([.modificationDate: bundledModified], ofItemAtPath: staging.path)

        guard (try? fm.replaceItemAt(guest, withItemAt: staging)) != nil else {
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

/// The engine's lock file, so the app can stand aside for a running mount.
final class EngineLock {
    private let descriptor: Int32

    init?() {
        let fd = open("/tmp/anylinuxfs.lock", O_RDWR)
        guard fd >= 0 else { return nil }
        descriptor = fd
    }

    func acquireExclusive() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
