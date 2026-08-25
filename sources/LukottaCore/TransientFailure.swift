// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Failures that mean "the machinery slipped", not "this cannot be opened".
///
/// The engine starts a virtual machine per mount and talks to it over a socket
/// and a pipe. On a busy Mac either can go for a moment, and none of that says
/// anything about the drive: "Broken pipe (os error 32)" is about a disk that
/// opens perfectly well a second later. So the attempt is made again, and only
/// what survives three of them is shown.
///
/// Deliberately narrow. A wrong password, a filesystem nobody can read, a
/// hibernated Windows volume: those are answers, and trying again spends a
/// minute of somebody's time arriving at the same place.
public enum TransientFailure {

    /// Read from the engine's own output. Lowercased before matching, since
    /// what wrote each of these disagrees about capitals.
    public static let signatures = [
        "broken pipe",
        "os error 32",
        "failed to write to pipe",
        "connection reset",
        "resource temporarily unavailable",
        "os error 35",
        "start vm error",
        "vm exited unexpectedly",
        "failed to start the virtual machine",
        "connection refused",
        "os error 61",
        // The image is held by a machine that has not finished going away. The
        // retry takes down whatever is serving nothing before it tries again,
        // which is what releases it.
        "failed to acquire lock",
        "already locked",
        // macOS refusing the NFS mount the engine asked for. The server is the
        // machine that has just come up inside the engine, and a moment later
        // the same request works.
        "failed to request nfs mount",
        // What this app says when it stops waiting for an attempt of its own.
        deadlineReached,
    ]

    /// The same list, as one case-insensitive pattern for grep.
    ///
    /// The mount script decides the same thing inside the shell, one attempt
    /// earlier: whether what just failed was worth another go before falling
    /// back to read-only. It used to carry a list written out by hand, which
    /// drifted from this one in both directions -- phrases here that the script
    /// never matched, phrases there that nothing in Swift knew about. Built
    /// from the list instead, so there is one list.
    ///
    /// Two the script has and this does not, because they are answers rather
    /// than slips once an attempt is over: a device the system says is busy,
    /// and a mount point macOS refuses as an invalid file system. Inside the
    /// script both are worth one more go -- the first is usually a machine on
    /// its way out still holding the device, and the second a leftover mount
    /// the sweep has just taken away.
    public static let signaturesForTheScript =
        (signatures + ["device or resource busy", "invalid file system"])
        .joined(separator: "|")

    /// What a mount ended by the deadline leaves in the detail, so it is tried
    /// again rather than reported as a drive that would not open.
    public static let deadlineReached = "the attempt was ended after"

    /// How long one attempt may take before it is ended.
    ///
    /// Generous, because it is not a performance target: a large NTFS volume
    /// whose log needs replaying, or an LVM group of several volumes, takes
    /// minutes on any machine. What it is for is the attempt that will never
    /// end -- a virtual machine that did not come up, an NFS mount waiting on a
    /// server that has gone -- which otherwise leaves somebody watching a
    /// spinner for as long as they are willing to.
    public static let deadline: TimeInterval = 8 * 60

    /// Whether this is worth trying again.
    public static func isTransient(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return signatures.contains { lowered.contains($0) }
    }

    /// Whether what ended this attempt was the machinery slipping.
    ///
    /// Not simply "does the transcript contain one of these phrases". Every
    /// attempt has a virtual machine to take down afterwards, and the teardown
    /// says "connection reset" and "connection refused" on its way out --
    /// including the teardown that follows a wrong passphrase. Read that way, a
    /// real answer becomes three attempts, each with a deadline of minutes,
    /// before somebody is told the one thing they needed to know at the start.
    ///
    /// So the transcript is asked what it was *about* first. A rule that
    /// recognised it and settles the question -- the passphrase, the
    /// filesystem, a volume Windows left hibernated -- is an answer, and no
    /// number of attempts will change it. Only where nothing settled it does
    /// the machinery come into question.
    public static func endedInASlip(summary: String, detail: String?) -> Bool {
        // This app's own deadline, wherever it appears: always worth another go.
        let text = [summary, detail ?? ""].joined(separator: "\n")
        if text.lowercased().contains(deadlineReached) { return true }
        if let rule = Diagnosis.rule(for: text), rule.settles { return false }
        return isTransient(text)
    }

    /// How many times an attempt is made in all, the first one included.
    public static let attempts = 3

    /// How long to leave the machinery alone before trying again. Long enough
    /// for a virtual machine that is shutting down to finish doing so, which is
    /// what most of these are.
    public static let pause: TimeInterval = 1.5
}
