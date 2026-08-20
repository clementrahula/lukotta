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
enum CredentialStore {
    private static let service = "dev.lukotta.drive-credential"

    static func save(_ credential: String, for uuid: String) -> Bool {
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

    static func load(for uuid: String) -> String? {
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
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(for uuid: String) -> Bool {
        guard !uuid.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: uuid,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func has(for uuid: String) -> Bool { load(for: uuid) != nil }
}
