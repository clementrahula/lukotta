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
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        volumes.count > 1
                            ? "“\(drive.name)” is open" : "“\(drive.name)” is unlocked"
                    ).font(.title3.weight(.semibold))
                    Text("You can open, change, and save files on it.")
                        .font(.caption).foregroundStyle(.secondary)
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
