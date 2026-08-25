// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

// MARK: - Drive selection

struct DriveListView: View {
    @EnvironmentObject var model: AppModel

    /// The row a dragged row is currently over, so it can show where it would
    /// land. Nothing else depends on it.
    @State private var dropping: String?

    var body: some View {
        list
    }

    @ViewBuilder private var list: some View {
        if model.drives.isEmpty {
            EmptyStateView(
                icon: "externaldrive.badge.questionmark",
                title: "No drives found",
                message:
                    "Connect the drive and choose Rescan. If it is already connected, macOS may have it mounted, in which case eject it in Finder first. To open a disk image instead, choose File → Open Disk Image.",
                actionTitle: "Rescan",
                action: model.rescan)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Nothing more can be opened, and every way of trying is shut
                // rather than left to fail at the end of a minute's work.
                if !model.canOpenAnother {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(
                            "\(model.capacity.openCount) drives or images are open. You can only have \(model.capacity.limitCount) open at the same time. Eject one to open another."
                        )
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35))
                    )
                    .accessibilityElement(children: .combine)
                }
                if let notice = model.notice {
                    NoticeLine(text: notice) { model.notice = nil }
                        .padding(.bottom, 2)
                }
                // A drive that has just gone leaves its message where it was,
                // in the space it was taking.
                ForEach(model.departed.filter { $0.index == 0 }) { gone in
                    DepartedRow(name: gone.name)
                }
                // Rows are dragged into whatever order somebody wants them in.
                //
                // Asked for on the row rather than left to a List, which
                // reorders its own rows and never started here: a row is a
                // button, and the button takes the press before the list sees a
                // drag. A row carries its device identifier while it is being
                // dragged, and dropping it on another row is what moves it.
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(model.drives.enumerated()), id: \.element.id) {
                            position, drive in
                            let point = model.mountPoint(for: drive)
                            DriveRow(
                                drive: drive,
                                mountPoint: point,
                                knownFormat: model.knownFormats[drive.id],
                                knownFilesystem: model.knownFilesystems[drive.id],
                                container: model.container(of: drive),
                                space: point.flatMap { model.space[$0] },
                                volumeCount: point.flatMap { model.volumeCount[$0] } ?? 1,
                                readOnly: point.map { model.readOnlyMounts.contains($0) } ?? false,
                                action: { model.choose(drive) },
                                eject: { model.eject(point ?? "") },
                                ejecting: point != nil && model.ejectingPath == point,
                                // One at a time. A second teardown while the
                                // first is running is how a drive ends up half
                                // ejected.
                                otherEjectInFlight: model.isEjecting,
                                dropping: dropping == drive.id,
                                // A locked row does nothing while there is
                                // nowhere to serve another drive from.
                                unopenable: !model.canOpenAnother
                            )
                            .draggable(drive.id) {
                                // What is carried under the pointer: the row's
                                // name, rather than the whole row redrawn.
                                Label(drive.name, systemImage: "externaldrive.fill")
                                    .padding(6)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                dropping = nil
                                guard let dragged = items.first else { return false }
                                model.move(dragged, onto: drive)
                                return true
                            } isTargeted: { over in
                                if over {
                                    dropping = drive.id
                                } else if dropping == drive.id {
                                    dropping = nil
                                }
                            }
                            ForEach(model.departed.filter { $0.index == position + 1 }) { gone in
                                DepartedRow(name: gone.name)
                            }
                        }
                    }
                    // Once the rows have moved, nothing is being dragged over
                    // anything: the row that was marked has changed places, and
                    // the mark would sit on whatever took its position.
                    .onChange(of: model.drives.map(\.id)) { dropping = nil }
                }
                // The line under the header, mirrored. Without it the list runs
                // straight into the footer and the two read as one block. The
                // negative inset takes it out to the window's edges, where the
                // header's line is: everything on this screen is inside a
                // 24-point margin, and a line stopping short of the edge looks
                // like a mistake rather than a division.
                Divider().opacity(0.5).padding(.horizontal, -24)
                HStack {
                    Text("What a drive contains is only known once it is unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Rescan", action: model.rescan)
                }
            }
        }
    }
}

struct DriveRow: View {
    let drive: Drive
    let mountPoint: String?
    /// What a probe made of it, where one has been made. Nil until then.
    var knownFormat: VolumeFormat?
    /// What it turned out to hold, where it has been opened.
    var knownFilesystem: String?
    /// Which container the file is, where the row is a file. The row names it
    /// rather than saying "Disk Image" over every one of them.
    var container: ContainerFormat?
    /// Only known once the drive is open, and only then worth showing.
    var space: VolumeSpace?
    var volumeCount: Int = 1
    /// Opened read-only, whether that was asked for or fallen back to.
    var readOnly = false
    let action: () -> Void
    let eject: () -> Void
    /// This drive is the one being ejected.
    var ejecting = false
    /// Some drive is, which is enough to stop this one being started.
    var otherEjectInFlight = false
    /// A row being dragged is over this one, and would land here.
    var dropping = false
    /// Nothing more can be opened, so this row cannot be either.
    var unopenable = false

    private var isMounted: Bool { mountPoint != nil }

