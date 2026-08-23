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
                                        "\(Brand.name) opens BitLocker, Linux and virtual machine drives and disk images that macOS cannot open on its own.\n\nReading a drive at the raw device level needs Full Disk Access. macOS has no way for an app to request this directly, so it has to be switched on by hand."
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
                                "Click + at the bottom of the list, select \(Brand.name) in Applications, and switch it on.",
                            note: "If it is already in the list, switch it on instead.",
                            // The wording covers both cases; the picture shows
                            // the likelier one. A permission that has gone
                            // usually leaves the entry behind, so that reader
                            // is looking for a switch rather than for +.
                            picture: model.restoreBlocked
                                ? Brand.switchPicture : "FullDiskAccessAdd",
                            pictureDescription: model.restoreBlocked
                                ? appString("The Full Disk Access list, with an app's switch marked.")
                                : appString("The Full Disk Access list, with the + button marked.")
                        )
                        Step(
                            number: 3,
                            text: "Come back to this window and click Relaunch.",
                            note: "Granted permission will only apply once the app is restarted."
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
            // Three buttons fill this row in English and can overflow it in
            // German, where the last one truncated to "Datenschutzeinstellu…".
            // Given a width they do not fit in, they take two rows instead of
            // losing their labels.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    quit
                    Spacer(minLength: 20)
                    relaunch
                    openSettings
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        quit
                        Spacer(minLength: 12)
                        relaunch
                    }
                    HStack {
                        Spacer(); openSettings
                    }
                }
            }
        }
    }

    private var quit: some View {
        Button("Quit App") { NSApp.terminate(nil) }
    }
    private var relaunch: some View {
        Button("Relaunch") { model.relaunch() }
    }
    private var openSettings: some View {
        // The one thing to do here, so it carries the tint and takes Return.
        Button("Open System Settings") { model.openPrivacySettings() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }
}

struct Step: View {
    let number: Int
    let text: LocalizedStringKey
    /// The part that is worth saying but is not an instruction, set apart so
    /// the instruction can be read on its own.
    var note: LocalizedStringKey? = nil
    /// A picture of the pane the step is talking about. English only: the
    /// settings it shows are in the reader's own language, and twenty-two sets
    /// of screenshots is not a thing one person can keep true.
    var picture: String? = nil
    var pictureDescription: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.orange))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let picture {
                    // The corners and the hairline are drawn into the
                    // picture, which is the only way they stay aligned once
                    // SwiftUI has scaled it to the width it has.
                    Image(picture)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 150, alignment: .leading)
                        .accessibilityLabel(pictureDescription.map(Text.init) ?? Text(text))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
