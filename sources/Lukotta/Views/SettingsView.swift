import LukottaCore
import SwiftUI

/// The Settings window, reached with Command-comma like any other Mac app.
struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var model: AppModel
    @AppStorage(MenuBarPreference.key) private var showMenuBarIcon = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue

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

                if !updater.checksAutomatically {
                    Text("You can still check whenever you like.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text("Last checked: \(lastChecked)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
                .padding(.top, 4)
                Text(
                    model.helper.isReady
                        ? "Updating does not eject your drives. Anything unlocked stays unlocked and keeps working."
                        : "Once the background helper is set up, updating will leave unlocked drives alone."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            } header: {
                Text("Updates").font(.headline)
            }

            Section {
                Toggle("Show \(Brand.name) in the menu bar", isOn: $showMenuBarIcon)
                Text("Appears only while a drive is unlocked, for ejecting it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Menu Bar").font(.headline)
            }

            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in
                    (Appearance(rawValue: new) ?? .system).apply()
                }
                Text("System follows your Mac's setting, including when it changes.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Appearance").font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
