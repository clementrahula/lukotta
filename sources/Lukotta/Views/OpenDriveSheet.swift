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
                    VStack(spacing: 8) {
                        ForEach(model.survey) { entry in
                            SurveyRow(entry: entry) {
                                guard let drive = entry.drive else { return }
                                dismiss()
                                model.choose(drive)
                            }
                        }
                    }
                    .padding(22)
                }
            }

            Divider()
            HStack {
                Text("Everything attached to this Mac, whether or not \(Brand.name) can open it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Check Again") { model.surveyDrives() }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 580, height: 560)
        .task { model.surveyDrives() }
    }
}

private struct SurveyRow: View {
    let entry: DriveSurvey.Entry
    let open: () -> Void

    private var openable: Bool {
        if case .openable = entry.verdict { return true }
        return false
    }

    /// Why this one cannot be opened, in ordinary terms rather than the
    /// partition table's.
    private var reason: String {
        switch entry.verdict {
        case .openable:
            return String(localized: "Encrypted, or a Windows or Linux volume.")
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
        case .macOSHasIt, .macOSReadsIt: return .green
        case .system, .unreadable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: openable ? "lock.fill" : "externaldrive")
                .font(.system(size: 19))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(entry.name).font(.callout.weight(.medium))
                    Text(verbatim: entry.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: "\(entry.sizeDescription) · \(entry.content)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(reason)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if openable {
                Button("Open", action: open).controlSize(.small)
                    .accessibilityLabel("Open \(entry.name)")
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
