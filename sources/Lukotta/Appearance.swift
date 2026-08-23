// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import SwiftUI

/// Whether the app follows the system's light or dark setting, or overrides it.
///
/// Following the system is the default and is what most apps should do. The
/// override exists because this one is often used beside a file manager or a
/// terminal that has been pinned one way, and matching that is easier than
/// changing the whole Mac.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "dev.lukotta.appearance"

    var id: String { rawValue }

    /// A key, not a String: Text(String) shows the string as written, so a
    /// label typed as String is a label that never translates.
    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means "whatever the Mac is set to", which is what NSApp expects.
    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Apply this to every window the app owns.
    ///
    /// Setting it on NSApp rather than per window covers the sheets, the
    /// Settings window and the menu bar extra together, and leaving it nil
    /// hands control back to the system, including later changes to it.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }
}
