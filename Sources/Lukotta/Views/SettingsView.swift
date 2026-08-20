import LukottaCore
import SwiftUI

/// The Settings window, reached with Command-comma like any other Mac app.
struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var model: AppModel

    private var lastChecked: String {
        guard let date = updater.lastChecked else { return "Not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle("Download and install them", isOn: $updater.downloadsAutomatically)
                    .disabled(!updater.checksAutomatically)
                    .padding(.leading, 18)

                Text(
                    updater.checksAutomatically
                        ? "Checked daily. Lukotta reads a raw disk and runs part of itself as root, so a fix reaching you matters."
                        : "Lukotta will not look for updates. You can still check whenever you like."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Last checked: \(lastChecked)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
                .padding(.top, 4)
                // Worth saying plainly: an update replaces the app while a
                // drive may be open, and whether that drive survives depends on
                // which route opened it.
                Label(
                    model.helper.isReady
                        ? "An open drive stays open through an update. The background helper holds it, not the app."
                        : "An open drive will close when an update installs, because the app itself is holding it. Setting up the background helper keeps it open.",
                    systemImage: model.helper.isReady ? "checkmark.circle" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(model.helper.isReady ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            } header: {
                Text("Updates").font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
