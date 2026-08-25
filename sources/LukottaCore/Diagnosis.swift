// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Turns raw engine output into one plain sentence, without hiding the original.
///
/// Everything here matches on text, because there is nothing else to match on:
/// the engine exits 0 whether or not the mount worked, so the exit status says
/// only that it shut down. What the rules can do is be honest about where each
/// phrase comes from, since that is what says how likely it is to change.
///
/// Most of them are not the engine's words at all. "No key available" is
/// cryptsetup's, "unknown filesystem type" is mount's, and those have been
/// stable for a decade and are what scripts everywhere already depend on. The
/// handful that are the engine's own are marked as such, and are the ones an
/// upgrade can break.
///
/// Which is why `enginesChecked` exists. The lock file pins the engine version;
/// a test compares it with that list and fails when it changes. An upgrade then
/// has to look at these rules deliberately, rather than finding out later that
/// a failure has been showing raw output to people for a release or two.
public enum Diagnosis {

    /// Who writes the words a rule looks for.
    public enum Source: String, Sendable {
        /// cryptsetup, mount, the kernel. Long-standing and widely relied on.
        case linuxTooling
        /// anylinuxfs itself. Free to be reworded in any release.
        case engine
        /// macOS, through the mount path.
        case system
    }

    public struct Rule: Sendable {
        public let name: String
        public let source: Source
        public let patterns: [String]
        /// Whether matching this rule settles the question.
        ///
        /// Most of these are answers about the drive or about what the person
        /// using it must do: a wrong passphrase, a filesystem nothing here can
        /// read, a volume Windows left hibernated. Trying again spends minutes
        /// arriving at the same sentence.
        ///
        /// Two are not. A lock held by another instance and a hypervisor that
        /// refused are both about the machinery of the moment, and the attempt
        /// after them often works -- so a transcript carrying one of those is
        /// still read for whether it is worth another go.
        public let settles: Bool
        /// Built when it matches: the app's name and the reader's language are
        /// both known only then.
        public let message: @Sendable () -> String

        init(
            name: String, source: Source, patterns: [String], settles: Bool = true,
            message: @escaping @Sendable () -> String
        ) {
            self.name = name
            self.source = source
            self.patterns = patterns
            self.settles = settles
            self.message = message
        }

        func matches(_ lowercased: String) -> Bool {
            patterns.contains { lowercased.contains($0) }
        }
    }

    /// Engine versions these rules have actually been checked against.
    ///
    /// Add to it after reading the release notes and the failure paths, not
    /// before. `vendor/engine.lock` is what a test compares against.
    public static let enginesChecked = ["0.19.0"]

