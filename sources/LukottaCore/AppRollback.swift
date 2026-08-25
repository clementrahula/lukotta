// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Putting the previous version back. The decisions only — no filesystem here.
///
/// Sparkle keeps a machine on a launchable app right up to the swap: nothing
/// damaged is installed, and an interruption before the swap leaves the old
/// bundle byte-identical. The case it cannot cover is the swap succeeding and
/// the version it installed being the thing that does not work. By then the old
/// bundle is gone.
///
/// So the outgoing bundle is kept aside as the update installs, and these
/// decide what happens on the launches that follow.
public struct LaunchRecord: Equatable, Sendable {
    /// The version those attempts were of. A different version starts again.
    public let version: String
    /// Launches of that version that began without reaching a working app.
    public let attempts: Int
    public let firstAttemptAt: Date

    public init(version: String, attempts: Int, firstAttemptAt: Date) {
        self.version = version
        self.attempts = attempts
        self.firstAttemptAt = firstAttemptAt
    }
}

public enum LaunchAction: Equatable, Sendable {
    /// Start normally, writing this record first — or clearing what is there.
    case proceed(LaunchRecord?)
    /// Do not start. Put the kept-aside version back and open that instead.
    case rollBack(attempts: Int)
}

public enum AppRollback {

    /// The directory the app and the shim in front of it both keep this in.
    ///
    /// They have to agree, and they did not. The shim reads the identifier out
    /// of the Info.plist beside it; the app used the name of the bundle on
    /// disk. So the app kept the outgoing version under "Lukotta Beta" and the
    /// shim looked for it under "com.lukotta.beta", found nothing, and started
    /// a broken version for the fourth time and the fortieth. The one thing an
    /// update cannot undo was the one thing not wired up.
    ///
    /// The identifier is what everything else this app keeps is filed under,
    /// and it survives somebody renaming the application. The name is the
    /// fallback on both sides, for a bundle whose Info.plist cannot be read --
    /// `bundle_identifier()` in sources/LukottaLaunch/main.c does the same.
    public static func supportName(identifier: String?, bundleName: String) -> String {
        guard let identifier, !identifier.isEmpty else { return bundleName }
        return identifier
    }

    /// Why three, rather than one or five.
    ///
    /// One would be wrong: a launch that begins and never finishes is not proof
    /// of a bad version. A power cut, a force quit during a slow start, and a
    /// closed laptop all leave the same trace, and undoing a good update on
    /// that evidence trades a working version for an older one on noise.
    ///
    /// Five would be wrong the other way. By the third identical failure nobody
    /// is still wondering whether it was a fluke; they are wondering whether
    /// the app is gone.
    ///
    /// Three makes the pattern unambiguous at a cost of two failed starts,
    /// which is about as many times as anyone tries before giving up.
    public static let attemptLimit = 3

    /// Whether this launch may proceed, given what the previous ones did.
    ///
    /// `keptAside` is the version of the bundle sitting in the keep-aside
    /// place, or nil when there is not one — which is what every ordinary
    /// launch looks like.
    public static func decide(
        record: LaunchRecord?,
        currentVersion: String,
        keptAside: String?,
        now: Date,
        limit: Int = attemptLimit
    ) -> LaunchAction {
        // Nothing to go back to, so the count means nothing and is not read.
        // This is what makes a rollback impossible on an ordinary launch —
        // structurally, rather than by being careful elsewhere.
        guard let keptAside else { return .proceed(nil) }
        // The kept-aside copy is what is running: either the install never
        // happened, or a rollback already put this version back.
        guard keptAside != currentVersion else { return .proceed(nil) }

        let previous = record?.version == currentVersion ? record : nil
        let attempts = (previous?.attempts ?? 0) + 1
        if attempts >= limit { return .rollBack(attempts: attempts) }
        return .proceed(
            LaunchRecord(
                version: currentVersion,
                attempts: attempts,
                firstAttemptAt: previous?.firstAttemptAt ?? now))
    }
}
