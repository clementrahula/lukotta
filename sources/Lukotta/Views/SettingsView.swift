// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import LukottaCore
import SwiftUI

/// The Settings window, reached with Command-comma like any other Mac app.
struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var model: AppModel
    @AppStorage(MenuBarPreference.key) private var showMenuBarIcon = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @AppStorage(Language.key) private var language = Language.system
    @State private var languageChanged = false
    @AppStorage(RestorePreference.key) private var restoreAtLogin = false
    /// What still has to be granted before opening at login can work, shown
    /// beside the switch rather than as a dialogue nobody reads.
    @State private var restoreNeeds: String?

    private var lastChecked: String {
        guard let date = updater.lastChecked else { return "Not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open drives again after restarting", isOn: $restoreAtLogin)
                    .onChange(of: restoreAtLogin) { _, on in
                        restoreNeeds = LoginItem.apply(on)
                        if on { model.restoreRememberedMounts() }
                    }
                Text(
                    "\(Brand.name) opens in the background when you log in and puts back the drives and images that were open, as they were. A drive that needs a password comes back only if the password is saved in your Keychain."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let restoreNeeds {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(restoreNeeds)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle(
                    "Download and install them",
                    isOn: Binding(
                        get: { updater.checksAutomatically && updater.downloadsAutomatically },
                        set: { updater.downloadsAutomatically = $0 })
                )
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
                    .onChange(of: showMenuBarIcon) { model.refreshEjectables() }
                Text("Appears only while a drive is unlocked, for ejecting it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Menu Bar").font(.headline)
            }

            Section {
                PopUpRow(
                    choices: [(Language.system, String(localized: "System")), (nil, "")]
                        + Language.available.map { ($0, Language.name(of: $0)) },
                    selection: $language
                )
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Language")
                .onChange(of: language) { _, choice in
                    Language.apply(choice)
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("The language changes when \(Brand.name) starts again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { model.relaunch() }
                            .controlSize(.small)
                    }
                } else {
                    Text("System follows your Mac's language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Language").font(.headline)
            }

            Section {
                // A Form puts a control with no label against the right edge,
                // away from the words explaining it. Held to the left instead,
                // at its own width rather than stretched across the row.
                HStack {
                    Picker("", selection: $appearance) {
                        ForEach(Appearance.allCases) { choice in
                            Text(choice.label).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Appearance")
                    .onChange(of: appearance) { _, new in
                        (Appearance(rawValue: new) ?? .system).apply()
                    }
                    Spacer()
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
