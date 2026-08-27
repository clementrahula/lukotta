// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Whether an open mount has stopped answering, so the app can say so.
///
/// The fault this exists for: a copy to a drive froze at 23:22 and the window
/// looked exactly the same at 23:37. Finder's progress bar stops moving and
/// nothing else changes -- no error, no dialog, no way to tell a wedged copy
/// from a slow one. The person watching finds out by giving up.
///
/// The mount stays in the table the whole time, so "is it mounted" answers yes.
/// What actually happens is that requests stop being answered: a `stat` of the
/// mount point, which normally returns in under a millisecond, does not return
/// at all. That is the signal, and it is the one Finder is already stuck on.
///
/// Deliberately not clever. A single slow answer means nothing -- a drive that
/// has to spin up, a guest that is busy -- so one is never enough. Several in a
/// row, spread over long enough that a passing hiccup cannot produce them, is a
/// mount that has stopped.
public struct StallWatch: Sendable {

    /// How long one probe is given before it counts as unanswered.
    ///
    /// Longer than any healthy answer by a wide margin: a loopback NFS stat is
    /// sub-millisecond, and even a drive waking from standby answers well
    /// inside this. Short enough that a stall is noticed while somebody is
    /// still looking at the screen.
    public static let probeDeadline: TimeInterval = 5

    /// How many unanswered probes in a row make a stall.
    ///
    /// Three, at the interval below, is a little over a minute of a mount
    /// saying nothing. Below that the observed hiccups -- the engine briefly
    /// busy at the start of a large write -- would raise it, and a notice that
    /// cries wolf is one people learn to ignore.
    public static let strikes = 3

    /// How often to ask.
    public static let interval: TimeInterval = 20

    private var missed = 0
    private var announced = false

    public init() {}

    /// What one probe changes.
    public enum Verdict: Equatable, Sendable {
        /// Nothing to say.
        case quiet
        /// Say it has stopped, once.
        case stalled
        /// Say it is back, having said it stopped.
        case recovered
    }

    /// Record one probe and decide whether anything should be said.
    ///
    /// Said once per episode in each direction: a stall that lasts an hour is
    /// one sentence, not a sentence every twenty seconds, and a mount that
    /// recovers says so only if it had complained.
    public mutating func record(answered: Bool) -> Verdict {
        if answered {
            missed = 0
            guard announced else { return .quiet }
            announced = false
            return .recovered
        }
        missed += 1
        guard missed >= Self.strikes, !announced else { return .quiet }
        announced = true
        return .stalled
    }

    /// Whether this watch is currently reporting a stall.
    public var isStalled: Bool { announced }

    /// How long a stall has been going, for a sentence that says so.
    public var missedProbes: Int { missed }
}
