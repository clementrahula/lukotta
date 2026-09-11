// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The label each drive had when it was last opened, known to every Lukotta app and never forgotten.
///
/// Keyed on the volume's identity, so it survives replugging as a different diskNsM. Nothing
/// sensitive is stored here: credentials live in the Keychain.
public enum DriveMemory {
    public static func knownName(for uuid: String) -> String? {
        guard !uuid.isEmpty else { return nil }
        return SharedMemory.read().names[uuid]
    }

    public static func remember(mountPoint: String, for uuid: String) {
        guard !uuid.isEmpty else { return }
        let name = (mountPoint as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return }
        SharedMemory.change { $0.names[uuid] = name }
    }

    /// Whether any drive has been opened before. Evidence that reading a drive was permitted once.
    public static var hasAny: Bool { !SharedMemory.read().names.isEmpty }

    /// How a test removes what it added.
    public static func forget(uuid: String) {
        SharedMemory.change { $0.names.removeValue(forKey: uuid) }
    }
}
