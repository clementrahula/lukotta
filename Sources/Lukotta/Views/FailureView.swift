import AppKit
import LukottaCore
import SwiftUI

// MARK: - Failure

struct FailureView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive?
    let summary: String
    let detail: String?
    @State private var showDetail = false

    var body: some View {
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

            InfoBox(
                icon: "shield.checkered",
                text: "Your drive was not modified. A failed unlock cannot damage the data on it.")

            if let detail, !detail.isEmpty {
                DisclosureGroup("What the engine reported", isExpanded: $showDetail) {
                    LogView(lines: detail.components(separatedBy: .newlines).filter { !$0.isEmpty })
                }
                .font(.caption)
            }

            Spacer()
            HStack {
                Button("Choose another drive", action: model.backToDrives)
                Spacer()
                if summary.contains("Full Disk Access") {
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                        .keyboardShortcut(.defaultAction)
                } else if let drive {
                    Button("Try again") { model.choose(drive) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
