// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Mounting a drive through the filesystem extension rather than over NFS.
///
/// The command is `mount -F`, which mount(8) describes as forcing "the file
/// system type be considered as an FSModule delivered using FSKit". What comes
/// back has to be read rather than trusted, for the same reason the engine's
/// exit status is worthless (see `Diagnosis`): the interesting failures all
/// report the same way.
///
/// Only one of those failures matters, and it is not a failure of the drive:
///
///     Module com.lukotta.v2.fs is disabled!
///     mount: Unable to invoke task
///
/// That is the switch in System Settings that this application cannot set --
/// `FSModuleIdentity.enabled` is readonly and `FSClient` only reads. It means
/// "serve this drive over NFS instead", and it means nothing to the person
/// using the Mac, who is never told about it. See `FilesystemRoute`.
public enum ExtensionMount {

    /// What an attempt came to.
    public enum Outcome: Equatable, Sendable {
        /// Mounted. The volume is local.
        case mounted
        /// The extension is not enabled, or not installed. Take the other route
        /// and say nothing.
        case unavailable
        /// It could have worked and did not. Worth a diagnosis, and still worth
        /// falling back rather than failing in front of somebody.
        case failed(String)
    }

    /// The filesystem name the module registers under. One definition, because
    /// the Info.plist of the extension and this have to agree exactly or the
    /// mount finds nothing.
    public static let filesystemName = "lukottafs"

    /// The command, as arguments rather than a string.
    ///
    /// Never composed into a shell line: a volume name is somebody else's text,
    /// and a drive called `; rm -rf ~` has been a real filename since filenames
    /// existed.
    public static func command(device: String, mountPoint: String, readOnly: Bool) -> [String] {
        var arguments = ["/sbin/mount", "-F", "-t", filesystemName]
        if readOnly { arguments += ["-o", "ro"] }
        arguments += [device, mountPoint]
        return arguments
    }

    /// What the attempt came to, read from what it printed.
    ///
    /// Matched on the words, because the exit status does not distinguish a
    /// module that is switched off from a drive that could not be read, and
    /// those two mean opposite things: one is "use the other route quietly",
    /// the other is "this drive has a problem".
    public static func outcome(status: Int32, output: String) -> Outcome {
        let text = output.replacingOccurrences(of: "\r", with: "")
        let lowered = text.lowercased()

        // The switch. Said by mount itself, and the only phrasing it has.
        if lowered.contains("is disabled") || lowered.contains("unable to invoke task") {
            return .unavailable
        }
        // No module of that name registered at all: an ordinary build, or one
        // whose extension a system update de-registered.
        if lowered.contains("unknown file system type")
            || lowered.contains("no such file system")
            || lowered.contains("operation not supported by device")
        {
            return .unavailable
        }
        if status == 0 { return .mounted }
        let summary =
            text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        return .failed(summary ?? "The drive did not open through the filesystem extension.")
    }

    /// Whether an outcome means "take the other route".
    ///
    /// Everything except a mount does. A failure is not a reason to leave
    /// somebody without their drive: the route that has always worked is still
    /// there, and it is the one they had yesterday.
    public static func shouldFallBack(_ outcome: Outcome) -> Bool {
        outcome != .mounted
    }

    /// Whether an outcome is worth putting in the log.
    ///
    /// A switch that is off is not: it is the ordinary state of every Mac where
    /// nobody has turned the extension on, and logging it on every mount would
    /// bury the failures that mean something.
    public static func isWorthLogging(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .mounted, .unavailable: return false
        case .failed: return true
        }
    }
}
