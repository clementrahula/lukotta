import LukottaCore
import SwiftUI

/// The uninstall, shown as it happens.
///
/// Removing an app is not a moment to leave someone watching a spinner: each
/// step says what it is doing and stays on screen when it is done, so what was
/// removed is visible afterwards rather than only promised beforehand.
struct UninstallView: View {
    @EnvironmentObject var model: AppModel

    private var allDone: Bool { model.uninstallFinished && model.uninstallFailure == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: allDone ? "checkmark.circle.fill" : "trash")
                    .font(.system(size: 28))
                    .foregroundStyle(allDone ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(allDone ? "\(Brand.name) has been removed" : "Removing \(Brand.name)")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        allDone
                            ? "It is in the Bin. Nothing else of it is left on this Mac."
                            : "This takes a moment."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                ForEach(model.uninstallSteps) { step in
                    HStack(spacing: 10) {
                        Group {
                            if step.done {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(step.label)
                            .font(.callout)
                            .foregroundStyle(step.done ? .secondary : .primary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(step.label): \(step.done ? "done" : "in progress")")
                }
            }

            if let failure = model.uninstallFailure {
                InfoBox(
                    text: """
                        Everything else was removed. \(Brand.name) itself could not be moved to \
                        the Bin — \(failure) — so drag it there yourself to finish.
                        """)
            }

            Spacer()

            HStack {
                Spacer()
                if model.uninstallFinished {
                    Button("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
