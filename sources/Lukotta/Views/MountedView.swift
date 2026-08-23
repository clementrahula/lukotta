// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

// MARK: - Mounted

struct MountedView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    let mountPoint: String

    /// Falls back to the single point when nothing has been collected yet.
    private var volumes: [String] {
        model.openVolumes.isEmpty ? [mountPoint] : model.openVolumes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "“\(drive.name)” is unlocked"
                    ).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    // A drive can be read-only because that was asked for, or
                    // because it refused to be written to and the mount fell
                    // back. Either way the screen must not promise writing.
                    Text(
                        model.mountedReadOnly
                            ? "You can read files on it. It was opened read-only, so nothing can be written to it."
                            : "You can read and write files on it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Why it is read-only, where that was not what was asked
                    // for. A drive that will not accept writes and says nothing
                    // about it leaves the person with nothing to act on, and
                    // the commonest cause is one Windows setting.
                    if let reason = model.readOnlyReason {
                        Text(reason)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }

            // A container can hold several volumes, and all of them are
            // opened, so one "Location" line would describe part of the truth.
            VStack(alignment: .leading, spacing: 6) {
                Text(volumes.count > 1 ? "Volumes opened" : "Location")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(volumes, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.callout.weight(.medium))
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    // Combining leaves the role unspecified, and an element of
                    // no particular kind is not something VoiceOver can describe
                    // beyond reading it. It is a line of text; say so.
                    .accessibilityAddTraits(.isStaticText)
                }
            }

            InfoBox(
                text:
                    "The drive appears in the Finder sidebar under Locations.\nEject it here or in Finder before unplugging it."
            )

            if let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem = model.ejectProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Button("All Drives") { model.showAllDrives() }
                Button("Show in Finder") { model.revealInFinder(mountPoint) }
                Spacer()
                if model.isEjecting {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Ejecting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Eject") { model.eject(mountPoint) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(model.isEjecting)
        }
    }
}
