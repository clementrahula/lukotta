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
    static let signatures = [
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

    /// How many times an attempt is made in all, the first one included.
    public static let attempts = 3

    /// How long to leave the machinery alone before trying again. Long enough
    /// for a virtual machine that is shutting down to finish doing so, which is
    /// what most of these are.
    public static let pause: TimeInterval = 1.5
}
