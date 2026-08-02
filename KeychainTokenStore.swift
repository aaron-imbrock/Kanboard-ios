import Foundation
import Security

/// Keeps the Kanboard API token in the Keychain instead of UserDefaults, so it is not
/// written to the app's plist or included in device backups.
enum KeychainTokenStore {
    private static let service = "org.kanboard.SimpleKanboard"
    private static let account = "api-token"
    private static let legacyDefaultsKey = "kb_token"

    static func load() -> String {
        // One-time migration off the old @AppStorage("kb_token") plaintext value.
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey) {
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            if !legacy.isEmpty {
                save(legacy)
                return legacy
            }
        }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { return "" }
        return token
    }

    static func save(_ token: String) {
        guard !token.isEmpty else { delete(); return }
        let data = Data(token.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func delete() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
