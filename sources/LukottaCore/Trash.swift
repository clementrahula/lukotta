// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The one directory that makes deleting from a Lukotta drive feel like
/// deleting from any other.
///
/// Finder does not delete a file when somebody presses ⌘⌫. It renames it into
/// `.Trashes/<uid>` at the top of the volume, which is one operation whatever is
/// inside it, and empties the Trash later or never. Where that directory cannot
/// be made, Finder falls back to unlinking each file in turn and, part way
/// through, gives up with "some items had to be skipped".
///
/// That fallback is what a Lukotta drive has always got, and it is the worst
/// thing about the product. Measured on this machine against an NTFS volume the
/// application served:
///
///     delete 6000 files, one unlink at a time     4028 ms
///     delete 6000 files, renamed into .Trashes       2.9 ms
///     delete 20000 files, renamed into .Trashes      6.3 ms
///
/// Three times the files for twice the time, because the count is not what a
/// rename costs. A million files is the same rename.
///
/// **This writes to a drive somebody asked us to open, which this application
/// otherwise does not do.** The rule is right about contents and worth keeping
/// everywhere else. What it costs here is the whole of the deletion experience,
/// against one empty directory that every native volume already has and that
/// macOS makes by itself on any external disk somebody deletes from. The
/// directory is created empty, owned by whoever opened the drive, readable by
/// nobody else, and never written to again by us.
public enum Trash {

    /// Where Finder looks. Not configurable: the name and the layout are
    /// Finder's, and a directory anywhere else is one it will not find.
    public static func directory(onVolumeAt mountPoint: String, uid: uid_t) -> String {
        (mountPoint as NSString)
            .appendingPathComponent(".Trashes")
            .appending("/\(uid)")
    }

    /// Make it, if the volume can take it.
    ///
    /// Never throws into the mount path and never fails a mount. A drive that
    /// will not hold a `.Trashes` -- read-only, out of space, a filesystem
    /// whose driver refuses the name -- is a drive that behaves exactly as it
    /// did before this existed, which is the old behaviour and not a fault.
    ///
    /// - Returns: whether Finder will now find one.
    @discardableResult
    public static func prepare(
        onVolumeAt mountPoint: String,
        readOnly: Bool,
        uid: uid_t = getuid(),
        manager: FileManager = .default
    ) -> Bool {
        // A read-only mount cannot take one, and asking would put a write error
        // in the log of every read-only drive anybody opens.
        guard !readOnly, !mountPoint.isEmpty else { return false }

        let path = directory(onVolumeAt: mountPoint, uid: uid)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            // 0o700: somebody else's deleted files are not ours to read, and
            // this is the mode macOS itself uses for a per-user trash.
            try manager.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            Log.mount.info(
                "prepared a trash directory on the volume, so deleting is a rename")
            return true
        } catch {
            // Worth knowing, not worth telling anybody about: the drive still
            // works, deleting is just as slow as it was.
            Log.mount.info(
                "no trash directory on this volume: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
