// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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
    /// Read once when the sheet opens, not on every keystroke: the report is
    /// recomputed as the description is typed, and this comes off disk.
    @State private var recentLog = ""
    /// The report without the typed description, redacted once when the sheet
    /// opens. Everything in it — the engine's output, the log, the crash
    /// report — is fixed for as long as the sheet is up, and redacting it is
    /// two regular expressions over several thousand characters.
    @State private var fixedPart = ""

    private let environment = Diagnostics.environment()
    private let crashes = Diagnostics.crashReports()

    private var crashWhen: String {
        guard let crash = crashes.first, let date = Diagnostics.date(of: crash) else {
            return "earlier"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// What the sheet shows and copies: the part that cannot change, with the
    /// typed description redacted on top of it.
    private var reportText: String {
        guard !problem.isEmpty else { return fixedPart }
        return Diagnostics.withProblem(Diagnostics.scrubbed(problem), in: fixedPart)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        copied = true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Report an Issue").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // Escape closes it. Without this the sheet can only be left by
                // finding one button with the mouse.
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("What happened?").font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        TextEditor(text: $problem)
                            .font(.callout)
                            .accessibilityLabel("What happened")
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
                                """
                                macOS wrote \(crash.lastPathComponent). It is not sent \
                                anywhere automatically. Attach it to your message if you can.
                                """
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
                                .environment(\.layoutDirection, .leftToRight)
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
            Text(
                """
                An issue on GitHub is answered sooner. Send it by email instead \
                if it carries anything you would rather not publish.
                """
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 12)

            HStack {
                Button(copied ? "Copied" : "Copy Details") { copyReport() }
                Spacer()
                // The report goes on the clipboard whichever of these is
                // pressed, so there is always something to paste.
                Button("Open an Issue") {
                    copyReport()
                    if let url = URL(string: Diagnostics.newIssueURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Open Email") {
                    copyReport()
                    if let url = Diagnostics.mailtoURL(
                        address: "bugreport@lukotta.com", environment: environment)
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600, height: 620)
        .task {
            // Opened from a failure, the box starts with what went wrong.
            // Editable: it is the reader's report, not the app's.
            if problem.isEmpty, let summary = model.reportableSummary { problem = summary }

            // Everything already in hand goes up at once. Reading the log
            // walks the system's log store and takes seconds, and a sheet that
            // sits blank meanwhile reads as one that is broken -- so the report
            // is written twice: what is known now, then again with the log.
            fixedPart = Diagnostics.report(
                environment: environment,
                engineOutput: model.reportableOutput,
                crashReport: crashes.first,
                recentLog: model.recentLog.isEmpty ? nil : model.recentLog,
                // The daemon actually running, which after an update is not
                // always the one in the bundle.
                parts: Components.all(helperInstalled: model.helper.installedVersion))
            // Kept fresh from now on too: the sheet can be left open while the
            // thing being reported is tried again.
            recentLog = model.recentLog
        }
    }
}
