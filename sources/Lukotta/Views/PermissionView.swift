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
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 28)).foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Welcome to \(Brand.name)").font(.title3.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text(
                                "\(Brand.name) opens BitLocker and Linux drives that macOS cannot read on its own. One setting is needed first.\n\nReading a drive at the raw device level needs Full Disk Access. An administrator password is not enough, and the removable-volumes permission covers files on a drive rather than the raw device. macOS has no way for an app to request this one, so it has to be switched on by hand."
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Step(number: 1, text: "Open Privacy & Security → Full Disk Access.")
                        Step(number: 2, text: "Click + and add \(Brand.name), then switch it on.")
                        Step(
                            number: 3,
                            text:
                                "Come back here and choose Relaunch. A new permission applies only to an app started after it was granted."
                        )
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("What to do")

                    InfoBox(
                        icon: "hand.raised",
                        text:
                            "This is a macOS privacy setting, not a change to your Mac. You can switch it off again at any time, and nothing is installed."
                    )
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
        Button("Reveal App") { model.revealApp() }
    }
    private var relaunch: some View {
        Button("Relaunch") { model.relaunch() }
    }
    private var checkAgain: some View {
        Button("Check Again") { model.recheckPermission() }
    }
    private var openSettings: some View {
        Button("Open Privacy Settings") { model.openPrivacySettings() }
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
                .background(Circle().fill(.tint))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
