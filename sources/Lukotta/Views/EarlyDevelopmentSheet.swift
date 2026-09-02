// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import LukottaCore
import SwiftUI

/// Said once, before the first drive is opened.
///
/// Not a prompt in the copy path and not a warning attached to an action: the
/// rule that opening a drive costs no extra click is untouched. Somebody
/// agreeing to try something still in development is entitled to know that is
/// what they are doing, and to be told once rather than every time.
///
/// The flag is written when the button is pressed rather than when the sheet
/// appears, so a launch that is killed or crashes while this is up shows it
/// again.
struct EarlyDevelopmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Early Development")
                .font(.title2.weight(.semibold))

            // The name is interpolated rather than written out: it is a
            // trademark and an unbranded build carries a different one.
            // See TRADEMARKS.txt.
            Text(
                "\(Brand.name) is still new. The Linux tools and drivers it relies on have been around for years and are well tested. \(Brand.name) is built on top of them, but it is still in development, so there are inevitably issues yet to be uncovered. For now, using it for opening drives and images in read-only mode is the safest thing to do. Writing does work, but please treat it as experimental, and keep a copy of anything you would be upset to lose."
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("OK") {
                    onAcknowledge()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        // There is one way out and it is the button, so the flag cannot be
        // skipped by pressing Escape or clicking away.
        .interactiveDismissDisabled()
    }
}
