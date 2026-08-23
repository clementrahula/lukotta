// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

// MARK: - Permission

struct PermissionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        // The same screen either way. What differs is whether
                        // this is the first time or the permission has gone
                        // since it was granted.
                        Image(
                            systemName: model.restoreBlocked
                                ? "exclamationmark.triangle.fill" : "hand.wave.fill"
                        )
                        .font(.system(size: 28))
                        // Orange, as a permission that has not been granted is
                        // elsewhere in the app. In the tint it read as
                        // reassurance, which is the opposite of the message.
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                model.restoreBlocked
                                    ? appString("\(Brand.name) could not open your drives")
                                    : appString("Welcome to \(Brand.name)")
                            )
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            Text(
                                model.restoreBlocked
                                    ? appString(
                                        "Your drives are set to open again after a restart, but Full Disk Access is no longer granted. A macOS update, a move or a reinstall can remove it."
                                    )
                                    : appString(
                                        "\(Brand.name) opens BitLocker and Linux drives that macOS cannot read on its own. One setting is needed first.\n\nReading a drive at the raw device level needs Full Disk Access. An administrator password is not enough, and the removable-volumes permission covers files on a drive rather than the raw device. macOS has no way for an app to request this one, so it has to be switched on by hand."
                                    )
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Step(number: 1, text: "Open Privacy & Security → Full Disk Access.")
                        Step(
                            number: 2,
                            text:
                                "Click + there, select \(Brand.name) in Applications, and switch it on."
                        )
                        Step(
                            number: 3,
                            text:
                                "Come back here and click Relaunch. A new permission applies only to an app started after it was granted."
                        )
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("What to do")

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            // Four buttons fill this row in English and overflow it in German,
            // where the last one truncated to "Datenschutzeinstellu…". Given a
            // width they do not fit in, they take two rows instead of losing
            // their labels.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    reveal
                    Spacer(minLength: 20)
                    relaunch
                    checkAgain
                    openSettings
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        reveal
                        Spacer(minLength: 12)
                        relaunch
                        checkAgain
                    }
                    HStack {
                        Spacer(); openSettings
                    }
                }
            }
        }
    }

    private var reveal: some View {
        Button("Quit App") { NSApp.terminate(nil) }
    }
    private var relaunch: some View {
        Button("Relaunch") { model.relaunch() }
    }
    private var checkAgain: some View {
        Button("Check Again") { model.recheckPermission() }
    }
    private var openSettings: some View {
        // The one thing to do here, so it carries the tint and takes Return.
        Button("Open System Settings") { model.openPrivacySettings() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .keyboardShortcut(.defaultAction)
    }
}

struct Step: View {
    let number: Int
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.orange))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
