// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import Security

/// Optional storage for a drive's password or recovery key.
///
/// Off by default and always the user's choice. The argument for making people
/// retype a 48-digit recovery key every time is weaker than it looks: the
/// realistic alternative is a text file on the desktop, which is worse in every
/// respect. The Keychain is the right place for this.
///
/// Entries are keyed by the partition's UUID rather than its device path, so
/// they survive the drive being replugged as a different diskNsM.
public enum CredentialStore {
    /// Where these are kept in the Keychain.
    ///
    /// The released app's name is left exactly as it was: changing it would
    /// lose every passphrase anybody has saved. A pre-release adds its own
    /// suffix, so it cannot read or overwrite them -- it is a different app,
    /// and somebody testing one should not find the other's keys in it.
    private static let service: String = {
        let base = "com.lukotta.drive-credential"
        let identifier = Bundle.main.bundleIdentifier ?? ""
        return identifier.hasSuffix(".beta") ? base + ".beta" : base
    }()

    public static func save(_ credential: String, for uuid: String) -> Bool {
        guard !uuid.isEmpty, let data = credential.data(using: .utf8) else { return false }
        delete(for: uuid)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uuid,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Lukotta drive credential",
            // Available only while the Mac is unlocked, and never synced to
            // other devices: this is a local disk's key.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: false,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func load(for uuid: String) -> String? {
        guard !uuid.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uuid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(for uuid: String) -> Bool {
        guard !uuid.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uuid,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public static func has(for uuid: String) -> Bool { load(for: uuid) != nil }

    /// Every drive a passphrase is stored for.
    ///
    /// Uninstalling offers to remove them, and an offer to delete "some
    /// passphrases" is not one anybody can weigh. This is what lets the
    /// question name the drives.
    public static func savedDrives() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
            let entries = items as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Whether any drive credential is stored at all.
    ///
    /// Used when uninstalling, to say that passphrases are being left behind
    /// rather than removing them without asking.
    public static var hasAny: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
