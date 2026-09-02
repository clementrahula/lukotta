// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Whether the early-development notice is due, and when it stops being due.
///
/// It lives here rather than in the view so that it can be tested. Written as
/// a property of the model it was not: the test target links LukottaCore and
/// not the application, so the first version shipped with no test at all and
/// was wrong in a way anybody launching the app twice would have seen.
///
/// What was wrong is worth keeping written down. The sheet was shown while the
/// drive list was on screen, and taken away again when it was not. Opening a
/// drive moves off the list, so the sheet vanished with nothing acknowledged,
/// and it came back at every launch after. Being due is therefore latched:
/// reaching the list arms it, and only the button disarms it.
public struct EarlyNotice: Sendable {

    /// Keyed on the bundle identifier, so the release, the pre-release and a
    /// local build each say it once rather than one answering for the others.
    public static func key(for bundleIdentifier: String?) -> String {
        "com.lukotta.earlyDevelopmentAcknowledged." + (bundleIdentifier ?? "unknown")
    }

    /// Whether the button has ever been pressed for this build.
    public private(set) var acknowledged: Bool

    /// Whether the drive list has been reached since launch.
    public private(set) var armed = false

    public init(acknowledged: Bool) {
        self.acknowledged = acknowledged
    }

    /// The drive list appeared. Arms the notice, and never disarms it.
    public mutating func sawTheDriveList() {
        armed = true
    }

    /// The button was pressed.
    public mutating func acknowledge() {
        acknowledged = true
    }

    /// Whether the sheet should be on screen.
    public var isDue: Bool { !acknowledged && armed }
}
