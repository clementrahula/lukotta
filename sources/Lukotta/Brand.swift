// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import LukottaCore

/// What this build calls itself.
///
/// Read from the bundle rather than written into the interface, because the
/// name is a trademark and an unbranded build carries a different one. Any
/// string the user reads should interpolate this instead of spelling out
/// Lukotta. See TRADEMARKS.txt.
enum Brand {
    static var name: String { appName }

    /// The picture of an app's row in Full Disk Access, which is the one
    /// picture in the app with a name in it. The branded build shows
    /// Lukotta.app because that is what its reader is looking for; an
    /// unbranded build shows the same row with the name blurred, rather than
    /// naming a build nobody has.
    static var switchPicture: String {
        Bundle.main.object(forInfoDictionaryKey: "LUKSwitchPictureAssetName") as? String
            ?? "FullDiskAccessSwitchUnbranded"
    }
}