    /// In order. The first match wins, so the specific ones come before the
    /// general ones — "no key available" is a wrong password, and would
    /// otherwise be caught by the filesystem rule underneath it.
    public static let rules: [Rule] = [
        Rule(
            name: "no-full-disk-access", source: .engine,
            patterns: ["cannot probe", "insufficient permissions"],
            message: {
                appString(
                    "macOS blocked access to the drive. \(appName) needs Full Disk Access before it can read an encrypted disk."
                )
            }),
        // Four ways of saying the credential was refused. Discovery reports
        // "no key available"; the mount path says "failed to open encrypted
        // device". Neither is a technical problem and neither should read like
        // one.
        Rule(
            name: "wrong-credential", source: .linuxTooling,
            patterns: [
                "wrong key", "invalid passphrase", "no key available", "keyslot",
                "failed to open encrypted device",
            ],
            message: { appString("That password or recovery key did not unlock this drive.") }),
        // Kept for a drive opened before the first sector could be read — with
        // no helper there is no probe, and this is the only thing that says so.
        Rule(
            name: "not-bitlocker", source: .engine,
            patterns: ["not a valid bitlocker", "not a valid bitlk", "no bitlocker"],
            message: { appString("This partition is not a BitLocker volume.") }),
        // cryptsetup refuses a BitLocker volume that Windows is part-way
        // through encrypting or decrypting: `_activate_check` in `bitlk.c`
        // stops when the recorded state is anything but normal, so nothing is
        // written to a volume in that state and nothing can be read from it
        // either. Worth explaining rather than showing as-is, since the remedy
        // is to let Windows finish.
        Rule(
            name: "bitlocker-mid-conversion", source: .linuxTooling,
            patterns: ["unsupported state and cannot be activated"],
            message: {
                appString(
                    "Windows is part-way through encrypting or decrypting this drive. Open it in Windows and let BitLocker finish, then try again."
                )
            }),
        Rule(
            name: "windows-hibernated", source: .linuxTooling,
            patterns: ["hiberfile", "hibernated", "unclean", "dirty"],
            message: {
                appString(
                    "The drive was not shut down cleanly by Windows. Turn off Fast Startup in Windows, or shut Windows down fully rather than hibernating, then try again."
                )
            }),
        Rule(
            name: "unrecognised-filesystem", source: .linuxTooling,
            patterns: ["unknown filesystem type", "no such device"],
            message: {
                appString(
                    "The engine did not recognise a filesystem on this volume. If it is encrypted, the password or recovery key may be wrong."
                )
            }),
        Rule(
            name: "container-not-understood", source: .engine,
            patterns: ["cannot be mounted directly", "lvm2_member"],
            message: {
                appString(
                    "This drive holds several volumes inside it, and \(appName) could not work out which ones. Reporting this would help."
                )
            }),
        // The engine writes to the guest filesystem only while holding its lock
        // exclusively, and it cannot have it exclusively while another drive is
        // open. Lukotta does that write at launch to keep this from happening,
        // so reaching here means a drive was already open when the engine
        // changed under it.
        Rule(
            name: "engine-lock-held", source: .engine,
            patterns: ["another instance is already running"], settles: false,
            message: {
                appString(
                    "Another drive is open, and the drive engine has to run on its own the first time after it changes. Eject the other drives, open this one, then they can all be open together again."
                )
            }),
        Rule(
            name: "already-mounted", source: .system,
            patterns: ["already mounted"],
            message: {
                appString("macOS already has this drive mounted. Eject it in Finder and try again.")
            }),
        Rule(
            name: "hypervisor-refused", source: .system,
            patterns: ["hypervisor", "hv_", "vmm"], settles: false,
            message: {
                appString(
                    "The virtualisation engine could not start. A restart usually clears this.")
            }),
        Rule(
            name: "busy", source: .linuxTooling,
            patterns: ["resource busy", "device busy"],
            message: { appString("The drive is busy. Close anything using it, then try again.") }),
    ]

    /// The rule that explains this transcript, if one does.
    ///
    /// Separate from `summarise` so a failure can record which rule spoke —
    /// or that none did, which is what an upstream rewording looks like from
    /// the inside.
    public static func rule(for transcript: String) -> Rule? {
        let lower = transcript.lowercased()
        return rules.first { $0.matches(lower) }
    }

    public static func summarise(_ transcript: String, fallback: String) -> String {
        if let rule = rule(for: transcript) {
            Log.mount.notice("failure explained by \(rule.name, privacy: .public)")
            return rule.message()
        }
        // Nothing matched. Either it is a failure nobody has seen before, or a
        // phrase that has been reworded upstream and every one of these rules
        // has quietly stopped firing. Said out loud, so a bug report carries it.
        Log.mount.notice("no rule explained the failure; falling back to engine output")

        // Prefer the engine's last meaningful line over a generic message —
        // but the last line is usually the tail of an orderly shutdown, which
        // says nothing about why anything failed. Look for the complaint first.
        // Lukotta's own markers are plumbing for the step indicator. One
        // surfacing as the explanation of a failure — "LUKOTTA_STAGE:working" —
        // tells the user nothing and reads like a fault in the app.
        let lines = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("LUKOTTA_") }
        let noise = [
            "exited with status", "kernel log saved", "vm report received",
            "nfs server not ready", "using the background helper",
        ]
        if let complaint = lines.last(where: { line in
            let l = line.lowercased()
            return (l.contains("error") || l.contains("failed") || l.contains("cannot"))
                && !noise.contains(where: l.contains)
        }) {
            return complaint
        }
        if let last = lines.last(where: { line in
            let l = line.lowercased()
            return line.count > 8 && !noise.contains(where: l.contains)
        }) {
            return last
        }
        let fb = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fb.isEmpty { return fb }
        // No output at all usually means the drive went away before the engine
        // reached it, which is worth saying rather than shrugging.
        return lines.isEmpty
            ? appString("The engine reported nothing at all. The drive may have been unplugged.")
            : appString("No reason was reported. The details below may say more.")
    }
}
