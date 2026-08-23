// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import ServiceManagement

/// Opening at login, and what has to be in place for it to be any use.
///
/// Registering is the easy half. The other half is that a drive cannot be put
/// back without the two things a drive always needs: Full Disk Access, which
/// macOS will not let an application ask for, and the background helper, which
/// is what reads a raw disk. Both are asked for the moment the setting is
/// turned on, rather than at the next login, when nobody is watching and a
/// drive would simply fail to appear.
enum LoginItem {

    /// Turn opening at login on or off, and say what is still missing.
    ///
    /// Returns nil when everything needed is in place.
    @MainActor
    static func apply(_ on: Bool) -> String? {
        let service = SMAppService.mainApp
        guard on else {
            try? service.unregister()
            Log.app.notice("no longer opening at login")
            return nil
        }

        do {
            try service.register()
            Log.app.notice("will open at login")
        } catch {
            Log.app.error("could not register to open at login")
            return String(
                localized:
                    "macOS would not add \(Brand.name) to your login items. Open System Settings, then General, then Login Items, and add it there."
            )
        }

        // Registered, but a drive still needs these. Asked for now, while the
        // person is here and knows what they just switched on.
        if !Permissions.reading().fullDiskAccess {
            Permissions.openFullDiskAccessSettings()
            return String(
                localized:
                    "Switch on Full Disk Access for \(Brand.name) in the window that just opened. Without it a drive cannot be read, at login or at any other time."
            )
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return String(
                localized:
                    "Allow \(Brand.name) in the window that just opened, so macOS lets it open at login."
            )
        }
        return nil
    }

    /// Whether macOS currently has it registered, whatever the setting says.
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
