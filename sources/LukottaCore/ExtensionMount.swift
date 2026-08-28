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
/// `FSModuleIdentity.enabled` is readonly and `FSClient` only reads.
///
/// **There is no second route.** v2 serves drives through the extension and
/// through nothing else: no NFS, no engine mount, no network volume. The whole
/// reason v2 exists is that a network volume cannot behave like a disk, so
/// keeping one behind it as a fallback would mean shipping the problem v2 was
/// built to remove and calling it a safety net.
public enum ExtensionMount {

    /// What an attempt came to.
    public enum Outcome: Equatable, Sendable {
        /// Mounted. The volume is local.
        case mounted
        /// The extension is not enabled, or not installed. Nothing can be
        /// served until it is; there is nothing else to try.
        case unavailable
        /// It could have worked and did not. Worth a diagnosis.
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
    /// those two mean opposite things: one is about this Mac's settings, the
    /// other is about the drive. They are not the same sentence to anybody.
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

    /// Whether an outcome is worth putting in the log.
    ///
    /// A switch that is off is not: it is the ordinary state of a Mac where
    /// nobody has turned the extension on yet, and logging it on every attempt
    /// would bury the failures that mean something.
    public static func isWorthLogging(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .mounted, .unavailable: return false
        case .failed: return true
        }
    }
}

extension ExtensionMount {

    /// Whether this build carries a filesystem extension at all.
    ///
    /// Only the v2 channel does. Checked by looking inside the running bundle
    /// rather than by a build flag, for the same reason the app reads its own
    /// name and identifier from the bundle: a build states what it can do
    /// instead of a constant claiming it can.
    ///
    /// This says nothing about whether the module is *enabled*. Nothing can:
    /// `FSModuleIdentity.enabled` is readonly and there is no way to ask. The
    /// answer to that question is the attempt itself.
    public static func isCarried(in bundle: Bundle = .main) -> Bool {
        guard
            let extensions = bundle.builtInPlugInsURL?
                .deletingLastPathComponent()
                .appendingPathComponent("Extensions", isDirectory: true)
        else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        return names.contains { $0.hasSuffix(".appex") }
    }

    /// Whether this Mac could run one. FSKit arrives in macOS 15.4, and the
    /// application supports 15.0.
    public static func systemSupportsExtensions(
        _ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        if version.majorVersion > 15 { return true }
        return version.majorVersion == 15 && version.minorVersion >= 4
    }
}
