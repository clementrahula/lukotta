import AppKit
import LukottaCore
import SwiftUI

/// Reporting a problem, including crash logs macOS has already written.
///
/// The system's own crash dialog offers to send to Apple, which a Developer ID
/// developer never receives. This shows exactly what would be sent, puts it on
/// the clipboard, and opens a message — nothing is transmitted on its own.
struct ReportIssueSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var problem = ""
    @State private var copied = false

    private let environment = Diagnostics.environment()
    private let crashes = Diagnostics.crashReports()

    private var reportText: String {
        Diagnostics.report(
            environment: environment,
            problem: problem,
            engineOutput: model.statusLines.joined(separator: "\n"),
            crashReport: crashes.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Report an Issue").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("What happened?").font(.subheadline.weight(.semibold))
                        TextEditor(text: $problem)
                            .font(.callout)
                            .frame(height: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.15)))
                    }

                    if let crash = crashes.first {
                        VStack(alignment: .leading, spacing: 7) {
                            Label(
                                "A crash report was found", systemImage: "doc.text.magnifyingglass"
                            )
                            .font(.subheadline.weight(.semibold))
                            Text(
                                "macOS wrote \(crash.lastPathComponent). It is not sent anywhere "
                                    + "automatically — attach it to your message if you can."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([crash])
                            }
                            .controlSize(.small)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Details that will be included").font(.subheadline.weight(.semibold))
                        ScrollView {
                            Text(reportText)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                        }
                        .frame(height: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Button(copied ? "Copied" : "Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Open Email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    copied = true
                    if let url = Diagnostics.mailtoURL(
                        address: "lukotta@rahula.dev", environment: environment)
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600, height: 620)
    }
}
