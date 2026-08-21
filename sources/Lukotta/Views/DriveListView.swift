import AppKit
import LukottaCore
import SwiftUI

// MARK: - Drive selection

struct DriveListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.drives.isEmpty {
            EmptyStateView(
                icon: "externaldrive.badge.questionmark",
                title: "No encrypted drives found",
                message:
                    "Connect the encrypted drive and choose Rescan. If it is already connected, macOS may have it mounted — eject it in Finder first.",
                actionTitle: "Rescan",
                action: model.rescan)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if let notice = model.notice {
                    Label(notice, systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                Text("Select a drive to unlock")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.drives) { drive in
                            DriveRow(
                                drive: drive,
                                mountPoint: model.mountPoint(for: drive),
                                action: { model.choose(drive) },
                                eject: { model.eject(model.mountPoint(for: drive) ?? "") })
                        }
                    }
                }
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
    let action: () -> Void
    let eject: () -> Void

    private var isMounted: Bool { mountPoint != nil }

    /// The same facts whether unlocked or not. A drive that is unlocked does not stop
    /// being a 500 GB USB disk, and losing that when it opens made the two rows
    /// look like different kinds of thing.
    private var details: String {
        var parts = [drive.sizeDescription]
        if !drive.connection.isEmpty { parts.append(drive.connection) }
        parts.append(drive.kind.summary)
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 14) {
            // One fixed-width column, so the text starts in the same place on
            // every row. There is no "…badge.lock" symbol — asking for one drew
            // nothing at all, which is what left the closed rows without an
            // icon and their text out of line with the open ones.
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
                }
                Text(details)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let mountPoint {
                    Text("Unlocked at \(mountPoint)")
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if isMounted {
                Button("Eject", action: eject).controlSize(.small)
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { if !isMounted { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(drive.name), \(isMounted ? "unlocked" : "locked"), \(details)")
        .accessibilityHint(isMounted ? "Already unlocked" : "Unlock this drive")
        .accessibilityAddTraits(.isButton)
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
