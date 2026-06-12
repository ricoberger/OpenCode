//
//  Keychain.swift
//  OpenCode
//
//  Minimal Keychain wrapper for storing the server password. Only the
//  password is a secret — the server URL and username live in UserDefaults
//  (see ServerConfigStorage). A tiny hand-rolled wrapper keeps the app
//  dependency-free; the full Keychain API surface is not needed.
//

import Foundation
import Security

enum Keychain {
    /// Namespaces our items so they never collide with other apps' entries
    /// (generic passwords are matched by service + account).
    private static let service = "de.ricoberger.OpenCode"

    /// Inserts or updates a string value. Errors are intentionally ignored:
    /// a failed save degrades to "user re-enters the password", which is an
    /// acceptable failure mode for this app.
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // Try update-in-place first (the common case after the first save),
        // fall back to adding a fresh item.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // AfterFirstUnlock: readable in the background once the device
            // has been unlocked, which covers a future background-refresh
            // scenario without weakening protection much.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Reads a string value, or `nil` when missing/unreadable.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes a value. Deleting a non-existent item is a no-op.
    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
