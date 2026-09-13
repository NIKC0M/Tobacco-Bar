import Foundation
import Security

/// Keychain-backed storage for the Anthropic API key and any Suunto tokens.
///
/// A key stored here is still a key living on the device — fine for a personal
/// build, wrong for anything shipped to other people. If this app is ever
/// distributed, the key belongs behind a server you control and the app should
/// call that instead. See README › Security.
struct KeychainStore {

    private let service = "app.hybridathlete.credentials"

    enum Key: String {
        case anthropicAPIKey = "anthropic_api_key"
        case suuntoCredentials = "suunto_credentials"
        case suuntoTokens = "suunto_tokens"
    }

    // MARK: - Convenience

    var apiKey: String? {
        get { string(for: .anthropicAPIKey) }
        nonmutating set { set(newValue, for: .anthropicAPIKey) }
    }

    // MARK: - Primitives

    func string(for key: Key) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: Key) {
        guard let value, !value.isEmpty else {
            delete(key)
            return
        }
        set(Data(value.utf8), for: key)
    }

    func codable<T: Codable>(_ type: T.Type, for key: Key) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setCodable<T: Codable>(_ value: T?, for key: Key) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            delete(key)
            return
        }
        set(data, for: key)
    }

    func data(for key: Key) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func set(_ data: Data, for key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Credentials should not survive onto a restored backup of a
            // different device, and are never needed before first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            _ = SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
        }
    }

    func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    /// Cheap sanity check so a mistyped key fails in Settings instead of at 6am.
    static func looksLikeAnthropicKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count > 30
    }
}