    /// The parts only an open drive has, said after the rest.
    private var spoken: String {
        var parts: [String] = []
        if volumeCount > 1 { parts.append(String(localized: "\(volumeCount) volumes")) }
        if let space { parts.append(space.summary) }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    /// Said inside a longer label, so each has to be a string that is already
    /// translated: what is interpolated into a key is inserted as it stands.
    private var openWord: String { String(localized: "unlocked") }
    private var shutWord: String { String(localized: "locked") }

    /// The same facts whether unlocked or not. A drive that is unlocked does
    /// not stop being a 500 GB USB disk.
    private var details: String {
        var parts = [drive.sizeDescription]
        // Which container it is, where that is worth saying. A raw image is a
        // disk image in macOS's own words, and the scan already calls it one;
        // the rest are formats macOS knows nothing about, so the row names
        // them: VDI, VHD, VHDX, VMDK, qcow2.
        let placeOrFormat = container.flatMap { $0 == .raw ? nil : $0.name } ?? drive.connection
        if !placeOrFormat.isEmpty { parts.append(placeOrFormat) }
        // A disk with no partition table says nothing about itself, so until
        // something has read it the row says nothing either rather than
        // printing a guess over it.
        if knownFormat != nil || drive.kindIsKnown {
            parts.append(drive.kind.summary(knowing: knownFormat, holding: knownFilesystem))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        // A locked row opens the drive when it is clicked, and it is also the
        // thing being dragged when the list is being rearranged. Written as a
        // Button, those two fight and the drag wins: the row could be dragged
        // and no longer opened.
        //
        // A tap gesture and a drag do not fight -- one needs the pointer to
        // stay still and the other needs it to move. What a Button gave for
        // free is then given here by hand: the keyboard, the button trait, and
        // the action a screen reader performs.
        if isMounted {
            row
        } else {
            row
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .focusable()
                .onKeyPress(.return) {
                    action(); return .handled
                }
                .onKeyPress(.space) {
                    action(); return .handled
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(drive.name), \(shutWord), \(details)")
                .accessibilityHint("Unlock this drive")
                .accessibilityAction(.default, action)
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            // One fixed-width column, so the text starts in the same place on
            // every row. There is no "…badge.lock" symbol to pair with the
            // checkmark one, so a locked drive gets the plain drive icon.
            Image(
                systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill"
            )
            .font(.system(size: 26))
            .foregroundStyle(isMounted ? Color.green : Color.orange)
            .frame(width: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(drive.name).font(.body.weight(.medium))
                    StatePill(open: isMounted)
                    // Only for a drive that is open: a read-only drive that is
                    // closed is a drive that has not been opened yet, and how
                    // it will be opened is not decided until it is.
                    if isMounted && readOnly { ReadOnlyPill() }
                }

                Text(details)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    // A size, a connection and a format name: Latin runs joined by
                    // separators that belong to neither direction.
                    .environment(\.layoutDirection, .leftToRight)
                if let mountPoint {
                    HStack(spacing: 6) {
                        Text("Unlocked at \(mountPoint)")
                            .lineLimit(1).truncationMode(.middle)
                        if volumeCount > 1 {
                            Text(verbatim: "·")
                            Text("\(volumeCount) volumes")
                        }
                        if let space {
                            Text(verbatim: "·")
                            Text(space.summary)
                        }
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            // Spelled out rather than combined from the children, so it reads
            // as a sentence — and the space has to be named here too, because
            // a label replaces what the children would have said.
            .accessibilityLabel(
                "\(drive.name), \(isMounted ? openWord : shutWord), \(details)\(spoken)")

            Spacer(minLength: 8)

            if isMounted {
                // Named, because moving between controls alone gives a row of
                // identical Ejects once several drives are open, and the drive
                // each one belongs to is in the text beside it rather than in
                // the button.
                // Ejecting takes seconds, and a button that looks untouched
                // for that long reads as broken — so it says what it is doing
                // and refuses to be pressed again while it does it.
                if ejecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                            .accessibilityHidden(true)
                        Text("Ejecting…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Ejecting \(drive.name)")
                } else {
                    Button("Eject", action: eject).controlSize(.small)
                        .accessibilityLabel("Eject \(drive.name)")
                        .disabled(otherEjectInFlight)
                }
            } else {
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    dropping ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: dropping ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// Whether the drive is unlocked, in the same place on every row.
struct StatePill: View {
    let open: Bool

    var body: some View {
        Text(open ? "Unlocked" : "Locked")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((open ? Color.green : Color.orange).opacity(0.15)))
            .foregroundStyle(open ? Color.green : Color.orange)
    }
}

/// Beside the state, for a drive opened read-only.
///
/// Its own pill rather than a third state of the one before it: a drive is
/// unlocked or it is not, and read-only says what may be done with it once it
/// is.
struct ReadOnlyPill: View {
    var body: some View {
        Text("Read-Only")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.blue.opacity(0.15)))
            .foregroundStyle(Color.blue)
    }
}

/// Stands in for a drive that has just gone, in the space it was taking.
///
/// Shaped like a drive row, and plainly not one: the point is that something
/// was there and is not, said where the eye already is rather than at the top
/// of the screen where it would push everything down and be missed.
struct DepartedRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("“\(isolated(name))” was disconnected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.primary.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
