import AppKit
import LukottaCore
import SwiftUI

// MARK: - Mounted

struct MountedView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    let mountPoint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(drive.name)” is unlocked").font(.title3.weight(.semibold))
                    Text("You can open, change, and save files on it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledContent("Location") {
                Text(mountPoint).font(.system(.caption, design: .monospaced)).textSelection(
                    .enabled)
            }

            InfoBox(
                icon: "sidebar.left",
                text:
                    "The drive appears in the Finder sidebar under Locations. Eject it here or in Finder before unplugging it."
            )

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
