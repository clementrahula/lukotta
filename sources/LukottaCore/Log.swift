// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import os

/// Where the app says what it did.
///
/// A bug report arrives hours after the thing it describes. Whatever the app
/// was holding in memory is gone by then; the unified log is not. It survives
/// the crash that ended the process, it survives the quit, and it can be read
/// back afterwards — by the app itself for a report, or with
/// `log show --predicate 'subsystem == "com.lukotta"'`.
///
/// Interpolating a string into a `Logger` message marks it private and the log
/// shows `<private>` in its place, which is the right default for a drive's
/// name or a path on someone's disk. Anything that has to be readable —
/// counts, versions, states, the names of our own stages — says so with
/// `privacy: .public`. Nothing here is ever given a passphrase.
public enum Log {
    /// Also what a report reads back, so the two cannot name different things.
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.lukotta"

    /// Starting, quitting, permissions, appearance, language.
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// Scanning, arriving, leaving.
    public static let drives = Logger(subsystem: subsystem, category: "drives")
    /// Unlocking, mounting, ejecting.
    public static let mount = Logger(subsystem: subsystem, category: "mount")
    /// The privileged helper and the connection to it.
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    /// Sleeping, waking, and what the mounts did about it.
    public static let sleep = Logger(subsystem: subsystem, category: "sleep")
    /// Update checks, installs, and putting a version back.
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}
