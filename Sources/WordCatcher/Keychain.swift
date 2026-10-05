import Foundation
import Security

/// Stores the Claude API key in the user's login Keychain. The key never touches a file.
enum Keychain {
    private static let service = "app.wordcatcher.mac"
    private static let account = "anthropic-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Read once per launch: every Keychain read can show a macOS permission prompt.
    private static var cached: String?
    private static var knownMissing = false

    static func apiKey() -> String? {
        if let cached { return cached }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        knownMissing = status == errSecItemNotFound
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        cached = key
        return key
    }

    /// True only when no key was ever saved, not when macOS blocked the read.
    static var isMissing: Bool {
        apiKey() == nil && knownMissing
    }

    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        let saved = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if saved {
            cached = key
            knownMissing = false
        }
        return saved
    }

    static var hasAPIKey: Bool { apiKey() != nil }
}
