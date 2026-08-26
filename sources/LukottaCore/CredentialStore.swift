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
    /// Named after the application, whichever application this is.
    ///
    /// It used to be one name with a suffix for the pre-release, so every other
    /// build -- an unbranded one, a fork, anything built from this source with
    /// its own identifier -- read and wrote the release's saved passphrases.
    /// Keying it to the identifier gives each of them its own, and keeps the
    /// two channels apart as before.
    private static let service: String = {
        let identifier = Bundle.main.bundleIdentifier ?? "com.example.driveunlocker"
        return "\(identifier).drive-credential"
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
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecSuccess { return true }

        // Something is already filed under this service and account, and the
        // delete above did not shift it. That is what a Keychain entry left by
        // a build signed differently looks like: it is there, it is ours by
        // service, and removing it needs a permission this process was not
        // given. Writing over the value is a smaller ask than deleting the
        // entry, and it is the one that keeps a saved passphrase working
        // across an update rather than failing in front of somebody who has
        // just typed one.
        if added == errSecDuplicateItem {
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: uuid,
            ]
            let updated = SecItemUpdate(
                identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated == errSecSuccess { return true }
            Log.app.error(
                "the Keychain already holds this drive's entry and would not take a new value (\(updated, privacy: .public))"
            )
            return false
        }

        // Said with the number. Without it this is an apology with nothing
        // behind it, and the difference between a locked Keychain, a refused
        // permission and a full disk is the whole of what to do next.
        Log.app.error("the drive's key could not be saved (\(added, privacy: .public))")
        return false
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
        let found = SecItemCopyMatching(query as CFDictionary, &item)
        guard found == errSecSuccess, let data = item as? Data else {
            // Nothing stored is the ordinary answer and not worth a line.
            // Anything else means a passphrase that is there and cannot be
            // read, which is what somebody being asked to type it again is
            // actually looking at.
            if found != errSecItemNotFound {
                Log.app.error(
                    "a saved key could not be read back (\(found, privacy: .public))")
            }
            return nil
        }
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
        let removed = SecItemDelete(query as CFDictionary)
        if removed != errSecSuccess, removed != errSecItemNotFound {
            Log.app.error("a saved key could not be removed (\(removed, privacy: .public))")
        }
        return removed == errSecSuccess
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
