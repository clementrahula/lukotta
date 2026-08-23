// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import SwiftUI

/// The mark this build carries.
///
/// An image in an asset catalog: the artwork at 1x, 2x and 3x, with a light and
/// a dark version of each. macOS picks the one matching the screen and the
/// appearance, so nothing here scales or tints anything.
///
/// Which image is a build-time choice. An unbranded build carries a placeholder
/// instead, because the Lukotta mark is a trademark and is not covered by the
/// GPL. See TRADEMARKS.txt.
struct LukottaMark: View {
    private static let asset =
        Bundle.main.object(forInfoDictionaryKey: "LUKMarkAssetName") as? String ?? "LukottaMark"

    var body: some View {
        Image(Self.asset)
            .accessibilityHidden(true)
    }
}
