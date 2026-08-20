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

    var body: some View {
        HStack(spacing: 14) {
            Image(
                systemName: isMounted
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive.fill.badge.lock"
            )
            .font(.system(size: 26))
            .foregroundStyle(isMounted ? Color.green : Color.accentColor)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(drive.name).font(.body.weight(.medium))
                    TypePill(text: drive.kind.summary, open: isMounted)
                }
                // Size leads; the device identifier is the least useful fact
                // and no longer competes with it.
                Text(
                    isMounted
                        ? "Open at \(mountPoint ?? "")"
                        : "\(drive.sizeDescription)  ·  \(drive.connection)"
                )
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
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
        .accessibilityLabel("\(drive.name), \(drive.sizeDescription), \(drive.kind.summary)")
        .accessibilityHint(isMounted ? "Already open" : "Unlock this drive")
        .accessibilityAddTraits(.isButton)
    }
}

/// Small label for what a partition might contain.
struct TypePill: View {
    let text: String
    let open: Bool

    var body: some View {
        Text(open ? "Open" : text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((open ? Color.green : Color.secondary).opacity(0.15)))
            .foregroundStyle(open ? Color.green : Color.secondary)
    }
}
