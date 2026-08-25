// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Failures that mean "the machinery slipped", not "this cannot be opened".
///
/// The engine starts a virtual machine, hands it a disk, and talks to it over a
/// socket and a pipe. Any of that can fail for a moment on a Mac that is busy:
/// the machine's own end of the pipe goes before it has read what was written
/// to it, a socket is reset while it is being set up, the hypervisor refuses a
/// machine because the last one has not finished going away.
///
/// None of those say anything about the drive. Told to a person they are worse
/// than useless -- "Failed to write to pipe: Broken pipe (os error 32)" about a
/// disk that opens perfectly well a second later -- so the attempt is made
/// again instead, and only what survives being tried three times is shown.
///
/// Deliberately narrow. A wrong password, a filesystem nobody can read, a
/// hibernated Windows volume: those are answers, and trying again would waste a
/// minute of somebody's time to arrive at the same place.
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
    ]

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
