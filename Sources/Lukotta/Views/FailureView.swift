import AppKit
import LukottaCore
import SwiftUI

// MARK: - Failure

struct FailureView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive?
    let summary: String
    let detail: String?
    // Open from the start. A failure is exactly when the log is worth reading,
    // and hiding it behind a second click asks the user to guess that it exists.
    @State private var showDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The drive was not opened").font(.title3.weight(.semibold))
                            Text(summary).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let stopped = model.failedStage {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(MountStage.allCases, id: \.rawValue) { s in
                                StageRow(stage: s, current: stopped, stopped: true)
                            }
                        }
                        .padding(.leading, 2)
                    }

                    InfoBox(
                        text:
                            "Your drive was not modified. A failed unlock cannot damage the data on it."
                    )

                    if let detail, !detail.isEmpty {
                        DisclosureGroup("Details", isExpanded: $showDetail) {
                            LogView(
                                lines: detail.components(separatedBy: .newlines).filter {
                                    !$0.isEmpty
                                })
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            HStack {
                // Back is where the user came from — the credential for this
                // drive — not the list of every drive.
                if let drive {
                    Button("Back") { model.choose(drive) }
                } else {
                    Button("Back", action: model.backToDrives)
                }
                Button("Report This Issue") { model.showReport = true }
                Spacer()
                if summary.contains("Full Disk Access") {
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                        .keyboardShortcut(.defaultAction)
                } else if let drive {
                    // Retries as it stands. Back is the way to change anything.
                    Button("Try Again") { model.unlock(drive) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
