// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import LukottaCore
import SwiftUI

/// Every disk attached to this Mac, and what can be done with each.
///
/// The drive list shows only what this app can open, which is correct until it
/// shows nothing: "no encrypted drives found" says nothing about the drive on
/// the desk. This view lists everything attached, with a reason beside each disk
/// that cannot be opened.
struct OpenDriveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSystem = false

    /// The disks somebody might act on: anything that is not part of the
    /// running system, whether or not this app can open it.
    private var theirs: [DriveSurvey.Entry] {
        model.survey.filter { $0.verdict != .system }
    }

    private var system: [DriveSurvey.Entry] {
        model.survey.filter { $0.verdict == .system }
    }

    private func open(_ entry: DriveSurvey.Entry) {
        guard let drive = entry.drive else { return }
        dismiss()
        model.choose(drive)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open Drive").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()

            if model.survey.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking every disk…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Nothing here but the system's own volumes, which is
                        // the same emptiness the drive list reports, and says
                        // the same thing rather than leaving a blank sheet
                        // under a collapsed row.
                        if theirs.isEmpty {
                            // No button of its own. This sheet keeps one at
                            // the bottom whether the list is empty or not, and
                            // two Rescans on one sheet is a choice where there
                            // is none.
                            EmptyStateView(
                                icon: "externaldrive.badge.questionmark",
                                title: "No drives found",
                                message:
                                    "Connect the drive and choose Rescan. If it is already connected, macOS may have it mounted, in which case eject it in Finder first. To open a disk image instead, choose File → Open Disk Image."
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                        }
                        ForEach(theirs) { entry in
                            SurveyRow(entry: entry) { open(entry) }
                        }
                        // The system's own volumes are last and folded away.
                        // There are a dozen of them on any Mac -- APFS makes
                        // Preboot, Recovery, VM and the rest inside every
                        // container -- and none is a thing to open. Shown
                        // above the drive somebody plugged in, they bury it.
                        if !system.isEmpty {
                            DisclosureGroup(isExpanded: $showSystem) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(system) { entry in
                                        SurveyRow(entry: entry) { open(entry) }
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text("macOS System Volumes")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, theirs.isEmpty ? 0 : 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                }
            }

            Divider()
            HStack {
                Text("Every drive attached to this Mac, whether or not \(Brand.name) can open it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                RescanButton(title: "Rescan", busy: model.isSurveying) { model.surveyDrivesAsked() }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 580, height: 560)
        // The watcher reports a drive being plugged in or taken out. A
        // container file being attached or detached is not something it sees,
        // so the sheet also looks again every couple of seconds while it is up.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                model.surveyDrives()
            }
        }
        .task { model.surveyDrives() }
    }
}

private struct SurveyRow: View {
    @EnvironmentObject var model: AppModel
    let entry: DriveSurvey.Entry
    let open: () -> Void

    private var openable: Bool {
        if case .openable = entry.verdict { return true }
        return false
    }

    /// Where this app has it open, when it does.
    private var openHere: (point: String, readOnly: Bool)? {
        if case .openHere(let point, let readOnly) = entry.verdict {
            return (point, readOnly)
        }
        return nil
    }

    /// Why this one cannot be opened, in ordinary terms rather than the
    /// partition table's.
    private var reason: String {
        switch entry.verdict {
        case .openable:
            // The counterpart of the lines below, and said the same way. What
            // it may hold is in the subtitle already; this line is for what
            // can be done about it.
            return String(localized: "A drive \(Brand.name) can open.")
        case .openHere(let point, _):
            // The same sentence the drive list uses for the same fact, rather
            // than a second one saying it differently in thirty-six languages.
            return String(localized: "Unlocked at \(point)")
        case .macOSHasIt(let point):
            return String(localized: "macOS has this open at \(point).")
        case .macOSReadsIt:
            return String(localized: "macOS reads this format itself.")
        case .system:
            return String(localized: "A macOS system volume.")
        case .unreadable:
            return String(localized: "Not a format \(Brand.name) can open.")
        }
    }

    private var tint: Color {
        switch entry.verdict {
        case .openable: return .orange
        case .openHere: return .green
        case .macOSHasIt, .macOSReadsIt: return .green
        case .system, .unreadable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(
                systemName: openable
                    ? "lock.fill" : (openHere != nil ? "lock.open.fill" : "externaldrive")
            )
            .font(.system(size: 19))
            .foregroundStyle(tint)
            .frame(width: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(entry.name).font(.callout.weight(.medium))
                    // The same two pills the drive list uses, so a drive says
                    // the same thing about itself wherever it is shown.
                    if let openHere {
                        StatePill(open: true)
                        if openHere.readOnly { ReadOnlyPill() }
                    }
                    Text(verbatim: entry.id)
                        .font(.system(.caption2, design: .monospaced))
                        .environment(\.layoutDirection, .leftToRight)
                        .foregroundStyle(.tertiary)
                }
                Text(
                    verbatim: entry.content.isEmpty
                        ? entry.sizeDescription : "\(entry.sizeDescription) · \(entry.content)"
                )
                .font(.caption).foregroundStyle(.secondary)
                .environment(\.layoutDirection, .leftToRight)
                Text(reason)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if openable {
                Button("Open", action: open).controlSize(.small)
                    .accessibilityLabel("Open \(entry.name)")
                    .disabled(!model.canOpenAnother)
            } else if let openHere {
                // The same treatment as the drive list: ejecting takes seconds,
                // and a button that looks untouched for that long reads as
                // broken and gets pressed again.
                if model.ejectingPath == openHere.point {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                            .accessibilityHidden(true)
                        Text("Ejecting…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Ejecting \(entry.name)")
                } else {
                    Button("Eject") { model.eject(openHere.point) }
                        .controlSize(.small)
                        .accessibilityLabel("Eject \(entry.name)")
                        .disabled(model.isEjecting)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}
