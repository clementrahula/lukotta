// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation
import Security

/// A drive's password or recovery key, in the Keychain, found by every Lukotta app of every version.
///
/// Keyed by the volume's identity rather than its device path, so a key survives the drive coming
/// back as a different diskNsM.
public enum CredentialStore {
    static let lukotta = "com.lukotta"

    static let identifier = Bundle.main.bundleIdentifier ?? "com.example.driveunlocker"

    /// Written by every Lukotta app, readable by any app without a prompt. Never renamed.
    static let store: String = {
        identifier.hasPrefix(lukotta) ? "\(lukotta).keys" : "\(identifier).keys"
    }()

    /// Where keys were kept before: read, copied into the store, never written or removed.
    static let earlier: [String] = {
        guard identifier.hasPrefix(lukotta) else { return ["\(identifier).drive-credential"] }
        return [lukotta, "\(lukotta).beta", "\(lukotta).dev", "\(lukotta).v2"]
            .map { "\($0).drive-credential" }
    }()

    static var everywhere: [String] { [store] + earlier }

    /// No Keychain call ever puts a prompt in front of anybody.
    static func quietly<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    /// Any application may read the entry: a future build, name or signature is never locked out.
    static func openAccess() -> SecAccess? {
        let label = "Lukotta drive credential" as CFString
        var access: SecAccess?
        guard SecAccessCreate(label, [] as CFArray, &access) == errSecSuccess, let access else {
            return nil
        }
        let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL]
        for acl in acls ?? [] {
            SecACLSetContents(acl, nil, label, [])
        }
        return access
    }

    public static func save(_ credential: String, for uuid: String) -> Bool {
        guard !uuid.isEmpty, let data = credential.data(using: .utf8) else { return false }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store,
            kSecAttrAccount as String: uuid,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Lukotta drive credential",
            kSecAttrSynchronizable as String: false,
        ]
        if let access = openAccess() { query[kSecAttrAccess as String] = access }
        let added = quietly { SecItemAdd(query as CFDictionary, nil) }
        if added == errSecSuccess { return true }

        // Already saved: overwritten in place, never deleted first.
        if added == errSecDuplicateItem {
            let identity: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: store,
                kSecAttrAccount as String: uuid,
            ]
            let change = [kSecValueData as String: data] as CFDictionary
            let updated = quietly { SecItemUpdate(identity as CFDictionary, change) }
            if updated == errSecSuccess { return true }
            Log.app.error("the saved key would not take a new value (\(updated, privacy: .public))")
            return false
        }
        Log.app.error("the drive's key could not be saved (\(added, privacy: .public))")
        return false
    }

    /// The saved key, wherever any Lukotta app saved it.
    public static func load(for uuid: String) -> String? {
        guard !uuid.isEmpty else { return nil }
        for place in everywhere {
            guard let found = read(service: place, account: uuid) else { continue }
            if place != store { _ = save(found, for: uuid) }
            return found
        }
        return nil
    }

    static func read(service place: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: place,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let found = quietly { SecItemCopyMatching(query as CFDictionary, &item) }
        guard found == errSecSuccess, let data = item as? Data,
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        else {
            if found != errSecItemNotFound, found != errSecSuccess {
                Log.app.error("a saved key could not be read back (\(found, privacy: .public))")
            }
            return nil
        }
        return text
    }

    /// Forget: the drive's key goes from every place a Lukotta app filed it.
    @discardableResult
    public static func delete(for uuid: String) -> Bool {
        guard !uuid.isEmpty else { return false }
        var removedAny = false
        for place in everywhere {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: place,
                kSecAttrAccount as String: uuid,
            ]
            let removed = quietly { SecItemDelete(query as CFDictionary) }
            if removed == errSecSuccess { removedAny = true }
            if removed != errSecSuccess, removed != errSecItemNotFound {
                Log.app.error("a saved key could not be removed (\(removed, privacy: .public))")
            }
        }
        return removedAny
    }

    public static func has(for uuid: String) -> Bool { load(for: uuid) != nil }

    /// Every drive a key is saved for, named so an uninstall can say which.
    public static func savedDrives() -> [String] {
        var names: [String] = []
        for entry in entries(withData: false) where !names.contains(entry.account) {
            names.append(entry.account)
        }
        return names
    }

    /// Every saved key, tried before anybody is asked to type one that is already in the Keychain.
    public static func allSaved() -> [(name: String, credential: String)] {
        entries(withData: true).compactMap { entry in
            guard let credential = entry.credential, !credential.isEmpty else { return nil }
            return (entry.account, credential)
        }
    }

    public static var hasAny: Bool { !entries(withData: false).isEmpty }

    static func entries(withData: Bool) -> [(account: String, credential: String?)] {
        everywhere.flatMap { place -> [(account: String, credential: String?)] in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: place,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if withData { query[kSecReturnData as String] = true }
            var items: CFTypeRef?
            let found = quietly { SecItemCopyMatching(query as CFDictionary, &items) }
            guard found == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
            return list.compactMap { entry in
                guard let account = entry[kSecAttrAccount as String] as? String else { return nil }
                let credential = (entry[kSecValueData as String] as? Data).flatMap {
                    String(data: $0, encoding: .utf8)
                }
                return (account, credential)
            }
        }
    }
}
